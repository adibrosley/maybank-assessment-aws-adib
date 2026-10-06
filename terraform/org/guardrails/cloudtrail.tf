# Organization trail. In a Control Tower landing zone this trail is created and
# managed by Control Tower; this extract shows the equivalent settings for clarity.
# Bucket and KMS key live in the Log Archive account.

resource "aws_cloudtrail" "org" {
  count                         = var.manage_org_trail ? 1 : 0
  name                          = "org-trail"
  is_organization_trail         = true
  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true # digest files prove integrity
  s3_bucket_name                = var.log_archive_bucket # Object Lock (compliance) enabled on the bucket
  kms_key_id                    = var.cloudtrail_kms_key_arn
  cloud_watch_logs_group_arn    = null

  # Data events on cardholder-data buckets only (cost control).
  advanced_event_selector {
    name = "CDE S3 object access"
    field_selector {
      field  = "eventCategory"
      equals = ["Data"]
    }
    field_selector {
      field  = "resources.type"
      equals = ["AWS::S3::Object"]
    }
    field_selector {
      field       = "resources.ARN"
      starts_with = var.cde_bucket_arn_prefixes
    }
  }

  advanced_event_selector {
    name = "All management events"
    field_selector {
      field  = "eventCategory"
      equals = ["Management"]
    }
  }

  insight_selector { insight_type = "ApiCallRateInsight" }
  insight_selector { insight_type = "ApiErrorRateInsight" }
}

variable "manage_org_trail" {
  type    = bool
  default = false # true only if not using Control Tower's trail
}

variable "log_archive_bucket" {
  type    = string
  default = ""
}

variable "cloudtrail_kms_key_arn" {
  type    = string
  default = null
}

variable "cde_bucket_arn_prefixes" {
  type    = list(string)
  default = ["arn:aws:s3:::payments-prod-cde-"]
}
