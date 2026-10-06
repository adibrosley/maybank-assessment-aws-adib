variable "name" {
  type = string
}

variable "cidr_block" {
  type = string
  validation {
    condition     = can(cidrnetmask(var.cidr_block))
    error_message = "cidr_block must be a valid IPv4 CIDR."
  }
}

variable "az_count" {
  type    = number
  default = 3
  validation {
    condition     = var.az_count >= 2
    error_message = "At least 2 AZs are required for the availability target (3 recommended)."
  }
}

variable "transit_gateway_id" {
  type        = string
  default     = null
  description = "Shared TGW ID (via RAM). Null only in the personal lab."
}

variable "flow_log_bucket_arn" {
  type    = string
  default = null
}

variable "tags" {
  type    = map(string)
  default = {}
}
