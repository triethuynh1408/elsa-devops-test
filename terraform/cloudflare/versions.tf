terraform {
  required_version = ">= 1.6.0" # variables inside import blocks need >= 1.6

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.28"
    }
  }
}
