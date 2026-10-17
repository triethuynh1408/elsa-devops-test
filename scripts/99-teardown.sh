#!/usr/bin/env bash
# 99 - Delete the k3d cluster. Afterwards run `docker compose down` on the host.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
ensure_toolbox "$@"

# The cluster network can't be removed while the toolbox is still attached.
docker network disconnect "k3d-${CLUSTER_NAME}" "$(hostname)" 2>/dev/null || true
k3d cluster delete "$CLUSTER_NAME"
rm -f /workspace/kubeconfig "$BOOTSTRAP_STATUS"
log "Cluster deleted. Now run on the host: docker compose down"
