#!/usr/bin/env bash
# Build the quote-api image for amd64 + arm64 and push it to GHCR,
# tagged with the git SHA of the current commit (+ a floating `latest`).
#
# Runs on the HOST (needs docker + buildx), not in the toolbox container.
# Not numbered on purpose: run-all.sh never rebuilds images; the reviewer
# pulls the published one. In Part 4 GitHub Actions takes over this job.
#
# Usage: GHCR_USER=<github-username> ./scripts/build-push.sh
set -euo pipefail

cd "$(dirname "$0")/.."

GHCR_USER="${GHCR_USER:?set GHCR_USER to your GitHub username}"
OWNER=$(echo "$GHCR_USER" | tr '[:upper:]' '[:lower:]')   # registry paths must be lowercase
IMAGE="ghcr.io/${OWNER}/quote-api"

# The tag must describe exactly what is in the image: refuse uncommitted changes.
if [ -n "$(git status --porcelain)" ] && [ "${ALLOW_DIRTY:-0}" != "1" ]; then
  echo "ERROR: working tree has uncommitted changes; commit first so the SHA tag is honest." >&2
  exit 1
fi
SHA=$(git rev-parse --short=7 HEAD)

# A docker-container builder is required for multi-platform builds.
docker buildx inspect quote-builder >/dev/null 2>&1 \
  || docker buildx create --name quote-builder --driver docker-container >/dev/null

echo "Building ${IMAGE}:${SHA} for linux/amd64,linux/arm64 ..."
docker buildx build \
  --builder quote-builder \
  --platform linux/amd64,linux/arm64 \
  --build-arg APP_VERSION="${SHA}" \
  --label org.opencontainers.image.source="https://github.com/${GHCR_USER}/$(basename "$PWD")" \
  --label org.opencontainers.image.revision="$(git rev-parse HEAD)" \
  --tag "${IMAGE}:${SHA}" \
  --tag "${IMAGE}:latest" \
  --push \
  app/

echo ""
echo "Pushed: ${IMAGE}:${SHA}"
docker buildx imagetools inspect "${IMAGE}:${SHA}" | head -20
