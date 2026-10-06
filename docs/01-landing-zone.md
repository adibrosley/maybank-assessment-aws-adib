# Task 1: Landing-Zone Integration (AWS)

## 1.1 Account and OU structure

Built on **AWS Control Tower** (governance baseline, Account Factory) with **AWS Organizations** as the policy plane. Control Tower is used because it gives us a managed, drift-detected baseline (org trail, Config, Log Archive and Audit accounts) rather than hand-assembling those pieces. The trade-off is less flexibility in how those baseline resources are shaped, so anything Control Tower does not cover (TGW, inspection, SCPs beyond CT controls) is managed in our own Terraform.

```
Root
├── Management account        (Organizations, Control Tower, billing; no workloads)
├── Security OU
│   ├── Log Archive           (org CloudTrail, Config, flow logs; S3 Object Lock)
│   ├── Audit                 (delegated admin: GuardDuty, Security Hub, Config, Access Analyzer, Detective)
│   └── Backup Vault          (cross-account AWS Backup copies, Vault Lock compliance mode)
├── Infrastructure OU
│   ├── Network Hub           (TGW, Direct Connect, inspection, egress, Route 53 Resolver)
│   └── Shared Services       (Jenkins, ECR, IAM Identity Center delegated admin, golden AMIs)
├── Workloads OU
│   ├── Prod OU    → Payments-Prod   (PCI CDE)
│   └── NonProd OU → Payments-Staging, Payments-Dev
├── Sandbox OU                (no connectivity to TGW, spending limits)
├── Policy-Staging OU         (test SCP changes before rolling to Prod OU)
└── Suspended OU              (deny-all SCP for decommissioned accounts)
```

**Why an account per environment, not a VPC per environment:** the account is the strongest isolation boundary in AWS. IAM, quotas, KMS key policies and billing are scoped to it, so a mistake in Dev cannot touch Prod data, and PCI scope is limited to the Payments-Prod account (plus connected systems) instead of the whole estate.

**Policy-Staging OU** exists because a bad SCP applies instantly to every account in the OU. Changes are attached here first, validated, and then promoted, using the same pipeline as everything else.

## 1.2 Management ownership (RACI summary)

| Component | Platform team | Network team | Security team | Payments app team |
|---|---|---|---|---|
| Organizations, OUs, SCPs | A/R | C | C | I |
| Control Tower, Account Factory | A/R | I | C | I |
| TGW, DX, inspection, DNS hub | C | A/R | C | I |
| Network Firewall policy rules | C | R | A | C (requests via PR) |
| Log Archive, Audit, Backup Vault | C | I | A/R | I |
| VPC subnets/route tables in Payments accounts | A/R (via spoke module) | C | C | I |
| EKS, Aurora, ALB, app IAM roles | C | I | C | A/R (inside boundary) |

A = accountable, R = responsible, C = consulted, I = informed.

The app team deliberately does **not** own their own VPC routing. The spoke VPC is vended by the platform module, so routes always point to the TGW and through inspection. This is what makes Task 4 (unauthorised route change) preventable rather than only detectable.

## 1.3 Connectivity

| Path | Service | Behaviour and trade-off |
|---|---|---|
| DC ↔ AWS (primary) | **Direct Connect**, 2 dedicated connections at diverse DX locations, transit VIF to **DX Gateway** → TGW | Predictable latency and private path. Two locations meet the AWS "high resiliency" model. Lead time is weeks, so order early. |
| DC ↔ AWS (backup) | **Site-to-Site VPN** over internet, attached to TGW | Cheap backup; BGP prefers DX via AS-path. Limited to about 1.25 Gbps per tunnel, which is enough for degraded mode. |
| VPC ↔ VPC | **Transit Gateway** with separate route tables (`spokes`, `inspected`, `onprem`) | Hub-and-spoke scales better than VPC peering (non-transitive, N² links). Charges per attachment-hour and per GB processed. |
| Cross-region (DR) | TGW inter-region peering | Static routes only (no dynamic propagation across peering), so DR routes are managed in Terraform. |
| AWS services | Interface/gateway **VPC endpoints** (S3, ECR, STS, KMS, Secrets Manager, Logs) | Keeps traffic off NAT and the internet; S3 gateway endpoint is free and removes NAT data charges for the largest flows. |

Encryption in transit on DX: MACsec on supported 10/100 Gbps dedicated connections; otherwise an IPsec VPN over the DX transit VIF for CDE traffic.

## 1.4 Inspection

- **Centralised inspection VPC** in the Network account with **AWS Network Firewall** endpoints in each AZ.
- **TGW appliance mode enabled** on the inspection attachment. Without it, the TGW may send the request and response of one flow through firewall endpoints in different AZs, and the stateful firewall drops the asymmetric return traffic.
- Rule groups: stateful domain allow-list for egress (card schemes, AWS endpoints, patch repos), Suricata rules for known threats, default **drop** with alert logging to the Log Archive account.
- **North-south ingress** is not hair-pinned through the central firewall. It is protected at the edge with CloudFront, AWS WAF and Shield Advanced, managed centrally via **AWS Firewall Manager** so app teams cannot remove WAF from their ALBs. Trade-off: decentralised ingress gives lower latency and a smaller hub blast radius, at the cost of relying on Firewall Manager for consistency.

## 1.5 DNS

- **Route 53 private hosted zones** per environment (`payments.prod.aws.example.my`), owned by the workload account and associated with the Shared Services VPC for resolution.
- **Route 53 Resolver** inbound and outbound endpoints in the Network account (2 AZs minimum each). Outbound **forwarding rules** for on-prem zones are shared to all accounts via **AWS RAM**, so app teams cannot edit them but still use them.
- **Route 53 Resolver DNS Firewall** blocks resolution of non-allow-listed domains from the CDE. This stops DNS-based exfiltration that the network firewall would not see.
- Public DNS for the payment endpoint uses Route 53 with **Application Recovery Controller (ARC)** routing controls for DR (see Task 2).

## 1.6 Shared-services integration

| Service | Location | How workloads consume it |
|---|---|---|
| Identity | IAM Identity Center (delegated admin in Shared Services), federated to corporate IdP | Permission sets per role; no IAM users in workload accounts |
| CI/CD | Jenkins in Shared Services (agents on EKS/EC2 with instance roles) | Assumes `terraform-deploy` role in each target account |
| Container images | ECR in Shared Services with cross-account pull policy, image scanning (Inspector) | EKS nodes pull via VPC endpoint |
| Golden AMIs | Built in Shared Services, shared to OU | Karpenter `EC2NodeClass` references AMI by SSM parameter |
| Security tooling | Audit account as delegated admin | Findings aggregated in Security Hub |
| Logging | Log Archive account | Org trail, Config delivery, flow logs, Network Firewall logs |

## 1.7 Provider-native evidence

| Evidence | How to produce it |
|---|---|
| OU and account structure | `aws organizations list-organizational-units-for-parent`, Control Tower console landing zone view |
| SCP attachment | `aws organizations list-policies-for-target --target-id <ou-id> --filter SERVICE_CONTROL_POLICY` |
| TGW segmentation | `aws ec2 search-transit-gateway-routes` per route table |
| Appliance mode | `aws ec2 describe-transit-gateway-vpc-attachments` → `ApplianceModeSupport: enable` |
| Shared resolver rules | `aws ram list-resources --resource-owner SELF` |
| Path verification | **VPC Reachability Analyzer** from EKS ENI to on-prem CIDR, showing the hop through Network Firewall |
