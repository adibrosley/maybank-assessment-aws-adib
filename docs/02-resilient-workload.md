# Task 2: Resilient Workload (AWS)

## 2.1 Targets translated into design budgets

| Target | Meaning | Design consequence |
|---|---|---|
| 99.95% availability | About 21.9 minutes of unplanned downtime per month | Must survive the loss of one AZ with **no** manual action. Regional DR alone cannot meet this, because failover itself takes longer than the monthly budget. |
| RTO 60 min | Service restored in the DR region within 60 min of declaring disaster | Warm standby: infrastructure already deployed in DR, only scale-up and promotion needed |
| RPO 15 min | At most 15 min of committed transactions lost | Continuous replication (seconds), not periodic snapshots |

**Key point:** in-region Multi-AZ delivers the 99.95%. Cross-region DR delivers the RTO/RPO for a regional event. They are two different mechanisms for two different failure domains.

## 2.2 Compute: Amazon EKS across 3 AZs

| Component | Configuration | Why |
|---|---|---|
| EKS control plane | AWS-managed, runs across 3 AZs | Control plane HA is AWS's responsibility |
| Nodes | **Karpenter** NodePools across 3 AZ subnets, mixed instance families, On-Demand for payments-api (no Spot for the transaction path) | Spot interruption risk is acceptable for batch, not for card authorisation |
| Spread | `topologySpreadConstraints` on `topology.kubernetes.io/zone`, `maxSkew: 1`, `whenUnsatisfiable: DoNotSchedule` | Guarantees pods exist in every AZ |
| Disruption | `PodDisruptionBudget` `minAvailable: 66%`; Karpenter disruption budgets limit node churn | Upgrades and consolidation cannot take out capacity |
| Headroom | Replicas sized so **2 AZs carry 100% of peak** (N+1 at AZ level) | Surviving an AZ loss without waiting for scale-up |
| Ingress | ALB (AWS Load Balancer Controller), IP targets, cross-zone on, health checks on `/healthz` with dependency checks | ALB removes unhealthy AZ targets in seconds |
| Zonal shift | ALB registered with **ARC zonal shift / zonal autoshift** | Moves traffic away from an impaired AZ even when health checks look "green" (grey failures) |

**Trade-off vs. ECS on Fargate:** Fargate removes node management and patching, which is attractive for a regulated estate. EKS was chosen because the payment platform has several services, the team already operates EKS with Karpenter, and it keeps the workload portable. The cost is that we own node AMIs, add-on versions and quarterly cluster upgrades, which is handled by the pipeline in Task 5.

## 2.3 Data: Aurora PostgreSQL

| Feature | Behaviour | Contribution |
|---|---|---|
| Aurora storage | 6 copies across 3 AZs; tolerates loss of an AZ plus one more copy for reads | Durability within region |
| Multi-AZ instances | 1 writer + 2 readers in different AZs | Writer failure → reader promoted, typically under 60 s; apps reconnect via cluster endpoint |
| RDS Proxy | Pools connections and holds them during failover | Cuts app-visible failover time and avoids connection storms |
| **Aurora Global Database** | Storage-level replication to DR region, typically under 1 s lag | Meets **RPO 15 min with large margin** |
| Encryption | KMS **multi-Region key** (primary in ap-southeast-5, replica in ap-southeast-1) | Same key material in DR so encrypted data is usable after failover |
| Credentials | Secrets Manager with rotation, **replicated** to DR region | App can authenticate in DR without manual steps |

Other state: S3 (receipts, reports) uses **Cross-Region Replication with Replication Time Control** (15-minute replication SLA, aligned to RPO). Session state is kept out of pods (ElastiCache for Redis with Multi-AZ, rebuilt rather than replicated in DR since sessions can be re-established).

## 2.4 Backups and restore validation

Replication protects against infrastructure loss but **also replicates corruption and deletion**. Backups protect against logical failure (bad deploy, ransomware, operator error).

| Control | Configuration |
|---|---|
| AWS Backup plan | Continuous backup (PITR, 35 days) for Aurora; daily snapshots retained 35 days; monthly retained 1 year |
| Cross-account copy | Daily copy to the **Backup Vault account** (Security OU) |
| Cross-region copy | Daily copy to DR region vault |
| Immutability | **Backup Vault Lock in compliance mode**: no one, including root, can delete recovery points before retention ends |
| Restore validation | **AWS Backup restore testing** plan runs weekly: restores the latest Aurora recovery point into an isolated subnet, a validation Lambda runs row-count and checksum queries, reports result via EventBridge, and the restored cluster is deleted automatically |
| DR game day | Quarterly: full regional failover in staging; twice a year in production during a change window. **AWS Fault Injection Service** used for AZ-impairment and Aurora failover experiments |

Evidence of restore testing is the restore job history and validation results, exported to the Log Archive account for auditors.

## 2.5 Regional DR option: warm standby

| Option | RTO | RPO | Cost | Verdict |
|---|---|---|---|---|
| Backup and restore | Hours | Up to 24 h (or cross-region PITR copy cadence) | Lowest | Fails RTO and RPO |
| Pilot light (DB replicated, no compute) | 30 to 90 min | Seconds | Low | Risky against 60 min: EKS cluster creation alone is 15+ min |
| **Warm standby (chosen)** | **About 30 to 45 min** | **Seconds** | Medium | Meets both targets with margin |
| Active-active | Minutes | Near zero | Highest, plus app redesign for multi-writer | Not required by targets |

**DR region contents (always running):** VPC and TGW attachment, EKS cluster with minimal node capacity and all workloads deployed at low replica counts, Aurora Global DB secondary cluster (1 instance), replicated secrets and KMS keys, ECR replication, WAF and ALB.

### RTO budget (unplanned regional failure)

| Step | Owner | Time |
|---|---|---|
| Detection (CloudWatch alarms, AWS Health, Synthetics canaries) | Automated | 5 min |
| Triage and DR decision by incident commander | On-call | 10 min |
| Aurora Global DB **failover** (`--allow-data-loss`), secondary promoted | Pipeline / runbook | 5 to 10 min |
| Scale DR EKS: raise Karpenter limits, HPA min replicas | Pipeline | 5 to 10 min |
| Traffic switch: **Route 53 ARC routing control** flips to DR | On-call | 2 min (+ TTL 60 s) |
| Validation: canaries, test transaction, reconciliation check | On-call + app team | 10 min |
| **Total** | | **About 37 to 47 min** (inside 60) |

**Why ARC routing controls instead of plain Route 53 health-check failover:** health checks can flap and fail over automatically during partial impairment, causing split-brain with the database. ARC gives a deliberate, highly available "switch" on a data plane spread across 5 regions, so the decision stays with humans while execution stays fast.

**Planned switchover** (DR tests) uses Aurora Global DB **switchover**, which waits for replication to catch up, so RPO is zero.

## 2.6 Composite availability (indicative)

Serial components: CloudFront/WAF, ALB, EKS, Aurora. Each is offered at an SLA of 99.99% for Multi-AZ configurations (check the current AWS SLA pages; values change). Serial combination ≈ 99.96%, above the 99.95% target, **only if** the application tier is itself deployed across AZs with N+1 headroom. Dependency on on-prem systems via DX is the weakest link and is protected by dual DX plus VPN.

## 2.7 Provider-native evidence

- `aws rds describe-global-clusters` (members, writer region)
- CloudWatch metric `AuroraGlobalDBReplicationLag` and `AuroraGlobalDBRPOLag`, alarm at 60 s
- `aws backup list-restore-jobs` and restore testing results
- FIS experiment reports for AZ power-interruption scenarios
- AWS Resilience Hub assessment against the 60 min / 15 min policy, plus a scripted Service Quotas comparison between the two regions
