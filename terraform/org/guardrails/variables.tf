variable "home_region" {
  type    = string
  default = "ap-southeast-5"
}

variable "root_id" {
  type        = string
  description = "Organizations root ID (r-xxxx)"
}

variable "ou_ids" {
  type        = map(string)
  description = "OU IDs keyed by: workloads, prod, nonprod, sandbox, security, infrastructure"
}

variable "audit_account_id" {
  type = string
}

variable "example_workload_account_id" {
  type = string
}

variable "security_alerts_topic_arn" {
  type = string
}

variable "session_name" {
  type    = string
  default = "local-plan"
}
