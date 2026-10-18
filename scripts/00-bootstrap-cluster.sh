#!/usr/bin/env bash
# 00 - Create (or restart) the k3d cluster, connect the toolbox to it and
# prepare the nodepools. Runs automatically when the toolbox container starts;
# safe to re-run by hand.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
ensure_toolbox "$@"

echo running > "$BOOTSTRAP_STATUS"
trap '[ "$(cat $BOOTSTRAP_STATUS)" = ok ] || echo failed > "$BOOTSTRAP_STATUS"' EXIT

if k3d cluster get "$CLUSTER_NAME" >/dev/null 2>&1; then
  log "Cluster '$CLUSTER_NAME' exists - starting it (no-op if already running)"
  k3d cluster start "$CLUSTER_NAME"
else
  log "Creating k3d cluster '$CLUSTER_NAME' (1 server + 4 agents)"
  k3d cluster create --config /workspace/k3d/cluster.yaml --port "${HTTP_PORT}:80@loadbalancer"
fi

# The toolbox reaches the API server by container name on the cluster network.
NETWORK="k3d-${CLUSTER_NAME}"
SELF=$(hostname)
if ! docker inspect "$SELF" --format '{{json .NetworkSettings.Networks}}' | grep -q "\"${NETWORK}\""; then
  log "Connecting toolbox to network ${NETWORK}"
  docker network connect "$NETWORK" "$SELF"
fi

log "Writing kubeconfig"
mkdir -p ~/.kube
k3d kubeconfig get "$CLUSTER_NAME" \
  | sed -E "s#server: https://[^:]+:[0-9]+#server: https://k3d-${CLUSTER_NAME}-serverlb:6443#" > ~/.kube/config
chmod 600 ~/.kube/config
# Separate file for the host (gitignored) - never touches ~/.kube/config.
# Use per command: KUBECONFIG=./kubeconfig kubectl get nodes
k3d kubeconfig get "$CLUSTER_NAME" > /workspace/kubeconfig
chmod 600 /workspace/kubeconfig

log "Waiting for all 5 nodes to be Ready"
for _ in $(seq 1 60); do
  [ "$(kubectl get nodes --no-headers 2>/dev/null | wc -l)" -ge 5 ] && break
  sleep 3
done
kubectl wait --for=condition=Ready nodes --all --timeout=180s

log "Preparing nodepools (troubleshoot/prepare.sh)"
sh /workspace/troubleshoot/prepare.sh

log "Ingress controller: 2 Traefik replicas + PDB so a spot drain can't take ingress down"
kubectl apply -f /workspace/platform/traefik-config.yaml
# k3s applies the HelmChartConfig asynchronously (helm-install job). Wait until
# Traefik actually runs with it, so a drain right after bootstrap is safe.
for _ in $(seq 1 100); do
  kubectl -n kube-system get deploy traefik -o jsonpath='{.spec.replicas} {.spec.template.spec.containers[0].args}' 2>/dev/null \
    | grep -q '^2 .*requestAcceptGraceTimeout' && break
  sleep 3
done
kubectl -n kube-system rollout status deploy/traefik --timeout=180s

echo ok > "$BOOTSTRAP_STATUS"
log "Bootstrap complete"
