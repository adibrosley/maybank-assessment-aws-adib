# Control Matrix (AWS)

Type: **P** = preventive, **D** = detective, **C** = corrective. Framework references are indicative mappings to PCI DSS v4.0 requirement families and BNM RMiT themes.

| ID | Control objective | AWS implementation | Type | Owner | Evidence | PCI DSS v4.0 | Task |
|---|---|---|---|---|---|---|---|
| GOV-01 | Workloads isolated by environment and data classification | Organizations OUs, account per env, CDE in dedicated account | P | Platform | OU tree, account list | 1, 12.5.2 (scope) | 1 |
| GOV-02 | Guardrails cannot be changed by app teams | SCPs on OUs; SCP changes only via `platform-org` pipeline with Security approval | P | Platform | `list-policies-for-target`, PR history | 7.2 | 3 |
| GOV-03 | Only approved regions used | SCP-03 region deny | P | Platform | SCP JSON, CloudTrail `AccessDenied` | RMiT data residency | 3 |
| IAM-01 | No long-lived human credentials | IAM Identity Center + IdP MFA; no IAM users in workload accounts; Config `IAM_USER_*` checks | P/D | Security | Identity Center assignments, Config | 8.2, 8.4 | 3 |
| IAM-02 | App-created roles cannot escalate | Permission boundary `app-team-boundary` required on role creation | P | Platform | Boundary JSON, Access Analyzer | 7.2.1 | 3 |
| IAM-03 | Emergency access is controlled and alerted | Break-glass users with dual custody + FIDO2, `INC*` session names, EventBridge alert | P/D | Security | Alert history, quarterly test record | 8.2.2, 8.6 | 3 |
| IAM-04 | Root user not used | SCP deny root; centralised root access management; Config root MFA rule | P/D | Security | Config compliance | 8.2.2 | 3 |
| NET-01 | CDE has no direct internet path | Spoke VPC without IGW/NAT; default route to TGW; SCP-01 denies IGW/route changes | P | Network | Route tables, Reachability Analyzer | 1.3, 1.4 | 1, 4 |
| NET-02 | All egress and hybrid traffic inspected | Network Firewall in inspection VPC, appliance mode, default drop | P/D | Network/Security | Firewall policy, flow and alert logs | 1.2, 1.4 | 1 |
| NET-03 | Edge protection for public endpoint | CloudFront + WAF managed rules + Shield Advanced, enforced via Firewall Manager | P | Security | Firewall Manager compliance | 6.4.2 | 1 |
| NET-04 | DNS exfiltration blocked | Route 53 Resolver DNS Firewall allow-list for CDE | P | Network | DNS Firewall query logs | 1.4 | 1 |
| NET-05 | Route-table drift detected in near real time | EventBridge on route APIs, Config custom rule, hourly Terraform drift job | D | Network | Alerts, Config timeline | 11.5, 10.7 | 4 |
| DAT-01 | Data encrypted at rest | KMS CMKs (multi-Region for Aurora/S3); SCP + Config encryption rules; Checkov at plan | P/D | App/Security | Config, Checkov reports | 3.5 | 2, 3 |
| DAT-02 | Data encrypted in transit | TLS 1.2+ on CloudFront/ALB, Aurora `rds.force_ssl`, MACsec/IPsec on DX | P | App/Network | Listener policies, parameter groups | 4.2 | 1, 2 |
| DAT-03 | Secrets managed and rotated | Secrets Manager rotation, replicated to DR | P | App | Rotation history | 8.3.2 | 2 |
| RES-01 | Survive loss of one AZ | EKS topology spread + PDB, N+1 capacity, Aurora Multi-AZ, ALB cross-zone, ARC zonal autoshift | P | App/Platform | FIS AZ experiment report | 12.10 (BCP), RMiT | 2 |
| RES-02 | Regional DR within RTO 60 / RPO 15 | Warm standby, Aurora Global DB, ARC routing control | C | App/Platform | DR test timings | 12.10, RMiT | 2 |
| RES-03 | Backups immutable and restorable | AWS Backup cross-account/region copy, Vault Lock compliance, weekly restore testing | P/C | Security/App | Restore test results | 12.10.1, RMiT | 2 |
| LOG-01 | All API activity logged and tamper-evident | Org CloudTrail, log file validation, KMS, Object Lock in Log Archive | P/D | Security | `validate-logs` output | 10.2, 10.3, 10.5 | 3 |
| LOG-02 | Logs retained 12 months (3 immediately available) | S3 Object Lock 1 yr + Glacier; CloudTrail Lake 7 yr | P | Security | Bucket config | 10.5.1 | 3 |
| LOG-03 | Security events centrally monitored | GuardDuty, Security Hub, Detective (delegated admin in Audit) | D | Security | Security Hub dashboards | 10.4, 11.5 | 3 |
| CHG-01 | All prod changes automated and traceable | Jenkins pipeline only; deploy role assumable only by Jenkins; session name = build ID; source identity = approver | P/D | Platform | CloudTrail → build → evidence bucket chain | 6.5.1, 6.5.2 | 5 |
| CHG-02 | Peer approval, segregation of duties | Branch protection, CODEOWNERS, Jenkins `input` approver ≠ author | P | Platform | PR reviews, approval records | 6.5.4 | 5 |
| CHG-03 | Policy compliance checked before deployment | Checkov + Conftest on plan JSON | P | Platform/Security | Pipeline reports | 6.2, 6.5 | 5 |
| CHG-04 | Deployment evidence retained | Plan, approvals, logs in S3 Object Lock 7 yr | P | Platform | Evidence bucket | 10.5, 6.5 | 5 |
| OPS-01 | Capacity and quota risks managed | Service Quotas alarms, quota templates, quotas in Terraform for both regions | D | Platform | Usage alarms | RMiT capacity mgmt | 6 |
| OPS-02 | Cost governed | Budgets, Cost Anomaly Detection, tag policies | D | FinOps | Budget reports | n/a | 6 |
