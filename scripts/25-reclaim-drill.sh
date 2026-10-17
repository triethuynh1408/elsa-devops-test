#!/usr/bin/env bash
# 25 - Spot reclaim drill: drain a spot node running quote-api while curling the
# service through the ingress, show the pods rescheduling, then uncordon.
# Fails if any request failed during the drill.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
ensure_toolbox "$@"
wait_for_bootstrap

NS=quote
SELECTOR=app.kubernetes.io/name=quote-api
WORK=$(mktemp -d)

pods_with_capacity() {
  kubectl get pods -n "$NS" -l "$SELECTOR" -o wide --no-headers \
    | while read -r name _ status _ _ _ node _; do
        cap=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.acme\.io/capacity}' 2>/dev/null)
        printf '  %-36s %-12s %-18s %s\n' "$name" "$status" "$node" "$cap"
      done
}

kubectl -n "$NS" rollout status deployment/quote-api --timeout=120s >/dev/null \
  || die "quote-api is not healthy - run 20-deploy.sh first"

# Pick the spot node that currently runs the most quote-api replicas.
NODE=""
for n in $(kubectl get pods -n "$NS" -l "$SELECTOR" -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' \
           | sort | uniq -c | sort -rn | awk '{print $2}'); do
  if [ "$(kubectl get node "$n" -o jsonpath='{.metadata.labels.acme\.io/capacity}')" = "spot" ]; then
    NODE=$n; break
  fi
done
[ -n "$NODE" ] || die "no quote-api replica runs on a spot node - nothing to drill"

cleanup() {
  kill "${CURL_PID:-}" "${WATCH_PID:-}" 2>/dev/null || true
  kubectl uncordon "$NODE" >/dev/null 2>&1 || true   # always give the node back
  rm -rf "$WORK"
}
trap cleanup EXIT

log "Before: spot node to reclaim = $NODE"
pods_with_capacity

log "Starting traffic: curl ${INGRESS_URL}/api/quote every 0.2s"
( while true; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "${INGRESS_URL}/api/quote" || true)
    echo "$(date +%T) $code"
    sleep 0.2
  done ) > "$WORK/curl.log" &
CURL_PID=$!
kubectl get pods -n "$NS" -l "$SELECTOR" -o wide --watch-only --output-watch-events > "$WORK/watch.log" 2>&1 &
WATCH_PID=$!
sleep 3

log "Simulating spot reclaim: kubectl drain $NODE"
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --timeout=180s

log "Waiting for replacement pods to become Ready"
for _ in $(seq 1 60); do
  READY=$(kubectl get deployment quote-api -n "$NS" -o jsonpath='{.status.readyReplicas}')
  WANT=$(kubectl get deployment quote-api -n "$NS" -o jsonpath='{.spec.replicas}')
  [ "${READY:-0}" -ge "$WANT" ] && break
  sleep 2
done
sleep 5   # a little more traffic after recovery
kill "$CURL_PID" "$WATCH_PID" 2>/dev/null || true

log "Pod events during the drill (rescheduling)"
cat "$WORK/watch.log"

log "After: placement with $NODE cordoned"
pods_with_capacity

TOTAL=$(wc -l < "$WORK/curl.log" | tr -d ' ')
OK=$(grep -c ' 200$' "$WORK/curl.log" || true)
FAILED=$((TOTAL - OK))
log "Traffic during the drill: ${TOTAL} requests, ${OK} OK, ${FAILED} failed"
[ "$FAILED" -eq 0 ] || grep -v ' 200$' "$WORK/curl.log" | head -20

log "Uncordoning $NODE"
kubectl uncordon "$NODE"
kubectl get nodes -L acme.io/capacity

[ "$FAILED" -eq 0 ] || die "${FAILED} requests failed during the drill"
log "Drill passed: the service stayed up while a spot node was reclaimed"
