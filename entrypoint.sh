#!/bin/bash
set -euo pipefail
# Unmatched globs expand to nothing instead of the literal pattern, so the
# artifact_*.jq / resource_*.jq loops below simply skip when no files match.
shopt -s nullglob

# Define colors
RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color (reset)

entrypoint_dir="/massdriver"

params_path="$entrypoint_dir/params.json"
connections_path="$entrypoint_dir/connections.json"
config_path="$entrypoint_dir/config.json"
envs_path="$entrypoint_dir/envs.json"
secrets_path="$entrypoint_dir/secrets.json"

# Utility function for extracting JSON booleans with default values (since jq "//" doesn't work for properly for booleans)
jq_bool_default() {
  local query="${1:-}"
  local default="${2:-}"
  local data="${3:-}"

  if [ -z "$query" ] || [ -z "$default" ] || [ -z "$data" ]; then
    echo -e "${RED}jq_bool_default: missing argument(s)${NC}"
    exit 1
  fi
  
  jq -r "if $query == null then $default else $query end" "$data"
}
# Utility function for evaluating Checkov policies
evaluate_checkov() {
    if [ "$checkov_enabled" = "true" ]; then
        echo "Evaluating Checkov policies..."
        checkov_flags=""

        if [ "$checkov_quiet" = "true" ]; then
            checkov_flags+=" --quiet"
        fi
        if [ "$checkov_halt_on_failure" = "false" ]; then
            checkov_flags+=" --soft-fail"
        fi

        checkov --framework bicep -f template.bicep $checkov_flags
    fi
}

# Extract provisioner configuration
name_prefix=$(jq -r '.md_metadata.name_prefix' "$params_path")
scope=$(jq -r '.scope // "group"' "$config_path")
location=$(jq -r '.location // .region // "eastus"' "$config_path")
show_output=$(jq_bool_default '.show_output' false "$config_path")
action_on_unmanage=$(jq -r '.action_on_unmanage // "deleteAll"' "$config_path")
deny_settings_mode=$(jq -r '.deny_settings_mode // "none"' "$config_path")

# resource group scope settings
resource_group=$(jq -r --arg name_prefix "$name_prefix" '.resource_group // $name_prefix' "$config_path")
create_resource_group=$(jq_bool_default '.create_resource_group' true "$config_path")
delete_resource_group=$(jq_bool_default '.delete_resource_group' true "$config_path")

# Extract Checkov configuration
checkov_enabled=$(jq_bool_default '.checkov.enable' true "$config_path")
checkov_quiet=$(jq_bool_default '.checkov.quiet' true "$config_path")
checkov_halt_on_failure=$(jq_bool_default '.checkov.halt_on_failure' false "$config_path")

# ---------------------------------------------------------------------------
# Azure authentication
#
# Field resolution (config overlays the connection per-field; whichever single
# connection is found is used, and config alone is fine if neither exists):
#   1. config.json      .azure_authentication            (manual overlay, flat)
#   2. connections.json .azure_authentication            (connection, flat)    } first
#   3. connections.json .azure_service_principal.data    (legacy conn, .data)  } found
#
# Auth-method detection then runs on the resolved fields:
#   1. secret present      -> static SP
#   2. federated token env -> workload identity
#   3. client_id           -> user-assigned MI
#   4. else                -> system-assigned MI
# subscription_id is independent of the method.
# ---------------------------------------------------------------------------

# Overlay config.azure_authentication on top of whichever connection is found.
auth=$(jq -s '
    (.[1].azure_authentication // .[1].azure_service_principal.data // {}) as $conn
  | (.[0].azure_authentication // {})                                   as $cfg
  | $conn * $cfg
' "$config_path" "$connections_path")

azure_client_id=$(echo "$auth"       | jq -r '.client_id // empty')
azure_client_secret=$(echo "$auth"   | jq -r '.client_secret // empty')
azure_tenant_id=$(echo "$auth"       | jq -r '.tenant_id // empty')
azure_subscription_id=$(echo "$auth" | jq -r '.subscription_id // empty')

# The workload-identity webhook injects these; let resolved config/connection win.
azure_client_id="${azure_client_id:-${AZURE_CLIENT_ID:-}}"
azure_tenant_id="${azure_tenant_id:-${AZURE_TENANT_ID:-}}"
federated_token_file="${AZURE_FEDERATED_TOKEN_FILE:-}"

auth_fail() {  # $1 = method, $2 = hint
  echo -e "${RED}Azure authentication failed (${1}).${NC}" >&2
  echo -e "${RED}${2}${NC}" >&2
  exit 1
}

if [ -n "$azure_client_secret" ]; then
  echo "Authenticating to Azure with a service principal secret (client_id: ${azure_client_id:-<unset>})..."
  missing=()
  [ -z "$azure_client_id" ] && missing+=("client_id")
  [ -z "$azure_tenant_id" ] && missing+=("tenant_id")
  [ ${#missing[@]} -gt 0 ] && auth_fail "service principal secret" \
    "client_secret was provided but these required fields are missing: ${missing[*]}."
  az login --service-principal -u "$azure_client_id" -p "$azure_client_secret" -t "$azure_tenant_id" >/dev/null \
    || auth_fail "service principal secret" \
       "Verify client_id, client_secret, and tenant_id are correct and the secret has not expired."

elif [ -n "$federated_token_file" ]; then
  echo "Authenticating to Azure with workload identity (federated token)..."
  missing=()
  [ -z "$azure_client_id" ] && missing+=("client_id / AZURE_CLIENT_ID")
  [ -z "$azure_tenant_id" ] && missing+=("tenant_id / AZURE_TENANT_ID")
  [ ${#missing[@]} -gt 0 ] && auth_fail "workload identity" \
    "AZURE_FEDERATED_TOKEN_FILE is set but these are missing: ${missing[*]}. Is the webhook injecting them / the service account annotated?"
  [ -r "$federated_token_file" ] || auth_fail "workload identity" \
    "Federated token file '$federated_token_file' is not readable."
  az login --service-principal -u "$azure_client_id" -t "$azure_tenant_id" \
    --federated-token "$(cat "$federated_token_file")" >/dev/null \
    || auth_fail "workload identity" \
       "The federated credential may not be configured on the app/identity for this cluster's OIDC issuer + service account."

elif [ -n "$azure_client_id" ]; then
  echo "Authenticating to Azure with a user-assigned managed identity (client_id: ${azure_client_id})..."
  az login --identity --username "$azure_client_id" >/dev/null \
    || auth_fail "user-assigned managed identity" \
       "Is this identity assigned to the node, and is IMDS reachable from the pod?"

else
  echo "Authenticating to Azure with a system-assigned managed identity..."
  echo -e "${YELLOW}Note: system-assigned managed identity is generally unavailable to Kubernetes pods. If this is an AKS pod, you almost certainly want workload identity instead.${NC}"
  az login --identity >/dev/null \
    || auth_fail "system-assigned managed identity" \
       "No client_secret, no federated token, and no usable managed identity. For an AKS pod, configure workload identity."
fi

echo -e "${GREEN}Authenticated to Azure.${NC}\n"

# subscription_id: use if provided, otherwise the identity's default subscription.
if [ -n "$azure_subscription_id" ]; then
  az account set --subscription "$azure_subscription_id" \
    || auth_fail "subscription selection" \
       "Could not switch to subscription '$azure_subscription_id'. Does this identity have access to it?"
fi

# TODO: this can eventually be removed after MASSDRIVER_PACKAGE_NAME is fully deprecated
if [ -z "${MASSDRIVER_INSTANCE_ID:-}" ]; then
    export MASSDRIVER_INSTANCE_ID=$(echo "$MASSDRIVER_PACKAGE_NAME" | sed 's/-[a-z0-9]\{4\}$//')
fi

cd "bundle/$MASSDRIVER_STEP_PATH"

# Manipulate params/connections to fit Bicep format and write to file
jq 'with_entries(.value |= {value: .})' "$connections_path" > connections.json
jq 'with_entries(.value |= {value: .})' "$params_path" > params.json

# Set flags for az stack commands
flags=(--action-on-unmanage "$action_on_unmanage")
create_flags=(--deny-settings-mode "$deny_settings_mode")

case "$scope" in
  group)
    echo -e "Targeting resource group $resource_group\n"
    flags+=(--resource-group "$resource_group")
    ;;
  sub)
    echo -e "Targeting subscription $(az account show --query id -o tsv)\n"
    if [ "$MASSDRIVER_DEPLOYMENT_ACTION" != "decommission" ]; then
      create_flags+=(--location "$location")
    fi

    ;;
  *)
    echo -e "${RED}Error: Unsupported scope '$scope'. Expected 'group' or 'sub'.${NC}"
    exit 1
    ;;
esac

stack_name="${name_prefix}-${MASSDRIVER_STEP_PATH}"

# Handle deployment actions
case "$MASSDRIVER_DEPLOYMENT_ACTION" in

  plan)
    # evaluate_checkov
    # echo "Executing plan..."
    # az deployment $scope what-if $create_flags --name "$stack_name" --template-file template.bicep --parameters @params.json --parameters @connections.json
    echo -e "${YELLOW}What-if is not supported for Azure Stack deployments. Skipping plan step.${NC}"
    ;;

  provision)
    evaluate_checkov
    echo "Provisioning resources..."

    if [ "$scope" = "group" ]; then
      if [ "$create_resource_group" = "true" ]; then
        echo "Creating resource group $resource_group in location $location..."
        az group create --name "$resource_group" --location "$location"
        echo -e "${GREEN}Resource group $resource_group created.\n${NC}"
      else
        echo "Checking if resource group $resource_group exists..."
        if [ "$(az group exists --name "$resource_group")" = "true" ]; then
          echo "Resource group exists! Using existing resource group $resource_group"
        else
          echo -e "${RED}Error: Resource group $resource_group does not exist. If 'create_resource_group' is false, the resource group must already exist in Azure. To avoid this error, set 'create_resource_group' to 'true' in the provisioner configuration, or create the resource group $resource_group before provisioning.${NC}"
          exit 1
        fi
      fi
    fi

    echo -e "Deploying stack $stack_name..."
    if ! az stack "$scope" create "${create_flags[@]}" "${flags[@]}" --name "$stack_name" --template-file template.bicep --parameters @params.json --parameters @connections.json > create_output.json; then
      [ "$show_output" = "true" ] && cat create_output.json
      echo -e "${RED}Stack $stack_name deployment failed.${NC}"
      exit 1
    fi
    # The create output contains the deployment outputs nested within it, and may
    # contain secrets, so it is printed only when show_output is enabled.
    [ "$show_output" = "true" ] && cat create_output.json
    jq '.outputs // {} | with_entries(.value = .value.value)' create_output.json > outputs.json
    echo -e "${GREEN}Stack $stack_name deployed successfully.${NC}"

    jq -s '{params:.[0],connections:.[1],envs:.[2],secrets:.[3],outputs:.[4]}' "$params_path" "$connections_path" "$envs_path" "$secrets_path" outputs.json > resource_inputs.json
    for resource_file in artifact_*.jq resource_*.jq; do
      [ -f "$resource_file" ] || continue
      field=$(echo "$resource_file" | sed -E 's/^(artifact|resource)_(.*)\.jq$/\2/')
      echo -e "\nCreating resource \"$MASSDRIVER_INSTANCE_ID-$field\" in Massdriver..."
      jq -f "$resource_file" resource_inputs.json | xo resource publish -d "$field" -n "Resource $field for $name_prefix" -f -
    done
    ;;

  decommission)

    echo -e "Deleting stack $stack_name..."
    az stack "$scope" delete "${flags[@]}" --name "$stack_name" --yes
    echo -e "${GREEN}Stack $stack_name deleted successfully.\n${NC}"

    if [ "$scope" = "group" ] && [ "$delete_resource_group" = "true" ]; then
      echo "Deleting resource group $resource_group..."
      az group delete --name "$resource_group" --yes
      echo -e "${GREEN}Resource group $resource_group deleted successfully.\n${NC}"
    fi

    for resource_file in artifact_*.jq resource_*.jq; do
      [ -f "$resource_file" ] || continue
      field=$(echo "$resource_file" | sed -E 's/^(artifact|resource)_(.*)\.jq$/\2/')
      echo -e "\nDeleting resource \"$MASSDRIVER_INSTANCE_ID-$field\" from Massdriver..."
      xo resource delete -d "$field" || echo -e "${YELLOW}Warning: failed to delete resource for field $field. Continuing decommission.${NC}"
    done
    ;;

  *)
    echo -e "${RED}Error: Unsupported deployment action '$MASSDRIVER_DEPLOYMENT_ACTION'. Expected 'plan', 'provision', or 'decommission'.${NC}"
    exit 1
    ;;

esac
