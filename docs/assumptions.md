# RTO/RPO and Cost Assumptions (AWS)

## Platform and regional assumptions

| # | Assumption | Impact if wrong |
|---|---|---|
| A1 | Primary region **ap-southeast-5 (Malaysia)** for data residency preference under BNM RMiT; DR region **ap-southeast-1 (Singapore)** | If a required service (for example Aurora Global Database, Network Firewall, ARC) is not available in ap-southeast-5, primary moves to ap-southeast-1 and DR to another APAC region; design is unchanged |
| A2 | Hosting payment data outside Malaysia for DR is acceptable after regulatory consultation/notification as required by RMiT | Otherwise DR must be re-scoped |
| A3 | Application is stateless at the compute tier and can run on EKS | Otherwise session/state redesign needed |
| A4 | Aurora PostgreSQL is compatible with the existing database (or migration via AWS DMS + SCT is in scope) | Engine change affects timeline |
| A5 | Single-writer database model is acceptable (no active-active writes) | Active-active would need app-level conflict handling |
| A6 | On-prem dependencies (card schemes, HSM, core banking) remain reachable via DX during DR | If not, DR region needs its own DX/VPN path (included in design as TGW peering + VPN) |
| A7 | Payment HSM: AWS Payment Cryptography or CloudHSM is available in both regions, or on-prem HSM via DX | Affects RTO if keys must be re-provisioned |

## RTO/RPO assumptions

| Item | Assumption |
|---|---|
| Declaring disaster | RTO clock starts at **declaration**, not first symptom; detection + decision budgeted at 15 min within the 60 |
| Aurora Global DB lag | Typically under 1 second; alarm at 60 s; RPO target of 15 min therefore has large margin |
| Unplanned failover | Uses `failover-global-cluster --allow-data-loss`; data written in the lag window is lost (within RPO) and reconciled from payment network records |
| DNS | Public record TTL 60 s; clients honour TTL |
| DR capacity | EC2 quotas in DR region pre-raised to 100% of primary; Karpenter can launch nodes within ~2 to 5 min |
| Dependencies | IAM, Route 53 ARC data plane and CloudFront are global/multi-region and remain available |
| Logical corruption | Not covered by replication; recovered from PITR (AWS Backup), RTO for that case is longer and agreed separately |

## Cost assumptions

| Item | Assumption |
|---|---|
| Pricing basis | On-demand list price, USD, APAC region; excludes tax, Enterprise Support (greater of a minimum fee or a % of spend), and discounts |
| Traffic | ~200 TPS peak, ~2 TB/month egress to internet, ~5 TB/month through TGW |
| Compute | Primary: 6 × m7g.xlarge equivalent across 3 AZs (N+1); DR: 2 nodes idle, scales on failover |
| Database | Primary: 3 × db.r7g.xlarge; DR: 1 × db.r7g.xlarge |
| Logs | ~1 TB/month ingested across CloudWatch Logs |
| Shield Advanced | One subscription covers the organization |
| Total indicative run-rate | **~12,000 to 20,000 USD/month** for prod + DR + shared platform before Savings Plans/RIs; **~25 to 30% lower** after commitments |

These numbers are planning assumptions to drive the cost conversation, not quotes.
