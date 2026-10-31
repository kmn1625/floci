# Pinned Linux toolbox for the Azure lab: terraform, kubectl, helm, ansible.
# Runs on the floci-az compose network so ARM calls go to https://floci-az:4577
# (Terraform on Windows ignores SSL_CERT_FILE; a Linux container does not).
FROM python:3.12.16-slim

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG TERRAFORM_VERSION=1.16.6
ARG KUBECTL_VERSION=1.36.1
ARG HELM_VERSION=4.3.1
ARG ANSIBLE_CORE_VERSION=2.21.5

# hadolint ignore=DL3008
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl unzip ca-certificates git openssh-client jq dnsutils dnsmasq socat \
    && rm -rf /var/lib/apt/lists/*

RUN set -eux; cd /tmp; \
    curl -fsSLo tf.zip "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip"; \
    unzip -q tf.zip terraform -d /usr/local/bin && rm tf.zip; \
    curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl"; \
    chmod +x /usr/local/bin/kubectl; \
    curl -fsSL "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz" | tar -xz --strip-components=1 -C /usr/local/bin linux-amd64/helm; \
    pip install --no-cache-dir "ansible-core==${ANSIBLE_CORE_VERSION}"

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENV TF_PLUGIN_CACHE_DIR=/root/.terraform.d/plugin-cache \
    TF_IN_AUTOMATION=1
RUN mkdir -p /root/.terraform.d/plugin-cache
WORKDIR /work
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]
