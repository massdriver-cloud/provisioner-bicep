ARG AZURE_CLI_VERSION=2.86.0
ARG CHECKOV_VERSION=3.2.530
ARG RUN_IMG=debian:13.5-slim
ARG USER=massdriver
ARG UID=10001

FROM ${RUN_IMG} AS build
ARG AZURE_CLI_VERSION
ARG CHECKOV_VERSION

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl unzip jq gnupg && \
    curl -s https://api.github.com/repos/massdriver-cloud/xo/releases/latest | jq -r '.assets[] | select(.name | contains("linux-amd64")) | .browser_download_url' | xargs curl -sSL -o xo.tar.gz && tar -xvf xo.tar.gz -C /tmp && mv /tmp/xo /usr/local/bin/ && rm xo.tar.gz && \
    curl -sSL https://github.com/bridgecrewio/checkov/releases/download/${CHECKOV_VERSION}/checkov_linux_X86_64.zip -o checkov.zip && unzip checkov.zip && mv dist/checkov /usr/local/bin/ && rm -rf checkov.zip dist && \
    curl -sSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > /usr/share/keyrings/microsoft.gpg && \
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ bookworm main"  > /etc/apt/sources.list.d/azure-cli.list && \
    apt-get update && \
    if [ "$AZURE_CLI_VERSION" = "latest" ]; then \
        apt-get install -y --no-install-recommends azure-cli; \
    else \
        apt-get install -y --no-install-recommends azure-cli=${AZURE_CLI_VERSION}*; \
    fi && \
    rm -rf /var/lib/apt/lists/*

FROM ${RUN_IMG}
ARG USER
ARG UID

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates jq libicu76 && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p -m 777 /massdriver

RUN useradd \
    --create-home \
    --shell /bin/bash \
    --uid ${UID} \
    ${USER} && \
    chown -R ${USER}:${USER} /massdriver

COPY --from=build /usr/local/bin/xo /usr/local/bin/xo
COPY --from=build /usr/local/bin/checkov /usr/local/bin/checkov
COPY --from=build /usr/bin/az /usr/bin/az
COPY --from=build /opt/az /opt/az
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

USER ${USER}

# Pre-install Bicep so `az stack` doesn't download it on first run
RUN az bicep install

ENV MASSDRIVER_PROVISIONER=bicep

WORKDIR /massdriver

ENTRYPOINT ["entrypoint.sh"]