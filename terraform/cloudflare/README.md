# Part 5b: Cloudflare in Terraform

**Provider:** `cloudflare/cloudflare` **~> 5.28**, written against the v5 schema read from the provider itself (`terraform providers schema -json`). Two v5 changes catch v4-era code:
- the record resource is now **`cloudflare_dns_record`**; `cloudflare_record` is gone;
- ruleset `rules` is a **list attribute** (`rules = [ { … } ]`), no longer repeated `rules { }` blocks.

The validation run rejected both v4 forms: `Invalid resource type` and `Unsupported block type`.

| Resource | Purpose |
|---|---|
| `cloudflare_dns_record.quote_api` | Proxied CNAME `quote-api.example.com` → origin (ALB) |
| `import` block + `cloudflare_dns_record.status_page` | Adopts a manually created record. The ID format is `<zone_id>/<record_id>` |
| `cloudflare_ruleset.cache_rules` (phase `http_request_cache_settings`) | Static assets cached 30 days at the edge and 1 day in browsers; `/api/*` bypasses the cache. The bypass rule is last, so it always wins |

**Validate (no credentials needed):** `./scripts/50-validate-tf.sh` runs `fmt -check`, `init -backend=false` and `validate`. `.terraform.lock.hcl` pins the provider with hashes for linux/darwin × amd64/arm64.

## Real use

- `export CLOUDFLARE_API_TOKEN=…`, using a token scoped to this zone (DNS:Edit, Cache Rules:Edit). Never put it in tfvars.
- Copy `terraform.tfvars.example` to `terraform.tfvars` and fill in the IDs.
- Add a remote backend for state, e.g. S3 with locking. It's omitted here because the setup is validate-only.

**Adopting the manual record:**
1. Run `terraform plan`. It should show `1 to import` and no changes.
2. If there is drift, align the config with the live record first.
3. Apply, then delete the `import` block.

**Before the first apply:** a zone can only have one cache-settings ruleset. If cache rules were already made in the dashboard, import that ruleset too.
