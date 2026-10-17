#!/usr/bin/env bash
# 10 - Wait for the bootstrap and show the simulated nodepools.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
ensure_toolbox "$@"
wait_for_bootstrap

log "Nodes and nodepool labels"
kubectl get nodes -L acme.io/capacity -L acme.io/node-type
log "Taints"
kubectl get nodes -o custom-columns='NODE:.metadata.name,TAINTS:.spec.taints[*].key'
