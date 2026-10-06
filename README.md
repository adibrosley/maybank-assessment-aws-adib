# Regulated Payment Service: Data Centre to Cloud Migration

> **Selected cloud: Amazon Web Services (AWS).** All designs, services, evidence and code in this submission are AWS-native. No other provider is used.

## Scenario summary

A regulated payment service (PCI DSS cardholder data environment, operating under BNM RMiT) is migrating from an on-premises data centre to AWS.

| Constraint | Target | Where it is addressed |
|---|---|---|
| Availability | 99.95% (about 21.9 min downtime per month) | [02 Resilient workload](docs/02-resilient-workload.md) |
| RTO / RPO | 60 min / 15 min | [02](docs/02-resilient-workload.md), [assumptions](docs/assumptions.md) |
| Traceable, automated production change | 100% via pipeline | [05 Automation](docs/05-automation.md), [Jenkinsfile](Jenkinsfile) |
| App teams own workloads, not guardrails or hubs | Enforced by SCP and permission boundary | [03 Guardrails](docs/03-guardrails.md) |

## Submission map

| # | Task | Weight | Document |
|---|---|---|---|
| 1 | Landing-zone integration | 20% | [docs/01-landing-zone.md](docs/01-landing-zone.md) |
| 2 | Resilient workload | 20% | [docs/02-resilient-workload.md](docs/02-resilient-workload.md) |
| 3 | Guardrails | 20% | [docs/03-guardrails.md](docs/03-guardrails.md) |
| 4 | Drift incident | 15% | [docs/04-drift-incident-runbook.md](docs/04-drift-incident-runbook.md) |
| 5 | Automation | 15% | [docs/05-automation.md](docs/05-automation.md) |
| 6 | Cost and operations | 10% | [docs/06-cost-operations.md](docs/06-cost-operations.md) |

## Required deliverables

| Deliverable | Location |
|---|---|
| Mandatory architecture diagram (trust boundaries, traffic flow, failure domains, security controls, services) | [docs/architecture.md](docs/architecture.md) |
| Traffic-flow diagrams | [docs/architecture.md](docs/architecture.md) |
| Control matrix | [docs/control-matrix.md](docs/control-matrix.md) |
| IaC and pipeline extracts | [terraform/](terraform/), [policy/](policy/), [Jenkinsfile](Jenkinsfile) |
| Incident analysis and recovery runbook | [docs/04-drift-incident-runbook.md](docs/04-drift-incident-runbook.md) |
| RTO/RPO and cost assumptions | [docs/assumptions.md](docs/assumptions.md) |

## Repository layout

```
.
├── Jenkinsfile                     # Plan → policy → approve → apply → evidence
├── docs/                           # Design write-ups, diagrams, matrix, runbook
├── terraform/
│   ├── bootstrap/                  # State bucket (S3 native locking, versioned, KMS)
│   ├── modules/spoke-vpc/          # 3-AZ workload VPC attached to Transit Gateway
│   ├── org/guardrails/             # SCPs, Config org rules, org CloudTrail
│   └── workloads/payments/         # Aurora Global DB, AWS Backup, per-env config
├── policy/                         # OPA/Conftest rules run against terraform plan
├── jenkins/                        # Local Jenkins image with Terraform tooling
└── lab/                            # Low-cost hands-on version deployable via Jenkins
```

Hands-on walkthrough (Terraform, GitHub, Jenkins, drift simulation): [LEARNING.md](LEARNING.md)

## Design principles

1. **Separation of duties by account.** Platform, security and network concerns live in accounts application teams cannot modify.
2. **Preventive before detective.** SCPs and permission boundaries stop the wrong change; Config and CloudTrail prove it and catch what slips through.
3. **Everything is code, every change is evidenced.** Plans, approvals and apply logs are retained in immutable storage.
4. **Recover by redeploying, not by hand.** Both regions are built from the same Terraform; DR is a pipeline run plus a database promotion.
