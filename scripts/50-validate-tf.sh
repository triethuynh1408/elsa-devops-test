#!/usr/bin/env bash
# 50 - Part 5b: validate the Cloudflare Terraform (no credentials, no state,
# nothing applied): fmt -check, init -backend=false, validate.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
ensure_toolbox "$@"

cd /workspace/terraform/cloudflare

log "terraform fmt -check"
terraform fmt -check -recursive -diff

log "terraform init -backend=false"
terraform init -backend=false -input=false

log "terraform validate"
terraform validate
