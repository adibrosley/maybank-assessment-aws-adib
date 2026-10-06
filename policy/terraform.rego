# Conftest (OPA) rules evaluated against `terraform show -json tfplan`.
# Run: conftest test --policy policy/ plan.json
package main

import rego.v1

changes := input.resource_changes

creating_or_updating(rc) if {
  some a in rc.change.actions
  a in {"create", "update"}
}

# 1. CDE route tables may never point at an Internet Gateway, NAT or peering.
deny contains msg if {
  some rc in changes
  rc.type == "aws_route"
  creating_or_updating(rc)
  after := rc.change.after
  some k in {"gateway_id", "nat_gateway_id", "vpc_peering_connection_id"}
  after[k] != null
  msg := sprintf("%s: routes must target the Transit Gateway, found %s=%v", [rc.address, k, after[k]])
}

# 1b. Same check for inline routes on aws_route_table.
deny contains msg if {
  some rc in changes
  rc.type == "aws_route_table"
  creating_or_updating(rc)
  some r in rc.change.after.route
  some k in {"gateway_id", "nat_gateway_id", "vpc_peering_connection_id"}
  r[k] != ""
  r[k] != null
  msg := sprintf("%s: inline route %v must target the Transit Gateway, found %s=%v", [rc.address, r.cidr_block, k, r[k]])
}

# 2. Data stores must not be destroyed by a normal pipeline run.
protected_types := {"aws_rds_cluster", "aws_rds_global_cluster", "aws_s3_bucket", "aws_backup_vault", "aws_kms_key"}

deny contains msg if {
  some rc in changes
  rc.type in protected_types
  "delete" in rc.change.actions
  msg := sprintf("%s: deleting a protected data resource requires a separate, approved change", [rc.address])
}

# 3. Storage must be encrypted.
deny contains msg if {
  some rc in changes
  rc.type in {"aws_rds_cluster", "aws_rds_global_cluster"}
  creating_or_updating(rc)
  rc.change.after.storage_encrypted != true
  msg := sprintf("%s: storage_encrypted must be true", [rc.address])
}

# 4. Application IAM roles must carry the permission boundary.
deny contains msg if {
  some rc in changes
  rc.type == "aws_iam_role"
  creating_or_updating(rc)
  startswith(rc.change.after.path, "/app/")
  not endswith(object.get(rc.change.after, "permissions_boundary", ""), ":policy/app-team-boundary")
  msg := sprintf("%s: app roles must use the app-team-boundary permission boundary", [rc.address])
}

# 5. Mandatory cost/ownership tags (via default_tags -> tags_all).
required_tags := {"app", "env", "cost-centre"}

taggable(rc) if rc.change.after.tags_all != null

deny contains msg if {
  some rc in changes
  creating_or_updating(rc)
  taggable(rc)
  some t in required_tags
  not rc.change.after.tags_all[t]
  msg := sprintf("%s: missing required tag '%s'", [rc.address, t])
}

# 6. Warn (not block) on any network-topology change, so reviewers look twice.
warn contains msg if {
  some rc in changes
  rc.type in {"aws_route", "aws_route_table", "aws_route_table_association", "aws_ec2_transit_gateway_vpc_attachment"}
  rc.change.actions != ["no-op"]
  msg := sprintf("%s: network topology change (%v), needs Network team review", [rc.address, rc.change.actions])
}
