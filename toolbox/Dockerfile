# Toolbox: every CLI the scripts need, pinned and checksum-verified.
# Multi-arch: TARGETARCH is set by BuildKit (amd64 on most reviewers, arm64 on Apple Silicon).
FROM alpine:3.22

ARG TARGETARCH
ARG K3D_VERSION=v5.9.0
ARG KUBECTL_VERSION=v1.36.5
ARG HELM_VERSION=v3.22.1
ARG TERRAFORM_VERSION=1.16.6
ARG K6_VERSION=v2.3.0

RUN apk add --no-cache bash curl jq git docker-cli coreutils ca-certificates unzip

WORKDIR /tmp/dl
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

# k3d
RUN curl -fsSLO "https://github.com/k3d-io/k3d/releases/download/${K3D_VERSION}/k3d-linux-${TARGETARCH}" \
 && curl -fsSL "https://github.com/k3d-io/k3d/releases/download/${K3D_VERSION}/checksums.txt" \
    | grep " _dist/k3d-linux-${TARGETARCH}$" | sed 's# _dist/# #' | sha256sum -c - \
 && install -m 0755 "k3d-linux-${TARGETARCH}" /usr/local/bin/k3d

# kubectl
RUN curl -fsSLO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
 && echo "$(curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl.sha256")  kubectl" | sha256sum -c - \
 && install -m 0755 kubectl /usr/local/bin/kubectl

# helm
RUN f="helm-${HELM_VERSION}-linux-${TARGETARCH}.tar.gz" \
 && curl -fsSLO "https://get.helm.sh/${f}" \
 && curl -fsSL "https://get.helm.sh/${f}.sha256sum" | sha256sum -c - \
 && tar -xzf "$f" && install -m 0755 "linux-${TARGETARCH}/helm" /usr/local/bin/helm

# terraform
RUN f="terraform_${TERRAFORM_VERSION}_linux_${TARGETARCH}.zip" \
 && curl -fsSLO "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/${f}" \
 && curl -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_SHA256SUMS" \
    | grep " ${f}$" | sha256sum -c - \
 && unzip -q "$f" terraform && install -m 0755 terraform /usr/local/bin/terraform

# k6
RUN f="k6-${K6_VERSION}-linux-${TARGETARCH}.tar.gz" \
 && curl -fsSLO "https://github.com/grafana/k6/releases/download/${K6_VERSION}/${f}" \
 && curl -fsSL "https://github.com/grafana/k6/releases/download/${K6_VERSION}/k6-${K6_VERSION}-checksums.txt" \
    | grep " ${f}$" | sha256sum -c - \
 && tar -xzf "$f" && install -m 0755 "k6-${K6_VERSION}-linux-${TARGETARCH}/k6" /usr/local/bin/k6

WORKDIR /workspace
RUN rm -rf /tmp/dl \
 && k3d version && kubectl version --client && helm version --short && terraform version && k6 version
