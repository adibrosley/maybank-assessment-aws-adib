# Payments workload stack (extract). Same code for dev/staging/prod; differences
# live only in envs/<env>/terraform.tfvars. Deployed by Jenkins assuming
# terraform-deploy in the target account.

terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
  backend "s3" {} # see envs/<env>/backend.hcl
}

provider "aws" {
  region = var.primary_region
  assume_role {
    role_arn        = var.deploy_role_arn
    session_name    = var.session_name    # jenkins-<job>-<build>
    source_identity = var.source_identity # approver, persists in CloudTrail
  }
  default_tags { tags = local.tags }
}

provider "aws" {
  alias  = "dr"
  region = var.dr_region
  assume_role {
    role_arn        = var.deploy_role_arn
    session_name    = var.session_name
    source_identity = var.source_identity
  }
  default_tags { tags = local.tags }
}

locals {
  tags = {
    app         = "payments"
    env         = var.env
    cost-centre = var.cost_centre
    data-class  = "pci-cde"
    managed-by  = "terraform"
  }
}

# ---------------------------------------------------------------- Network (platform module, pinned)
module "vpc_primary" {
  source              = "../../modules/spoke-vpc" # in real life: git::...platform-modules//spoke-vpc?ref=v1.4.0
  name                = "payments-${var.env}"
  cidr_block          = var.primary_cidr
  az_count            = 3
  transit_gateway_id  = var.primary_tgw_id
  flow_log_bucket_arn = var.flow_log_bucket_arn
}

module "vpc_dr" {
  source              = "../../modules/spoke-vpc"
  providers           = { aws = aws.dr }
  name                = "payments-${var.env}-dr"
  cidr_block          = var.dr_cidr
  az_count            = 3
  transit_gateway_id  = var.dr_tgw_id
  flow_log_bucket_arn = var.flow_log_bucket_arn
}

# ---------------------------------------------------------------- KMS multi-Region key
resource "aws_kms_key" "data" {
  description         = "payments-${var.env} data key (multi-Region)"
  multi_region        = true
  enable_key_rotation = true
}

resource "aws_kms_replica_key" "data_dr" {
  provider        = aws.dr
  primary_key_arn = aws_kms_key.data.arn
}

# ---------------------------------------------------------------- Aurora Global Database
resource "aws_rds_global_cluster" "payments" {
  global_cluster_identifier = "payments-${var.env}"
  engine                    = "aurora-postgresql"
  engine_version            = var.aurora_engine_version
  storage_encrypted         = true
  deletion_protection       = true
}

resource "aws_db_subnet_group" "primary" {
  name       = "payments-${var.env}"
  subnet_ids = module.vpc_primary.data_subnet_ids
}

resource "aws_rds_cluster" "primary" {
  cluster_identifier            = "payments-${var.env}-primary"
  global_cluster_identifier     = aws_rds_global_cluster.payments.id
  engine                        = aws_rds_global_cluster.payments.engine
  engine_version                = aws_rds_global_cluster.payments.engine_version
  db_subnet_group_name          = aws_db_subnet_group.primary.name
  database_name                 = "payments"
  master_username               = "payments_admin"
  manage_master_user_password   = true # Secrets Manager owns the password; never in state
  storage_encrypted             = true
  kms_key_id                    = aws_kms_key.data.arn
  backup_retention_period       = 35
  preferred_backup_window       = "18:00-19:00" # 02:00-03:00 MYT
  deletion_protection           = true
  copy_tags_to_snapshot         = true
  iam_database_authentication_enabled = true
  enabled_cloudwatch_logs_exports     = ["postgresql"]

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [global_cluster_identifier] # managed failover changes membership
  }
}

# 1 writer + 2 readers, spread across AZs by RDS.
resource "aws_rds_cluster_instance" "primary" {
  count                        = var.primary_instance_count
  identifier                   = "payments-${var.env}-primary-${count.index}"
  cluster_identifier           = aws_rds_cluster.primary.id
  instance_class               = var.aurora_instance_class
  engine                       = aws_rds_cluster.primary.engine
  engine_version               = aws_rds_cluster.primary.engine_version
  performance_insights_enabled = true
  monitoring_interval          = 15
  monitoring_role_arn          = var.rds_monitoring_role_arn
}

resource "aws_db_subnet_group" "dr" {
  provider   = aws.dr
  name       = "payments-${var.env}-dr"
  subnet_ids = module.vpc_dr.data_subnet_ids
}

# Secondary (warm standby) cluster in the DR region. Promoted on failover.
resource "aws_rds_cluster" "dr" {
  provider                  = aws.dr
  cluster_identifier        = "payments-${var.env}-dr"
  global_cluster_identifier = aws_rds_global_cluster.payments.id
  engine                    = aws_rds_global_cluster.payments.engine
  engine_version            = aws_rds_global_cluster.payments.engine_version
  db_subnet_group_name      = aws_db_subnet_group.dr.name
  storage_encrypted         = true
  kms_key_id                = aws_kms_replica_key.data_dr.arn
  deletion_protection       = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "payments-${var.env}-dr-final"

  depends_on = [aws_rds_cluster_instance.primary]
  lifecycle {
    prevent_destroy = true
    ignore_changes  = [replication_source_identifier, global_cluster_identifier]
  }
}

resource "aws_rds_cluster_instance" "dr" {
  provider           = aws.dr
  count              = 1
  identifier         = "payments-${var.env}-dr-${count.index}"
  cluster_identifier = aws_rds_cluster.dr.id
  instance_class     = var.aurora_instance_class
  engine             = aws_rds_cluster.dr.engine
  engine_version     = aws_rds_cluster.dr.engine_version
}

# RPO guard: alarm well before the 15-minute RPO is at risk.
resource "aws_cloudwatch_metric_alarm" "global_db_lag" {
  provider            = aws.dr
  alarm_name          = "payments-${var.env}-global-db-replication-lag"
  namespace           = "AWS/RDS"
  metric_name         = "AuroraGlobalDBReplicationLag"
  dimensions          = { DBClusterIdentifier = aws_rds_cluster.dr.cluster_identifier }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 60000 # milliseconds = 60 s
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = [var.ops_alerts_topic_arn_dr]
  treat_missing_data  = "breaching"
}
