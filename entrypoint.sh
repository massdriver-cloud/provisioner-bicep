#!/bin/bash
set -euo pipefail

# Define colors
RED='\033[0;31m'
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
complete=$(jq_bool_default '.complete' true "$config_path")

# resource group scope settings
resource_group=$(jq -r --arg name_prefix "$name_prefix" '.resource_group // $name_prefix' "$config_path")
create_resource_group=$(jq_bool_default '.create_resource_group' true "$config_path")
delete_resource_group=$(jq_bool_default '.delete_resource_group' true "$config_path")

# Extract Checkov configuration
checkov_enabled=$(jq_bool_default '.checkov.enable' true "$config_path")
checkov_quiet=$(jq_bool_default '.checkov.quiet' true "$config_path")
checkov_halt_on_failure=$(jq_bool_default '.checkov.halt_on_failure' false "$config_path")

# Extract auth
# Try to get azure_service_principal from config.json, then fall back to connections.json
azure_auth=$(jq -r '.azure_service_principal // empty' "$config_path" 2>/dev/null || true)

if [ -z "$azure_auth" ]; then
  azure_auth=$(jq -r '.azure_service_principal // empty' "$connections_path" 2>/dev/null || true)
fi

# Check if azure_auth is still empty, and exit since we don't have auth info
if [ -z "$azure_auth" ]; then
  echo -e "${RED}Error: No Azure credentials found. Please refer to the provisioner documentation for specifying Azure credentials.${NC}"
  exit 1
fi

# Extract fields from azure_service_principal and validate they are not empty
azure_client_id=$(echo "$azure_auth" | jq -r '.data.client_id // empty')
azure_client_secret=$(echo "$azure_auth" | jq -r '.data.client_secret // empty')
azure_tenant_id=$(echo "$azure_auth" | jq -r '.data.tenant_id // empty')
azure_subscription_id=$(echo "$azure_auth" | jq -r '.data.subscription_id // empty')

for var in azure_client_id azure_client_secret azure_tenant_id; do
  if [ -z "${!var}" ]; then
    echo -e "${RED}Error: Missing required field $var in azure_service_principal.${NC}"
    exit 1
  fi
done

cd bundle/$MASSDRIVER_STEP_PATH

# Manipulate params/connections to fit Bicep format and write to file
jq 'with_entries(.value |= {value: .})' "$connections_path" > connections.json
jq 'with_entries(.value |= {value: .})' "$params_path" > params.json

# Authenticate with Azure using the service principal
echo "Authorizing to Azure using service principal..."
if ! az login --service-principal -u "$azure_client_id" -p "$azure_client_secret" -t "$azure_tenant_id"; then
  echo "Authentication failed. Please check the Azure credentials and refer to provisioner documentation."
  exit 1
fi
az account set --subscription "$azure_subscription_id"
echo "${GREEN}Authentication successful.${NC}"

az_flags=""
# Set command and flag settings based on scope
case "$scope" in
  group)
    echo "Targeting resource group $resource_group"
    az_flags+=" --resource-group $resource_group"
    ;;
  sub)
    echo "Targeting subscription $azure_subscription_id"
    az_flags+=" --location $location"
    ;;
  *)
    echo -e "${RED}Error: Unsupported scope '$scope'. Expected 'group' or 'sub'.${NC}"
    exit 1
    ;;
esac

# Extract flags from provisioner config
if [ "$complete" = "true" ]; then
  az_flags+=" --mode Complete"
fi

deployment_name="${name_prefix}-${MASSDRIVER_STEP_PATH}"

# Handle deployment actions
case "$MASSDRIVER_DEPLOYMENT_ACTION" in

  plan)
    evaluate_checkov
    echo "Executing plan..."
    az deployment $scope what-if $az_flags --name $deployment_name --template-file template.bicep --parameters @params.json --parameters @connections.json
    ;;

  provision)
    evaluate_checkov
    echo "Provisioning resources..."

    if [ "$scope" = "group" ]; then
      if [ "$create_resource_group" = "true" ]; then
        echo "Creating resource group $resource_group in location $location..."
        az group create --name "$resource_group" --location "$location"
        echo "Resource group $resource_group created."
      else
        echo "Checking if resource group $resource_group exists..."
        if az group exists --name "$resource_group" | grep -q "true"; then
          echo "Resource group exists! Using existing resource group $resource_group"
        else
          echo -e "${RED}Error: Resource group $resource_group does not exist. If 'create_resource_group' is false, the resource group must already exist in Azure. To avoid this error, set 'create_resource_group' to 'true' in the provisioner configuration, or create the resource group $resource_group before provisioning.${NC}"
          exit 1
        fi
      fi
    fi

    echo "Deploying bundle"
    az deployment $scope create $az_flags --name $deployment_name --template-file template.bicep --parameters @params.json --parameters @connections.json | tee outputs.json

    jq -s '{params:.[0],connections:.[1],envs:.[2],secrets:.[3],outputs:.[4].properties.outputs}' "$params_path" "$connections_path" "$envs_path" "$secrets_path" outputs.json > artifact_inputs.json
    for artifact_file in artifact_*.jq; do
      [ -f "$artifact_file" ] || break
      field=$(echo "$artifact_file" | sed 's/^artifact_\(.*\).jq$/\1/')
      echo "Creating artifact for field $field"
      jq -f "$artifact_file" artifact_inputs.json | xo artifact publish -d "$field" -n "Artifact $field for $name_prefix" -f -
    done
    ;;

  decommission)
    echo "Decommissioning resources..."
    touch empty.bicep
    az deployment $scope create $az_flags --name $deployment_name --template-file empty.bicep
    rm empty.bicep

    echo "Deleting deployment group $deployment_name"
    az deployment $scope delete --name "$deployment_name"

    if [ "$scope" = "group" ] && [ "$delete_resource_group" = "true" ]; then
      echo "Deleting resource group $resource_group in location $location"
      az group delete --name "$resource_group" --yes
    fi

    for artifact_file in artifact_*.jq; do
      [ -f "$artifact_file" ] || break
      field=$(echo "$artifact_file" | sed 's/^artifact_\(.*\).jq$/\1/')
      echo "Deleting artifact for field $field"
      xo artifact delete -d "$field" -n "Artifact $field for $name_prefix"
    done
    ;;

  *)
    echo -e "${RED}Error: Unsupported deployment action '$MASSDRIVER_DEPLOYMENT_ACTION'. Expected 'plan', 'provision', or 'decommission'.${NC}"
    exit 1
    ;;

esac
