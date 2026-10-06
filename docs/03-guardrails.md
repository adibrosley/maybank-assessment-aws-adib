# Task 3: Guardrails (AWS)

Guardrails are layered. Each layer answers a different question:

| Layer | Question it answers | Type | Can app team change it? |
|---|---|---|---|
| **SCP** (Organizations) | What is the *maximum* any principal in this account may do? | Preventive | No |
| **Permission boundary** (IAM) | What is the *maximum* a role created by the app team may do? | Preventive | No (they must attach it) |
| **AWS Config rules** | Is the deployed state compliant right now? | Detective / corrective | No |
| **CloudTrail controls** | Who did what, provably? | Detective / evidence | No |
| **Break-glass** | How do we act when the normal path is broken, safely? | Emergency | No |

SCPs and boundaries **never grant** permissions. They only cap them. An action is allowed only if identity policy allows it **and** no SCP, boundary or resource policy denies it.

Full JSON is in [`terraform/org/guardrails/policies/`](../terraform/org/guardrails/policies/) and is deployed by [`terraform/org/guardrails/`](../terraform/org/guardrails/).

## 3.1 SCP examples

### SCP-01 Protect network hub and routing (attached to Workloads OU)

Directly prevents the Task 4 incident. Only the platform pipeline role and break-glass role can modify routes.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyNetworkTopologyChanges",
      "Effect": "Deny",
      "Action": [
        "ec2:CreateRoute", "ec2:ReplaceRoute", "ec2:DeleteRoute",
        "ec2:CreateRouteTable", "ec2:DeleteRouteTable",
        "ec2:AssociateRouteTable", "ec2:DisassociateRouteTable",
        "ec2:ReplaceRouteTableAssociation",
        "ec2:AttachInternetGateway", "ec2:CreateInternetGateway",
        "ec2:CreateNatGateway", "ec2:CreateVpcPeeringConnection",
        "ec2:AcceptVpcPeeringConnection",
        "ec2:CreateTransitGatewayVpcAttachment", "ec2:DeleteTransitGatewayVpcAttachment"
      ],
      "Resource": "*",
      "Condition": {
        "ArnNotLike": {
          "aws:PrincipalArn": [
            "arn:aws:iam::*:role/platform-network-deploy",
            "arn:aws:iam::*:role/break-glass-admin"
          ]
        }
      }
    }
  ]
}
```

### SCP-02 Protect security services and logging (attached to Root, excluding Management)

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ProtectAuditTrail",
      "Effect": "Deny",
      "Action": [
        "cloudtrail:StopLogging", "cloudtrail:DeleteTrail", "cloudtrail:UpdateTrail",
        "cloudtrail:PutEventSelectors",
        "config:StopConfigurationRecorder", "config:DeleteConfigurationRecorder",
        "config:DeleteDeliveryChannel",
        "guardduty:DeleteDetector", "guardduty:DisassociateFromMasterAccount",
        "guardduty:UpdateDetector",
        "securityhub:DisableSecurityHub",
        "access-analyzer:DeleteAnalyzer",
        "ec2:DeleteFlowLogs", "logs:DeleteLogGroup"
      ],
      "Resource": "*",
      "Condition": {
        "ArnNotLike": { "aws:PrincipalArn": "arn:aws:iam::*:role/AWSControlTowerExecution" }
      }
    },
    {
      "Sid": "DenyLeaveOrg",
      "Effect": "Deny",
      "Action": "organizations:LeaveOrganization",
      "Resource": "*"
    },
    {
      "Sid": "DenyRootUser",
      "Effect": "Deny",
      "Action": "*",
      "Resource": "*",
      "Condition": { "StringLike": { "aws:PrincipalArn": "arn:aws:iam::*:root" } }
    }
  ]
}
```

### SCP-03 Region restriction (data residency, attached to Root)

Allows only primary and DR regions; global services (IAM, CloudFront, Route 53, Organizations, Support, WAF global) are exempted via `NotAction`.

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "DenyOutsideApprovedRegions",
    "Effect": "Deny",
    "NotAction": [
      "iam:*", "organizations:*", "route53:*", "route53-recovery-*:*",
      "cloudfront:*", "waf:*", "wafv2:*", "shield:*", "sts:*", "support:*",
      "budgets:*", "ce:*", "health:*", "trustedadvisor:*", "kms:*"
    ],
    "Resource": "*",
    "Condition": {
      "StringNotEquals": { "aws:RequestedRegion": ["ap-southeast-5", "ap-southeast-1"] }
    }
  }]
}
```

*Trade-off:* `kms:*` is exempted only because some global services call KMS in us-east-1 (for example CloudFront with ACM). Tighter scoping is possible and should be tested in the Policy-Staging OU first.

### SCP-04 Data protection (Prod OU)

Deny `rds:CreateDBCluster` when `rds:StorageEncrypted` is false, deny `s3:PutBucketPublicAccessBlock` changes that weaken settings, and require IMDSv2 via `ec2:MetadataHttpTokens = required` on `ec2:RunInstances`. See `policies/scp-data-protection.json`.

**SCP limits to remember:** 5 SCPs per target, 5,120 characters per policy, and they do not affect the Management account or service-linked roles. That is why the Management account runs no workloads.

## 3.2 Permission boundary for application teams

The app team's pipeline role can create IAM roles for their pods (IRSA / EKS Pod Identity), but **only if** the new role carries the boundary. Without this, "can create roles" is equivalent to "is administrator".

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowWorkloadServices",
      "Effect": "Allow",
      "Action": [
        "eks:*", "rds:*", "elasticloadbalancing:*", "ec2:Describe*",
        "ec2:CreateSecurityGroup", "ec2:AuthorizeSecurityGroup*", "ec2:RevokeSecurityGroup*",
        "ec2:CreateTags", "s3:*", "secretsmanager:*", "kms:Encrypt", "kms:Decrypt",
        "kms:GenerateDataKey*", "logs:*", "cloudwatch:*", "sqs:*", "sns:*",
        "ecr:*", "autoscaling:*", "backup:*"
      ],
      "Resource": "*"
    },
    {
      "Sid": "AllowRoleCreationOnlyWithBoundary",
      "Effect": "Allow",
      "Action": ["iam:CreateRole", "iam:PutRolePermissionsBoundary",
                 "iam:AttachRolePolicy", "iam:PutRolePolicy", "iam:DetachRolePolicy",
                 "iam:DeleteRolePolicy"],
      "Resource": "arn:aws:iam::*:role/app/*",
      "Condition": {
        "StringEquals": {
          "iam:PermissionsBoundary": "arn:aws:iam::${aws:PrincipalAccount}:policy/app-team-boundary"
        }
      }
    },
    {
      "Sid": "AllowPassAndReadAppRoles",
      "Effect": "Allow",
      "Action": ["iam:PassRole", "iam:GetRole", "iam:ListRole*", "iam:TagRole", "iam:DeleteRole"],
      "Resource": "arn:aws:iam::*:role/app/*"
    },
    {
      "Sid": "DenyBoundaryTampering",
      "Effect": "Deny",
      "Action": ["iam:DeleteRolePermissionsBoundary", "iam:CreatePolicyVersion",
                 "iam:DeletePolicy", "iam:SetDefaultPolicyVersion"],
      "Resource": ["arn:aws:iam::*:policy/app-team-boundary", "arn:aws:iam::*:role/*"]
    },
    {
      "Sid": "DenyPlatformResources",
      "Effect": "Deny",
      "Action": ["ec2:CreateRoute*", "ec2:ReplaceRoute*", "ec2:DeleteRoute*",
                 "ec2:AssociateRouteTable", "ec2:DisassociateRouteTable",
                 "ec2:CreateTransitGateway*", "ec2:DeleteTransitGateway*", "ec2:ModifyTransitGateway*",
                 "ec2:CreateVpc*", "ec2:DeleteVpc*", "ec2:ModifyVpc*", "ec2:AcceptVpc*",
                 "ec2:CreateInternetGateway", "ec2:AttachInternetGateway", "ec2:CreateNatGateway",
                 "cloudtrail:*", "config:Delete*", "config:Stop*",
                 "organizations:*", "account:*", "iam:CreateUser", "iam:CreateAccessKey"],
      "Resource": "*"
    }
  ]
}
```

The deny list names write actions only (for example `CreateRoute*`, not `*Route*`), because a wildcard like `ec2:*Vpc*` would also deny `DescribeVpcs` and break read-only tooling.

The SCP is the account-level ceiling; the boundary is the role-level ceiling. Using both means even an account admin cannot alter routing (SCP), and app-created roles cannot escalate (boundary).

## 3.3 AWS Config rules

Deployed as an **organization conformance pack** from the Audit account (delegated admin), so app teams cannot delete them. Starting point is the AWS-provided **Operational Best Practices for PCI DSS** conformance pack, plus these explicitly tracked rules:

| Rule (managed identifier) | Purpose | Remediation |
|---|---|---|
| `CLOUD_TRAIL_ENABLED`, `MULTI_REGION_CLOUD_TRAIL_ENABLED` | Org trail is on everywhere | Alert (SCP already prevents disabling) |
| `CLOUD_TRAIL_LOG_FILE_VALIDATION_ENABLED` | Tamper evidence | Alert |
| `VPC_FLOW_LOGS_ENABLED` | Network evidence | Auto-remediate (SSM Automation) |
| `RDS_CLUSTER_MULTI_AZ_ENABLED` | Resilience | Alert to app team |
| `RDS_STORAGE_ENCRYPTED`, `ENCRYPTED_VOLUMES` | Data at rest | Block at plan (Task 5) + alert |
| `S3_BUCKET_LEVEL_PUBLIC_ACCESS_PROHIBITED` | No public data | Auto-remediate |
| `RESTRICTED_INCOMING_TRAFFIC`, `VPC_SG_OPEN_ONLY_TO_AUTHORIZED_PORTS` | No open admin ports | Alert, high severity |
| `IAM_ROOT_ACCESS_KEY_CHECK`, `ROOT_ACCOUNT_HARDWARE_MFA_ENABLED` | Root hygiene | Alert |
| `BACKUP_PLAN_MIN_FREQUENCY_AND_MIN_RETENTION_CHECK` | RPO evidence | Alert |
| `EKS_CLUSTER_LOGGING_ENABLED`, `EKS_ENDPOINT_NO_PUBLIC_ACCESS` | Cluster audit, private API | Alert |
| **Custom: `route-table-approved-targets`** (Lambda, triggered on `AWS::EC2::RouteTable` change) | CDE route tables may only target the TGW or VPC endpoints; any route to an IGW/NAT/peering is NON_COMPLIANT | Alert P1 to network on-call (no auto-remediation; see Task 4 for why) |

**Trade-off on auto-remediation:** automatic fixes are safe for idempotent hardening (enable flow logs, block public S3). For routing, auto-reverting can fight a legitimate break-glass fix or cause an outage loop, so it alerts and the fix goes through the pipeline.

## 3.4 CloudTrail controls

| Control | Setting | Why |
|---|---|---|
| Organization trail | Created from Management account (Control Tower), all accounts, all regions | Member accounts cannot opt out |
| Log file integrity | `EnableLogFileValidation = true` | Digest files prove logs were not altered (verify with `aws cloudtrail validate-logs`) |
| Encryption | SSE-KMS with CMK in Log Archive; key policy allows CloudTrail to encrypt, only Security role to decrypt | Readers are separated from writers |
| Immutable storage | S3 Object Lock **compliance mode**, 1-year retention, then Glacier for 6 more years | PCI DSS 10.5.1: 12 months, 3 immediately available; RMiT record keeping |
| Data events | S3 object-level events on CDE buckets; Lambda invoke events | Who read cardholder files |
| **CloudTrail Lake** | Org event data store, 7-year retention | SQL investigation (used in Task 4) |
| CloudTrail Insights | API call-rate and error-rate insights | Detects unusual bursts (credential misuse) |
| Real-time alerting | EventBridge rules in each account forwarding to Security account event bus | Seconds-level detection of sensitive calls |

## 3.5 Safe break-glass pattern

Normal access is IAM Identity Center federated from the corporate IdP. Break-glass covers the case where **the IdP, Identity Center, or the pipeline is unavailable** during an incident.

| Element | Design |
|---|---|
| Identity | Two IAM users (`breakglass-1`, `breakglass-2`) in a dedicated, otherwise empty **Break-Glass account** in the Security OU; no access keys, console only |
| Authentication | Long random password stored in a physical safe (sealed envelope), **FIDO2 hardware MFA key** held by a different custodian. Two people are needed to use it |
| Authorisation | Users can only `sts:AssumeRole` into `break-glass-admin` roles in target accounts; role trust requires `aws:MultiFactorAuthPresent = true`, max session 1 h |
| SCP exemption | `break-glass-admin` is the only non-pipeline principal exempt from SCP-01, so emergency route fixes are possible |
| Detection | EventBridge rule on `ConsoleLogin` by breakglass users and `AssumeRole` into `break-glass-admin` → SNS → pager, security channel, and Security Hub finding (Severity: CRITICAL) |
| Accountability | Session name must be the incident ticket ID (enforced by `sts:RoleSessionName` condition, for example `INC*`) so every CloudTrail event links to the ticket |
| After use | Password rotated, envelope resealed, MFA re-verified; all changes made during the session are back-ported into Terraform and re-applied by the pipeline to clear drift |
| Testing | Quarterly test login, recorded as evidence |

Trust policy extract:

```json
{
  "Effect": "Allow",
  "Principal": { "AWS": "arn:aws:iam::111111111111:root" },
  "Action": ["sts:AssumeRole", "sts:SetSourceIdentity"],
  "Condition": {
    "Bool": { "aws:MultiFactorAuthPresent": "true" },
    "ArnLike": { "aws:PrincipalArn": "arn:aws:iam::111111111111:user/breakglass-*" },
    "StringLike": { "sts:RoleSessionName": "INC*" }
  }
}
```
