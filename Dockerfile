ARG AZURE_CLI_VERSION=2.75.0
ARG CHECKOV_VERSION=3.2.268
ARG OPA_VERSION=0.69.0
ARG RUN_IMG=debian:12.7-slim
ARG USER=massdriver
ARG UID=10001

FROM ${RUN_IMG} AS build
ARG AZURE_CLI_VERSION
ARG CHECKOV_VERSION
ARG OPA_VERSION

ENV DEBIAN_FRONTEND=noninteractive
RUN apt update && apt install -y curl unzip make jq apt-transport-https gnupg lsb-release && \
    curl -s https://api.github.com/repos/massdriver-cloud/xo/releases/latest | jq -r '.assets[] | select(.name | contains("linux-amd64")) | .browser_download_url' | xargs curl -sSL -o xo.tar.gz && tar -xvf xo.tar.gz -C /tmp && mv /tmp/xo /usr/local/bin/ && rm *.tar.gz && \
    curl -sSL https://openpolicyagent.org/downloads/v${OPA_VERSION}/opa_linux_amd64_static > /usr/local/bin/opa && chmod a+x /usr/local/bin/opa && \
    curl -sSL https://github.com/bridgecrewio/checkov/releases/download/${CHECKOV_VERSION}/checkov_linux_X86_64.zip > checkov.zip && unzip checkov.zip && mv dist/checkov /usr/local/bin/ && rm *.zip && \
    curl -sSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > /etc/apt/trusted.gpg.d/microsoft.asc.gpg && \
    echo "deb [arch=amd64] https://packages.microsoft.com/repos/azure-cli/ $(lsb_release -cs) main" > /etc/apt/sources.list.d/azure-cli.list && \
    apt update && \
    if [ "$AZ_CLI_VERSION" = "latest" ]; then \
        apt install -y azure-cli; \
    else \
        apt install -y azure-cli=$AZ_CLI_VERSION*; \
    fi && \
    rm -rf /var/lib/apt/lists/*

FROM ${RUN_IMG}
ARG USER
ARG UID

RUN apt update && apt install -y ca-certificates jq libicu72 && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p -m 777 /massdriver

RUN adduser \
    --disabled-password \
    --gecos "" \
    --uid $UID \
    $USER
RUN chown -R $USER:$USER /massdriver
USER $USER

COPY --from=build /usr/local/bin/* /usr/local/bin/
COPY --from=build /usr/bin/az /usr/bin/az
COPY --from=build /opt/az /opt/az
COPY entrypoint.sh /usr/local/bin/

ENV MASSDRIVER_PROVISIONER=bicep

WORKDIR /massdriver

ENTRYPOINT ["entrypoint.sh"]