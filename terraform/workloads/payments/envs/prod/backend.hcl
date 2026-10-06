bucket       = "tfstate-222222222222-ap-southeast-5"
key          = "payments/prod/terraform.tfstate"
region       = "ap-southeast-5"
encrypt      = true
kms_key_id   = "alias/terraform-state"
use_lockfile = true # S3 native locking (Terraform >= 1.10); no DynamoDB table needed
