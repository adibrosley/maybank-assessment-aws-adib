# AWS Backup: continuous (PITR) + daily, copied cross-region and cross-account
# to a Vault-Locked vault in the Backup account (Security OU).

resource "aws_backup_vault" "primary" {
  name        = "payments-${var.env}"
  kms_key_arn = aws_kms_key.data.arn
}

resource "aws_backup_plan" "payments" {
  name = "payments-${var.env}"

  rule {
    rule_name                = "continuous-pitr"
    target_vault_name        = aws_backup_vault.primary.name
    schedule                 = "cron(0 * * * ? *)"
    enable_continuous_backup = true
    lifecycle { delete_after = 35 }
  }

  rule {
    rule_name         = "daily-copy"
    target_vault_name = aws_backup_vault.primary.name
    schedule          = "cron(0 19 * * ? *)" # 03:00 MYT
    lifecycle { delete_after = 35 }

    copy_action { # cross-region (DR)
      destination_vault_arn = var.dr_backup_vault_arn
      lifecycle { delete_after = 35 }
    }
    copy_action { # cross-account, Vault Lock compliance mode
      destination_vault_arn = var.central_backup_vault_arn
      lifecycle { delete_after = 365 }
    }
  }
}

resource "aws_backup_selection" "payments" {
  name         = "payments-${var.env}-aurora"
  plan_id      = aws_backup_plan.payments.id
  iam_role_arn = var.backup_role_arn
  resources    = [aws_rds_cluster.primary.arn]
}

# Automated restore validation (weekly). A Lambda subscribed to restore-testing
# events runs row-count / checksum queries and reports the result.
resource "aws_backup_restore_testing_plan" "weekly" {
  name                = "payments_${var.env}_weekly"
  schedule_expression = "cron(0 20 ? * SUN *)"

  recovery_point_selection {
    algorithm             = "LATEST_WITHIN_WINDOW"
    include_vaults        = [aws_backup_vault.primary.arn]
    recovery_point_types  = ["SNAPSHOT"]
    selection_window_days = 7
  }
}

resource "aws_backup_restore_testing_selection" "aurora" {
  name                      = "aurora"
  restore_testing_plan_name = aws_backup_restore_testing_plan.weekly.name
  protected_resource_type   = "Aurora"
  iam_role_arn              = var.backup_role_arn
  protected_resource_arns   = [aws_rds_cluster.primary.arn]
  validation_window_hours   = 4
  # Restore into the isolated data subnets; verify override key names against the
  # AWS Backup restore-metadata reference for Aurora before use.
  restore_metadata_overrides = {
    dbsubnetgroupname = aws_db_subnet_group.primary.name
  }
}
