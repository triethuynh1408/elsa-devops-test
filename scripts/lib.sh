# shellcheck shell=bash
# Shared helpers, sourced by every numbered script.

CLUSTER_NAME="${CLUSTER_NAME:-elsa}"
HTTP_PORT="${HTTP_PORT:-8080}"
# Inside the k3d network the ingress is reachable via the load balancer container.
# shellcheck disable=SC2034  # used by the scripts that source this file
INGRESS_URL="http://k3d-${CLUSTER_NAME}-serverlb"
BOOTSTRAP_STATUS=/tmp/bootstrap.status

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# Scripts can be started from the host (./scripts/20-deploy.sh): in that case
# re-run the same script inside the toolbox, where kubectl/helm/k3d live.
# Usage (first line of each script): ensure_toolbox "$@"
ensure_toolbox() {
  [ "${ELSA_TOOLBOX:-}" = "1" ] && return 0
  local script repo tty_flag=""
  script=$(basename "${BASH_SOURCE[1]}")
  repo=$(cd "$(dirname "${BASH_SOURCE[1]}")/.." && pwd)
  [ -t 0 ] && [ -t 1 ] || tty_flag="-T"
  cd "$repo" || exit 1
  docker compose ps --status running toolbox --quiet | grep -q . \
    || die "toolbox is not running - start it with: docker compose up -d"
  exec docker compose exec $tty_flag toolbox bash "/workspace/scripts/${script}" "$@"
}

# Block until the compose bootstrap (00-bootstrap-cluster.sh) has finished.
wait_for_bootstrap() {
  local i=0 status
  while [ "$i" -lt 180 ]; do
    status=$(cat "$BOOTSTRAP_STATUS" 2>/dev/null || echo "pending")
    case "$status" in
      ok) return 0 ;;
      failed) die "cluster bootstrap failed - see: docker compose logs toolbox" ;;
    esac
    [ "$i" -eq 0 ] && log "Waiting for cluster bootstrap to finish (docker compose logs -f toolbox)..."
    sleep 5
    i=$((i + 1))
  done
  die "timed out waiting for cluster bootstrap"
}
