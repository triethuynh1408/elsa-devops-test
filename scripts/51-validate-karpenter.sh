#!/usr/bin/env bash
# 51 - Part 5a: validate the Karpenter manifests against the real Karpenter
# CRDs (pinned release) with a server-side dry run: the API server checks the
# OpenAPI schema AND the CRDs' CEL rules. Installs CRDs only - no controller,
# nothing is created in AWS.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
ensure_toolbox "$@"
wait_for_bootstrap

KARPENTER_VERSION=v1.15.0
CRD_URL="https://raw.githubusercontent.com/aws/karpenter-provider-aws/${KARPENTER_VERSION}/pkg/apis/crds"

log "Installing Karpenter ${KARPENTER_VERSION} CRDs (schemas only)"
for crd in karpenter.sh_nodepools karpenter.sh_nodeclaims karpenter.k8s.aws_ec2nodeclasses; do
  kubectl apply --server-side --force-conflicts -f "${CRD_URL}/${crd}.yaml"
done
kubectl wait --for=condition=Established --timeout=60s \
  crd/nodepools.karpenter.sh crd/nodeclaims.karpenter.sh crd/ec2nodeclasses.karpenter.k8s.aws

log "Server-side dry run of karpenter/*.yaml"
kubectl apply --dry-run=server -f /workspace/karpenter/

log "Karpenter manifests are valid for ${KARPENTER_VERSION} (karpenter.sh/v1, karpenter.k8s.aws/v1)"
