# Pinned Linux toolbox for the Azure lab: terraform, kubectl, helm, ansible.
# Runs on the floci-az compose network so ARM calls go to https://floci-az:4577
# (Terraform on Windows ignores SSL_CERT_FILE; a Linux container does not).
# kubectl is built from source: the 1.36 and 1.37 release binaries ship x/net with a critical CVE
# (GO-2026-6612). kubectl/ is upstream's main.go with go.sum pinning every module. Drop this stage
# once a release ships x/net >= 0.60.0.
FROM golang:1.26.10@sha256:b27fde63cc160f04a81cf7cf43c6560b47d736a1f0e3babe17745e8fbdff198d AS kubectl
ARG KUBECTL_VERSION=1.36.6
ARG KUBECTL_COMMIT=1b2171b110bb2a2542e1322035c6583ec86eb976
ENV CGO_ENABLED=0 GOFLAGS="-trimpath"
WORKDIR /src
COPY kubectl/ ./
RUN v="v${KUBECTL_VERSION}" major="${KUBECTL_VERSION%%.*}" minor="${KUBECTL_VERSION#*.}" \
    && minor="${minor%%.*}" ld="-s -w" \
    && for pkg in k8s.io/client-go/pkg/version k8s.io/component-base/version; do \
        ld="$ld -X $pkg.gitVersion=$v -X $pkg.gitMajor=$major -X $pkg.gitMinor=$minor \
            -X $pkg.gitCommit=${KUBECTL_COMMIT} -X $pkg.gitTreeState=clean"; \
       done \
    && go build -mod=readonly -ldflags "$ld" -o /out/kubectl .

FROM python:3.12.16-slim@sha256:b18b261e1b4974b4f321451ad5251ded85abb22c2b8b262da527dda1d031ab30

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG TERRAFORM_VERSION=1.17.1
ARG HELM_VERSION=4.3.1
ARG ANSIBLE_CORE_VERSION=2.21.5

# hadolint ignore=DL3008
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl unzip ca-certificates git openssh-client jq dnsutils dnsmasq socat \
        postgresql-client redis-tools \
    && rm -rf /var/lib/apt/lists/*

RUN set -eux; cd /tmp; \
    curl -fsSLo tf.zip "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip"; \
    unzip -q tf.zip terraform -d /usr/local/bin && rm tf.zip; \
    curl -fsSL "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz" | tar -xz --strip-components=1 -C /usr/local/bin linux-amd64/helm; \
    pip install --no-cache-dir "ansible-core==${ANSIBLE_CORE_VERSION}"

COPY --from=kubectl /out/kubectl /usr/local/bin/kubectl
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENV TF_PLUGIN_CACHE_DIR=/root/.terraform.d/plugin-cache \
    TF_IN_AUTOMATION=1
RUN mkdir -p /root/.terraform.d/plugin-cache
# Runs as root on purpose: the entrypoint's egress guard needs dnsmasq, resolv.conf and :80/:443.
# Local lab tool with no published ports.
WORKDIR /work
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]
