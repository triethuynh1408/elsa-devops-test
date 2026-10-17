#!/usr/bin/env bash
# 20 - Install ArgoCD and deploy quote-api through an ArgoCD Application
# (Helm chart synced from this Git repo). Then call it through the ingress.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
ensure_toolbox "$@"
wait_for_bootstrap

ARGOCD_CHART_VERSION=10.10.5   # ArgoCD v3.5.5
APP_NS=quote

log "Installing ArgoCD (chart ${ARGOCD_CHART_VERSION})"
helm upgrade --install argocd argo-cd \
  --repo https://argoproj.github.io/argo-helm --version "$ARGOCD_CHART_VERSION" \
  --namespace argocd --create-namespace \
  -f /workspace/platform/argocd-values.yaml \
  --wait --timeout 10m

log "Creating ArgoCD Application 'quote-api'"
kubectl apply -f /workspace/argocd/quote-api-app.yaml

log "Waiting for ArgoCD to sync and report Healthy"
for i in $(seq 1 60); do
  STATUS=$(kubectl get application quote-api -n argocd \
    -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || true)
  echo "  [$i] sync/health: ${STATUS:-pending}"
  [ "$STATUS" = "Synced/Healthy" ] && break
  [ "$i" -eq 60 ] && {
    kubectl get application quote-api -n argocd -o jsonpath='{.status.conditions}'; echo
    die "ArgoCD did not reach Synced/Healthy (is the repo public and pushed?)"
  }
  sleep 5
done
kubectl -n "$APP_NS" rollout status deployment/quote-api --timeout=180s

log "Pod placement (expected: 2 on spot, 1 on on-demand)"
kubectl get pods -n "$APP_NS" -o wide --no-headers \
  | while read -r name _ status _ _ _ node _; do
      cap=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.acme\.io/capacity}')
      printf '  %-36s %-10s %-18s %s\n' "$name" "$status" "$node" "$cap"
    done

log "Calling the service through the ingress"
for i in $(seq 1 30); do
  if curl -fsS --max-time 5 "${INGRESS_URL}/api/quote"; then echo; break; fi
  [ "$i" -eq 30 ] && die "ingress did not answer"
  sleep 2
done

log "Done. From the host: curl http://localhost:${HTTP_PORT}/api/quote"
echo "ArgoCD UI: kubectl -n argocd port-forward svc/argocd-server 8090:80 (user admin, password:"
echo "  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
