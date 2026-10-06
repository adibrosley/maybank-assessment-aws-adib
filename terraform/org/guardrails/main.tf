# Organization guardrails. Deployed ONLY from the Management account (SCPs) and
# the Audit account (Config org rules) by the platform pipeline.
# App teams have no access to this stack's repo, state or deploy role.

terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
  backend "s3" {} # configured per account via -backend-config
}

provider "aws" {
  region = var.home_region
}

# Config org rules are created from the Audit (delegated admin) account.
provider "aws" {
  alias  = "audit"
  region = var.home_region
  assume_role {
    role_arn     = "arn:aws:iam::${var.audit_account_id}:role/platform-guardrails-deploy"
    session_name = var.session_name # set by Jenkins: jenkins-<job>-<build>
  }
}

# ---------------------------------------------------------------- SCPs
locals {
  scps = {
    protect-security  = { file = "scp-protect-security.json", targets = [var.root_id] }
    region-restriction = { file = "scp-region-restriction.json", targets = [var.root_id] }
    protect-network   = { file = "scp-protect-network.json", targets = [var.ou_ids["workloads"], var.ou_ids["sandbox"]] }
    data-protection   = { file = "scp-data-protection.json", targets = [var.ou_ids["prod"]] }
  }

  # Flatten to one entry per (policy, target) pair for attachments.
  scp_attachments = merge([
    for name, s in local.scps : {
      for t in s.targets : "${name}:${t}" => { policy = name, target = t }
    }
  ]...)
}

resource "aws_organizations_policy" "scp" {
  for_each    = local.scps
  name        = each.key
  description = "Managed by terraform/org/guardrails - do not edit in console"
  type        = "SERVICE_CONTROL_POLICY"
  content     = file("${path.module}/policies/${each.value.file}") # file(), not templatefile(): keeps ${aws:...} IAM variables literal
}

resource "aws_organizations_policy_attachment" "scp" {
  for_each  = local.scp_attachments
  policy_id = aws_organizations_policy.scp[each.value.policy].id
  target_id = each.value.target
}

# ---------------------------------------------------------------- Config org rules
locals {
  managed_rules = {
    "cloudtrail-enabled"            = "CLOUD_TRAIL_ENABLED"
    "cloudtrail-log-validation"     = "CLOUD_TRAIL_LOG_FILE_VALIDATION_ENABLED"
    "vpc-flow-logs-enabled"         = "VPC_FLOW_LOGS_ENABLED"
    "rds-storage-encrypted"         = "RDS_STORAGE_ENCRYPTED"
    "rds-cluster-multi-az"          = "RDS_CLUSTER_MULTI_AZ_ENABLED"
    "s3-bucket-public-access"       = "S3_BUCKET_LEVEL_PUBLIC_ACCESS_PROHIBITED"
    "restricted-ssh"                = "INCOMING_SSH_DISABLED"
    "root-hardware-mfa"             = "ROOT_ACCOUNT_HARDWARE_MFA_ENABLED"
    "eks-endpoint-no-public-access" = "EKS_ENDPOINT_NO_PUBLIC_ACCESS"
  }
}

resource "aws_config_organization_managed_rule" "this" {
  provider        = aws.audit
  for_each        = local.managed_rules
  name            = each.key
  rule_identifier = each.value
}

# Backup plans must meet the RPO-driven minimums.
resource "aws_config_organization_managed_rule" "backup_plan" {
  provider        = aws.audit
  name            = "backup-plan-min-frequency-retention"
  rule_identifier = "BACKUP_PLAN_MIN_FREQUENCY_AND_MIN_RETENTION_CHECK"
  input_parameters = jsonencode({
    requiredFrequencyValue = "1"
    requiredFrequencyUnit  = "hours"
    requiredRetentionDays  = "35"
  })
}

# ---------------------------------------------------------------- Real-time route-change alert
# Deployed per workload account via StackSets/Account Factory customisation in practice;
# shown here for one account as an extract.
resource "aws_cloudwatch_event_rule" "unauthorised_route_change" {
  name        = "unauthorised-route-change"
  description = "Route API called by anyone other than the network pipeline role"
  event_pattern = jsonencode({
    source        = ["aws.ec2"]
    "detail-type" = ["AWS API Call via CloudTrail"]
    detail = {
      eventName = ["CreateRoute", "ReplaceRoute", "DeleteRoute",
      "ReplaceRouteTableAssociation", "AssociateRouteTable", "DisassociateRouteTable"]
      userIdentity = {
        arn = [{ "anything-but" = { prefix = "arn:aws:sts::${var.example_workload_account_id}:assumed-role/platform-network-deploy/" } }]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "route_change_to_sns" {
  rule = aws_cloudwatch_event_rule.unauthorised_route_change.name
  arn  = var.security_alerts_topic_arn
}

# Break-glass usage alert (console sign-in by break-glass users).
resource "aws_cloudwatch_event_rule" "break_glass_used" {
  name = "break-glass-used"
  event_pattern = jsonencode({
    "detail-type" = ["AWS Console Sign In via CloudTrail"]
    detail = {
      userIdentity = { userName = [{ prefix = "breakglass-" }] }
    }
  })
}

resource "aws_cloudwatch_event_target" "break_glass_to_sns" {
  rule = aws_cloudwatch_event_rule.break_glass_used.name
  arn  = var.security_alerts_topic_arn
}
