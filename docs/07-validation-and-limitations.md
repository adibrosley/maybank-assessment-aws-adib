# Exclusions, Validation, Known Limitations, Sources and AI Assistance

Assumptions (regional, RTO/RPO and cost) are in [assumptions.md](assumptions.md). This document covers the remaining items the brief asks to be documented.

## 1. Exclusions (out of scope)

| Excluded | Reason / where it would be handled |
|---|---|
| Application code changes, data migration (AWS DMS/SCT) and the cutover plan from the data centre | Migration wave planning is a separate workstream; this submission covers the target platform |
| Card-scheme, HSM and core-banking integration detail | Depends on the bank's existing providers; only connectivity (DX/VPN) and the HSM options are considered (assumption A7) |
| Full IP address plan and on-premises router/firewall configuration | Requires the existing DC network design |
| Kubernetes manifests, Helm charts and Argo Rollouts configuration | Application release design is referenced in Task 5 but not written out |
| Identity provider (IdP) configuration and Identity Center permission-set definitions | Organisation-specific |
| Formal PCI DSS assessment and BNM regulatory submissions | Control matrix maps controls to requirements; assessment is done by a QSA and the compliance function |
| Priced bill of materials | Cost figures are planning estimates (see §3) |

## 2. Validation performed

### 2.1 Static checks (during preparation)

| Check | Result |
|---|---|
| Conftest/OPA rules in `policy/` run against a sample **non-compliant** plan (route to IGW, unencrypted and deleted Aurora) and a **compliant** plan | Non-compliant plan denied with the expected messages; compliant plan passed |
| Mermaid diagrams in `docs/` parsed with the `mermaid` library | All diagrams syntactically valid (syntax check, not a visual render) |
| `terraform fmt -check`, `terraform validate`, `tflint`, Checkov on `lab/` (in the pipeline) | Pass; Checkov findings reported in soft-fail mode as designed for non-prod |

### 2.2 End-to-end lab run on AWS (12 Oct 2026)

The [`lab/`](../lab/) stack was deployed and operated through the [`Jenkinsfile`](../Jenkinsfile) in a personal AWS sandbox account (Terraform 1.15, AWS provider 6.x, Jenkins 2.541, S3 remote state with native locking and SSE-KMS).

| Step | What was done | Observed result |
|---|---|---|
| Bootstrap | State bucket + KMS key with Terraform (local state) | 7 resources created; versioning, KMS encryption, TLS-only policy |
| Plan | `ACTION=plan` | fmt/validate/tflint pass; Checkov soft-fail findings; Conftest **warn** on route-table changes (rule 6, requires Network review) |
| Apply | `ACTION=apply`, approval by `admin`, saved plan applied | VPC, subnets, route table and associations created; post-apply plan clean; plan, apply log and `evidence.json` uploaded to S3 |
| Simulated incident | IGW created and `0.0.0.0/0 → IGW` added to the private route table in the console | Route present |
| Detect | `ACTION=drift-check` | Build UNSTABLE, plan showed the rogue route to be removed |
| Identify actor | CloudTrail `CreateRoute` event | `userIdentity` (role session via Identity Center, `onBehalfOf.userId`), `sourceIPAddress`, browser `userAgent`, `sessionCredentialFromConsole: true`, `mfaAuthenticated: false`, exact route table and gateway in `requestParameters` |
| Restore | `ACTION=apply` with approval | Plan `0 to add, 1 to change, 0 to destroy` (route only); applied; state lock acquired and released |
| Clean up rogue resource | IGW detached and deleted manually (not managed by Terraform) | Final `drift-check` green: infrastructure matches Git |

**Region deviation:** the lab ran in `ap-southeast-2`, not the `ap-southeast-1` default in code. The sandbox account was created with AWS's new "projects" sign-up, which applies an AWS-managed SCP that limits the account to one home Region. The first bootstrap attempt in `ap-southeast-1` was denied by that SCP (`kms:CreateKey`, `s3:CreateBucket`, explicit deny). The Region was overridden at run time (`-var region=…`, Jenkins `TF_VAR_region`) without changing code.

## 3. Known limitations

| # | Limitation | Impact / mitigation |
|---|---|---|
| L1 | Only the `lab/` slice was deployed. Control Tower, Organizations/SCPs, Transit Gateway, Network Firewall, EKS, Aurora Global Database, AWS Backup and Config org rules are design and Terraform extracts that **have not been applied** to a real organisation | Would be validated in a dedicated landing-zone sandbox, starting with SCPs in the Policy-Staging OU |
| L2 | **Defect found and fixed during the lab:** the plan step piped `terraform plan -detailed-exitcode` through `tee`, so the shell returned `tee`'s exit code (0). Changes and drift were never detected, and Approval/Apply were skipped | Fixed: the plan is written to a file and Terraform's exit code is preserved. Lesson: control gates need a negative test, not just a green run |
| L3 | **Lab image fixes:** the tflint install script failed silently, and Checkov's pip install conflicted with a Debian-managed package | Fixed in `jenkins/Dockerfile` (direct tflint release download with version check; `--ignore-installed` for Checkov) |
| L4 | The lab uses static access keys and a single approver (`admin`); author ≠ approver is enforced only for `prod` | Acceptable for a personal lab only; the design uses role assumption and two-person approval (Task 5) |
| L5 | The Jenkinsfile implements one approval step plus the author ≠ approver check; the two-approver production rule in Task 5 relies on branch protection plus the Jenkins approver group | A second `input` step restricted to a different group would enforce it in Jenkins itself |
| L6 | Lab evidence is stored in the state bucket without S3 Object Lock | Design stores evidence in an Object Lock (compliance mode) bucket in Log Archive |
| L7 | Terraform drift detection only covers resources Terraform manages. The rogue IGW in the lab was invisible to the plan; only the route that used it was detected | Covered in the design by EventBridge on EC2 API calls, Config rules and Network Access Analyzer (Task 4) |
| L8 | Service availability in `ap-southeast-5` (Aurora Global Database, Network Firewall, ARC) was not verified (assumption A1) | Check AWS Regional Services list before committing to the primary Region |
| L9 | Cost figures are indicative on-demand estimates, not AWS Pricing Calculator outputs; the composite availability figure depends on current AWS SLA values | Validate in Pricing Calculator and against current SLA pages |

## 4. Sources

AWS documentation
- AWS Organizations, service control policies: https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html
- IAM permissions boundaries: https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_boundaries.html
- AWS Control Tower: https://docs.aws.amazon.com/controltower/latest/userguide/what-is-control-tower.html
- AWS Config managed rules: https://docs.aws.amazon.com/config/latest/developerguide/managed-rules-by-aws-config.html
- CloudTrail Lake: https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-lake.html
- Transit Gateway, including appliance mode: https://docs.aws.amazon.com/vpc/latest/tgw/transit-gateway-appliance-scenario.html
- AWS Network Firewall: https://docs.aws.amazon.com/network-firewall/latest/developerguide/what-is-aws-network-firewall.html
- Aurora Global Database: https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/aurora-global-database.html
- Route 53 Application Recovery Controller: https://docs.aws.amazon.com/r53recovery/latest/dg/what-is-route53-recovery.html
- AWS Backup restore testing: https://docs.aws.amazon.com/aws-backup/latest/devguide/restore-testing.html
- AWS Backup Vault Lock: https://docs.aws.amazon.com/aws-backup/latest/devguide/vault-lock.html
- S3 Replication Time Control: https://docs.aws.amazon.com/AmazonS3/latest/userguide/replication-time-control.html
- Disaster recovery options in the cloud (whitepaper): https://docs.aws.amazon.com/whitepapers/latest/disaster-recovery-workloads-on-aws/disaster-recovery-options-in-the-cloud.html
- New sign-up experience and its Region/service limits (relevant to §2.2): https://docs.aws.amazon.com/accounts/latest/reference/sign-in-new.html

Tooling
- Terraform S3 backend (native locking): https://developer.hashicorp.com/terraform/language/backend/s3
- Conftest: https://www.conftest.dev/
- Checkov: https://www.checkov.io/

Regulatory and standards
- BNM Risk Management in Technology (RMiT) policy document: https://www.bnm.gov.my/-/pd-rmit-nov25
- PCI Security Standards Council (PCI DSS): https://www.pcisecuritystandards.org/

## 5. AI assistance

This submission was prepared with substantial help from an AI assistant, **Claude (Anthropic)**.

| Area | AI assistance | My role |
|---|---|---|
| Design documents (Tasks 1 to 6), architecture diagrams, control matrix | Drafted the documents and Mermaid diagrams | Set the brief and constraints; reviewed the design against patterns I have operated (multi-account AWS, Transit Gateway hub-and-spoke, EKS with Karpenter, Terraform pipelines) |
| Terraform, OPA policy, Jenkinsfile, lab | Wrote the code and the static policy tests | Reviewed, deployed and operated the lab end to end on AWS (§2.2) |
| Troubleshooting during the lab | Helped diagnose the SCP Region restriction, credential error and the `tee` exit-code defect | Ran every step, confirmed results in AWS and Jenkins, applied the fixes |

AI-generated content was checked through the validation in §2. Defects found that way are listed in §3 rather than silently corrected.
