# Architecture and Traffic-Flow Diagrams (AWS)

Diagrams are Mermaid and render natively on GitHub.

**Regions (assumption, see [assumptions](assumptions.md)):** primary `ap-southeast-5` (Malaysia), DR `ap-southeast-1` (Singapore). Regional service availability must be confirmed before build.

## 1. Mandatory architecture diagram

Shows trust boundaries (dashed boxes), failure domains (AZs and regions), security controls and key services.

```mermaid
flowchart TB
  subgraph ORG["TRUST BOUNDARY 1: AWS Organization (SCPs, RCPs, Control Tower)"]
    direction TB
    subgraph SEC_OU["Security OU (owner: Security team)"]
      LOG["Log Archive acct<br/>Org CloudTrail → S3 Object Lock<br/>Config aggregator data, VPC Flow Logs"]
      AUD["Audit / Security Tooling acct<br/>GuardDuty, Security Hub, Detective<br/>IAM Access Analyzer, CloudTrail Lake"]
      BKP["Backup Vault acct<br/>AWS Backup vault (Vault Lock, compliance mode)"]
    end
    subgraph INF_OU["Infrastructure OU (owner: Platform/Network team)"]
      subgraph NET["Network Hub acct: TRUST BOUNDARY 2"]
        DX["Direct Connect x2 (diverse locations)<br/>+ Site-to-Site VPN backup"]
        TGW["Transit Gateway<br/>(shared via RAM; segmented route tables)"]
        INSP["Inspection VPC<br/>AWS Network Firewall (per AZ)<br/>TGW appliance mode ON"]
        EGR["Egress VPC<br/>NAT GW per AZ"]
        R53R["Route 53 Resolver<br/>inbound/outbound endpoints<br/>+ DNS Firewall"]
      end
      SHS["Shared Services acct<br/>Jenkins controller/agents, ECR,<br/>IAM Identity Center delegated admin"]
    end
    subgraph WL_OU["Workloads OU › Prod (owner: Payments app team, within boundary)"]
      subgraph PROD["Payments-Prod acct: TRUST BOUNDARY 3 (PCI CDE)"]
        subgraph R1["Primary region ap-southeast-5: FAILURE DOMAIN"]
          WAF["CloudFront + AWS WAF + Shield Advanced"]
          subgraph AZA["AZ-a"]
            ALBa["ALB node"]; EKSa["EKS nodes (Karpenter)"]; AURw["Aurora writer"]
          end
          subgraph AZB["AZ-b"]
            ALBb["ALB node"]; EKSb["EKS nodes"]; AURr1["Aurora reader"]
          end
          subgraph AZC["AZ-c"]
            ALBc["ALB node"]; EKSc["EKS nodes"]; AURr2["Aurora reader"]
          end
          KMS1["KMS multi-Region key<br/>Secrets Manager"]
        end
        subgraph R2["DR region ap-southeast-1: FAILURE DOMAIN (warm standby)"]
          EKS2["EKS cluster (min capacity)"]
          AUR2["Aurora Global DB secondary"]
          KMS2["KMS replica key<br/>Secrets Manager replica"]
        end
      end
    end
  end
  DC["On-prem data centre<br/>(legacy systems, card schemes)"]
  USERS["Merchants / consumers"]

  USERS -->|HTTPS TLS1.2+| WAF --> ALBa & ALBb & ALBc
  ALBa --> EKSa; ALBb --> EKSb; ALBc --> EKSc
  EKSa & EKSb & EKSc -->|TLS, IAM auth| AURw
  AURw -. storage replication 6 copies / 3 AZ .- AURr1 & AURr2
  AURw ==>|Global DB replication, lag < 1s typical| AUR2
  DC <-->|private, MACsec where supported| DX <--> TGW
  PROD <-->|TGW attachment| TGW
  TGW <--> INSP
  INSP --> EGR -->|egress allow-list| INTERNET(("Internet / card scheme APIs"))
  PROD -. "logs (org trail, flow logs)" .-> LOG
  PROD -. "backups copied cross-account" .-> BKP
  SHS -->|assume deploy role| PROD
```

### Trust boundaries and ownership

| Boundary | What it separates | Enforced by | Who can change it |
|---|---|---|---|
| 1. Organization | Our estate vs. everything else | SCPs, RCPs, Control Tower controls, org trail | Platform team via pipeline in Management account only |
| 2. Network hub | Shared connectivity vs. workloads | Separate account, TGW route tables, SCP denies network edits in workload OUs | Network team via pipeline |
| 3. PCI CDE (Payments-Prod) | Cardholder data vs. non-CDE | Dedicated account, Network Firewall policy, security groups, KMS key policies | Payments team (workload resources only, inside permission boundary) |
| Security OU | Evidence vs. everyone being audited | Object Lock, Vault Lock, SCP deny-delete, no app-team access | Security team only |

## 2. Traffic flows

### 2a. North-south ingress (customer payment request)

```mermaid
sequenceDiagram
  participant C as Customer
  participant CF as CloudFront + WAF + Shield Adv
  participant ALB as ALB (3 AZ, Payments-Prod)
  participant EKS as EKS pod (payments-api)
  participant DB as Aurora writer
  C->>CF: HTTPS (TLS 1.2+)
  CF->>CF: WAF managed rules, rate limit, geo, bot control
  CF->>ALB: Origin request (custom header + prefix list SG)
  ALB->>EKS: Target group (IP mode), mTLS optional in mesh
  EKS->>DB: TLS, IAM auth / Secrets Manager rotation
  DB-->>EKS: Result
  EKS-->>C: Response
```

ALB security group only allows the CloudFront managed prefix list, so the origin cannot be reached directly.

### 2b. East-west and hybrid (to on-prem and card schemes)

```mermaid
flowchart LR
  POD["EKS pod<br/>Payments-Prod VPC"] --> RT1["Spoke RT: 0.0.0.0/0 → TGW"]
  RT1 --> TGW["TGW 'spokes' route table"]
  TGW --> NFW["Inspection VPC<br/>Network Firewall<br/>(stateful, domain allow-list)"]
  NFW --> TGW2["TGW 'inspected' route table"]
  TGW2 -->|10.0.0.0/8 on-prem| DXGW["DX Gateway → Data centre"]
  TGW2 -->|default| EGRESS["Egress VPC NAT → card scheme APIs"]
```

Spoke VPCs have no Internet Gateway and no NAT. The only path out is via the TGW to inspection, and spokes cannot route to each other without passing the firewall.

### 2c. DNS resolution

```mermaid
flowchart LR
  APP["Workload VPC resolver (.2)"] -->|corp.example.my?| RULE["Resolver forwarding rule<br/>(shared via RAM)"]
  RULE --> OUT["Outbound endpoint (Network acct)"] --> ONPREM["On-prem DNS"]
  ONPREM -->|aws.example.my?| IN["Inbound endpoint"] --> PHZ["Private hosted zones<br/>(associated cross-account)"]
  APP -.-> DNSFW["Route 53 Resolver DNS Firewall<br/>block known-bad and non-allow-listed domains"]
```

### 2d. Disaster-recovery failover flow

```mermaid
flowchart LR
  A["Regional impairment detected<br/>(CloudWatch, Health, canaries)"] --> B["Incident commander declares DR"]
  B --> C["Aurora Global DB: failover<br/>secondary → primary"]
  C --> D["Jenkins: scale DR EKS<br/>(Karpenter NodePool limits up)"]
  D --> E["Route 53 ARC routing control<br/>flip traffic to DR"]
  E --> F["Validate: synthetic canaries,<br/>test transaction, reconciliation"]
```
