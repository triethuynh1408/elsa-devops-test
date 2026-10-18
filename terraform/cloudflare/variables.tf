variable "zone_id" {
  description = "Cloudflare zone ID of example.com."
  type        = string
}

variable "zone_name" {
  description = "Apex domain of the zone."
  type        = string
  default     = "example.com"
}

variable "origin_hostname" {
  description = "Origin the proxied record points to, e.g. the ALB DNS name in front of EKS."
  type        = string
}

variable "status_record_id" {
  description = "ID of the manually created status.example.com record to adopt (Cloudflare dashboard or API: GET /zones/{zone_id}/dns_records?name=status.example.com)."
  type        = string
}

variable "status_page_target" {
  description = "Current target of the manually created status record. Must match what exists, so the import shows no changes."
  type        = string
}
