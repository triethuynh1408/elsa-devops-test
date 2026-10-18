# Part 5b - Cloudflare DNS + cache rules (provider v5).
# Validate-only in this repo: `terraform init -backend=false && terraform validate`.

provider "cloudflare" {
  # Credentials come from the CLOUDFLARE_API_TOKEN environment variable - a token
  # scoped to this one zone (DNS:Edit, Cache Rules:Edit). Never in code or tfvars.
}

locals {
  api_hostname = "quote-api.${var.zone_name}"
}

# --- Proxied record for the service ------------------------------------------
resource "cloudflare_dns_record" "quote_api" {
  zone_id = var.zone_id
  name    = local.api_hostname
  type    = "CNAME"
  content = var.origin_hostname
  proxied = true # traffic goes through Cloudflare (CDN, WAF, hides the origin)
  ttl     = 1    # 1 = "automatic"; required for proxied records
  comment = "quote-api - managed by Terraform"
}

# --- Adopting a record that was created by hand in the dashboard -------------
# The import block (Terraform >= 1.5) is declarative and reviewable in a PR,
# unlike the one-off `terraform import` CLI. `terraform plan` shows the import
# plus any drift between this config and the live record; aim for zero changes,
# then the block can be removed after apply.
import {
  to = cloudflare_dns_record.status_page
  id = "${var.zone_id}/${var.status_record_id}" # v5 import ID: <zone_id>/<dns_record_id>
}

resource "cloudflare_dns_record" "status_page" {
  zone_id = var.zone_id
  name    = "status.${var.zone_name}"
  type    = "CNAME"
  content = var.status_page_target
  proxied = false
  ttl     = 300
  comment = "Created manually, adopted into Terraform"
}

# --- Cache rules ---------------------------------------------------------------
# A zone has exactly ONE ruleset per phase. If cache rules already exist (made in
# the dashboard), that ruleset must be imported too, or the apply will conflict.
# All matching rules apply in order and later rules override earlier ones, so the
# API bypass comes last and always wins for /api/*.
resource "cloudflare_ruleset" "cache_rules" {
  zone_id     = var.zone_id
  name        = "quote-api cache rules"
  description = "Aggressive caching for static assets, never cache the API"
  kind        = "zone"
  phase       = "http_request_cache_settings"

  rules = [
    {
      ref         = "cache_static_assets"
      description = "Static assets: cache 30 days at the edge, 1 day in browsers"
      expression  = "(http.host eq \"${local.api_hostname}\" and http.request.uri.path.extension in {\"css\" \"js\" \"mjs\" \"png\" \"jpg\" \"jpeg\" \"gif\" \"webp\" \"avif\" \"svg\" \"ico\" \"woff\" \"woff2\"})"
      action      = "set_cache_settings"
      action_parameters = {
        cache = true
        # Assumes fingerprinted file names (app.3f9c1.js), so a deploy changes the URL
        # and a long TTL is safe. Without fingerprinting, purge on deploy instead.
        edge_ttl = {
          mode    = "override_origin"
          default = 2592000 # 30 days
        }
        browser_ttl = {
          mode    = "override_origin"
          default = 86400 # 1 day: shorter, because a browser cache can't be purged
        }
      }
    },
    {
      ref         = "bypass_api"
      description = "Never cache API responses (dynamic, per-request)"
      expression  = "(http.host eq \"${local.api_hostname}\" and starts_with(http.request.uri.path, \"/api/\"))"
      action      = "set_cache_settings"
      action_parameters = {
        cache = false
      }
    },
  ]
}
