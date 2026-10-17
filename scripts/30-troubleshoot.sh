#!/usr/bin/env bash
# 30 - Part 3: apply the fixed troubleshooting manifests and run the provided
# verifier. Works on a clean cluster or on top of broken-app.yaml.
# Diagnosis of each issue: TROUBLESHOOTING.md.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
ensure_toolbox "$@"
wait_for_bootstrap

log "Applying troubleshoot/fixed-app.yaml"
kubectl apply -f /workspace/troubleshoot/fixed-app.yaml

log "Waiting for rollouts"
kubectl -n troubleshoot rollout status deployment/web --timeout=180s
kubectl -n troubleshoot rollout status deployment/ai-inference --timeout=180s

log "Running troubleshoot/verify.sh"
sh /workspace/troubleshoot/verify.sh

log "Placement"
kubectl get pods -n troubleshoot -o wide
