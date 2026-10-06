# Task 6: Cost and Operations (AWS)

Figures are indicative monthly USD estimates at on-demand list prices for an Asia Pacific region and must be validated in the **AWS Pricing Calculator** for the final regions. See [assumptions](assumptions.md).

## 6.1 Material cost drivers

| Driver | Why it is material here | Indicative monthly |
|---|---|---|
| **AWS Shield Advanced** | Flat org-wide subscription (plus data transfer fees) | ~3,000 |
| **AWS Network Firewall** | Charged per endpoint-hour **per AZ** plus per GB processed; 3 AZs × 2 regions | ~1,800 + data |
| **Aurora PostgreSQL** | 3 instances primary + 1 in DR, storage, I/O, and **replicated write I/O** for Global Database | ~1,500 to 3,000 |
| **EKS** | Control plane per cluster (2 clusters) + nodes sized for N+1 across 3 AZs (≈ 50% headroom) | ~150 + 2,000 to 4,000 nodes |
| **Data transfer and processing** | TGW per-GB processing, NAT per-GB processing, cross-AZ traffic, cross-region replication | Highly variable; often the surprise line |
| **Direct Connect** | 2 dedicated ports + data transfer out | ~1,000 to 2,000 |
| **CloudWatch Logs** | Ingestion per GB (EKS control plane, app logs, flow logs, firewall logs) | ~500 to 2,000 |
| **Security tooling** | GuardDuty (incl. EKS/RDS protection), Security Hub, Config items, Inspector | ~500 to 1,500 |
| **Warm-standby DR** | Pre-provisioned DR stack | ~25 to 35% of primary |

## 6.2 Optimisation controls

| Control | Mechanism | Trade-off |
|---|---|---|
| **Compute Savings Plans** (1-year, no upfront) for baseline EKS node usage | Commit to $/hour; applies across instance families and regions | Commitment risk if migration slips; cover only the steady baseline (~60 to 70%) |
| **Aurora Reserved Instances** for writer/readers | Up to roughly 40% off for 1 year | Locks instance family; review before size changes |
| **Aurora I/O-Optimized** vs Standard | Switch when I/O exceeds about 25% of Aurora spend | Higher instance and storage price, no per-I/O charge |
| **Graviton** instances for EKS nodes and Aurora | Better price-performance | Container images must be multi-arch |
| **VPC endpoints** (S3/DynamoDB gateway: free; ECR, STS, Logs interface) | Removes NAT and TGW processing charges for AWS traffic | Interface endpoints have hourly cost per AZ; only add for high-volume services |
| Karpenter consolidation in non-prod; **Spot** for non-prod and batch | Bin-packing and cheaper capacity | Not used on the payment authorisation path |
| Non-prod scheduling | Scale non-prod EKS to zero and stop Aurora outside working hours | Developers lose evening access |
| Log tiering | CloudWatch Logs **Infrequent Access** class for audit-only logs, short retention in CloudWatch with S3 archive | Fewer query features on IA logs |
| Config recording | Periodic (daily) recording in non-prod; continuous in prod | Slower detection in non-prod |
| Governance | **Tag policies** (`cost-centre`, `env`, `app`) enforced at plan; **AWS Budgets** per account with alerts at 80/100%; **Cost Anomaly Detection** per account; Cost Categories per business unit | Requires tagging discipline, enforced by Conftest |

## 6.3 Service quotas

Quotas are **per account per region**. The most common DR failure is a DR region whose quotas were never raised to match primary.

| Quota | Why it matters |
|---|---|
| EC2 On-Demand Standard vCPU | EKS nodes; DR must absorb 100% load during failover |
| EC2 Spot vCPU (non-prod) | Karpenter Spot pools |
| VPCs per region, interface endpoints per VPC | Spoke and endpoint growth |
| Transit Gateway attachments, routes per TGW route table | Hub scale |
| Network Firewall: firewalls, rule group capacity | Rule growth |
| EIPs, NAT gateways per AZ | Egress design |
| Aurora DB instances, DB clusters, manual snapshots | DR and restore testing |
| ALBs per region, targets per ALB | Ingress scale |
| EKS clusters, managed node groups, Pod Identity associations | Platform scale |
| KMS request rate (cryptographic operations) | High-TPS encryption can throttle |
| AWS Backup: concurrent restore/copy jobs | Restore testing and DR copy windows |

**Controls:** quotas requested through Terraform (`aws_servicequotas_service_quota`) so primary and DR stay identical; CloudWatch alarms on `AWS/Usage` metrics at 80% of quota; quarterly quota review in the ops review; Service Quotas **quota request templates** at the Organization level so new accounts are created with raised limits.

## 6.4 Operational dashboards (CloudWatch)

| Dashboard | Key widgets | Alarm examples |
|---|---|---|
| **Service health (SLO)** | Request rate, error rate, p99 latency per AZ (golden signals); availability vs 99.95% error budget; Synthetics canary success | Burn-rate alarm: 2% of monthly budget in 1 h → page |
| **Data and DR** | `AuroraGlobalDBReplicationLag`, `AuroraGlobalDBRPOLag`, writer CPU/connections, RDS Proxy pinning, backup job success, last successful restore test | Replication lag > 60 s; backup failed; restore test failed |
| **Platform** | EKS node count per AZ, pending pods, Karpenter provisioning errors, ALB healthy hosts per AZ | Healthy hosts in any AZ < 2 |
| **Network** | TGW bytes/drops per attachment, Network Firewall dropped packets, DX connection state and BGP status, NAT errors | DX down; firewall drop spike |
| **Security** | Security Hub score, GuardDuty high findings, Config non-compliant resources, break-glass usage, drift job status | Any break-glass login; new critical finding |
| **Cost** | Daily spend per account, top services, anomaly alerts, Savings Plan coverage and utilisation | Budget 80%; anomaly |

Dashboards are deployed as code (`aws_cloudwatch_dashboard`) and shared cross-account to the operations account via **CloudWatch cross-account observability**.

## 6.5 Handover criteria (project → BAU operations)

The service moves to BAU only when **all** of these are evidenced:

| Area | Criterion | Evidence |
|---|---|---|
| Resilience | AZ failure test (FIS) passed with no customer impact; regional DR test met RTO ≤ 60 min and RPO ≤ 15 min | FIS report, DR test record with timings |
| Backup | 4 consecutive successful automated restore tests | AWS Backup restore testing history |
| Security | Zero critical/high open Security Hub findings; PCI DSS controls mapped and tested (control matrix) | Security Hub export, QSA sign-off |
| Monitoring | All alarms routed to on-call with runbook links; dashboards reviewed by ops | Alarm inventory |
| Runbooks | Incident, DR, break-glass, drift (Task 4), certificate rotation, EKS upgrade | Runbooks in repo, walked through |
| People | Ops team trained, has executed DR failover in staging themselves | Training log |
| Automation | 100% of infrastructure in Terraform, drift job green for 14 days | Jenkins history |
| Cost | Budgets and anomaly detection active, Savings Plan plan agreed | Budgets config |
| Ownership | RACI signed off; service catalogue entry; support contract (AWS Enterprise Support) in place | RACI document |
| Hypercare | 30-day hypercare with project team on call, then formal acceptance | Acceptance record |
