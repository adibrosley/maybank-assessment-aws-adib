variable "env" { type = string }
variable "cost_centre" { type = string }
variable "primary_region" { type = string }
variable "dr_region" { type = string }
variable "deploy_role_arn" { type = string }
variable "session_name" {
  type    = string
  default = "local-plan"
}
variable "source_identity" {
  type    = string
  default = null
}
variable "primary_cidr" { type = string }
variable "dr_cidr" { type = string }
variable "primary_tgw_id" { type = string }
variable "dr_tgw_id" { type = string }
variable "flow_log_bucket_arn" { type = string }
variable "aurora_engine_version" { type = string }
variable "aurora_instance_class" { type = string }
variable "primary_instance_count" {
  type    = number
  default = 3
  validation {
    condition     = var.primary_instance_count >= 2
    error_message = "Need at least writer + 1 reader in another AZ for Multi-AZ."
  }
}
variable "rds_monitoring_role_arn" { type = string }
variable "ops_alerts_topic_arn_dr" { type = string }
variable "backup_role_arn" { type = string }
variable "dr_backup_vault_arn" { type = string }
variable "central_backup_vault_arn" { type = string }
