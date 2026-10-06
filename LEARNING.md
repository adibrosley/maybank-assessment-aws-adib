# Learning Guide: Terraform + GitHub + Jenkins From Zero

This guide walks you through the repo **by doing**: you publish it to GitHub, run a real Jenkins pipeline that deploys the `lab/` stack to **your own personal AWS account**, then simulate the Task 4 incident and fix it through the pipeline.

> ⚠️ Use a personal/sandbox AWS account. Never a company account or company credentials.
> Lab cost: VPC, subnets and route tables are free. The bootstrap KMS key is about USD 1/month (delete it after). Destroy everything at the end.

---

## Part 0: Terraform in 10 minutes (concepts you will be asked about)

| Concept | One-line meaning | Where in this repo |
|---|---|---|
| **Provider** | Plugin that talks to an API (here: AWS) | `provider "aws"` in every root module |
| **Resource** | A thing Terraform creates and owns | `resource "aws_vpc" "lab"` |
| **Data source** | Read-only lookup of something that exists | `data "aws_availability_zones"` |
| **Variable / output** | Inputs and return values | `variables.tf`, `outputs.tf` |
| **Module** | Reusable folder of Terraform | `terraform/modules/spoke-vpc` |
| **Root module** | The folder you run `terraform` in | `lab/`, `terraform/workloads/payments` |
| **State** | Terraform's record of what it created, mapping code → real resource IDs | S3 bucket from `terraform/bootstrap` |
| **Backend** | Where state is stored and locked | `backend "s3" {}` + `use_lockfile = true` |
| **Plan** | Diff between code and reality; changes nothing | `terraform plan -out=tfplan` |
| **Apply** | Executes a plan | `terraform apply tfplan` |
| **Drift** | Reality changed outside Terraform; shows up in plan | Part 5 below |

The core loop: **write code → `init` → `plan` → review → `apply`**. Terraform compares three things: your code, the state file, and the real AWS resources.

Why remote state matters: with state on your laptop, a teammate (or Jenkins) does not know what exists, and two people applying at once can corrupt it. S3 gives a shared copy, versioning gives rollback, and the lock file stops two applies running together.

---

## Part 1: Install tools (15 min)

| Tool | macOS | Windows (PowerShell) |
|---|---|---|
| Git | `brew install git` | `winget install Git.Git` |
| Terraform | `brew tap hashicorp/tap && brew install hashicorp/tap/terraform` | `winget install Hashicorp.Terraform` |
| AWS CLI | `brew install awscli` | `winget install Amazon.AWSCLI` |
| Docker Desktop | docker.com | docker.com (WSL2 backend) |
| GitHub CLI (optional, easiest login) | `brew install gh` | `winget install GitHub.cli` |

Check: `terraform -version` (need ≥ 1.10), `aws --version`, `docker --version`.

---

## Part 2: Put the repo on GitHub (15 min)

1. Unzip the repo, open a terminal in the folder.
2. Create an **empty public** repo on github.com named `aws-payments-migration` (no README, no .gitignore).
3. Push:

```bash
git init
git add .
git commit -m "AWS payments migration assessment"
git branch -M main
git remote add origin https://github.com/<your-username>/aws-payments-migration.git
gh auth login            # or use a Personal Access Token as the password
git push -u origin main
```

4. Open the repo in the browser. The Mermaid diagrams in `docs/architecture.md` render automatically. **This link is what you submit.**

5. (Recommended, shows the Task 5 controls) Settings → Branches → Add branch ruleset for `main`: require a pull request, require 1 approval, block force pushes.

---

## Part 3: Bootstrap the state bucket (10 min, your laptop)

Configure your personal admin credentials first: `aws configure --profile lab`.

```bash
cd terraform/bootstrap
export AWS_PROFILE=lab                     # PowerShell: $env:AWS_PROFILE="lab"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
terraform init
terraform plan  -var="bucket_name=tfstate-${ACCOUNT_ID}-ap-southeast-1"
terraform apply -var="bucket_name=tfstate-${ACCOUNT_ID}-ap-southeast-1"
```

Note the `state_bucket` output. This is the one stack that uses **local** state (chicken-and-egg: the bucket must exist before anything can store state in it).

Create a least-privilege IAM user for Jenkins (`jenkins-lab`) with **AmazonVPCFullAccess** plus this inline policy, then create an access key for it:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": ["s3:ListBucket"], "Resource": "arn:aws:s3:::tfstate-<ACCOUNT_ID>-ap-southeast-1" },
    { "Effect": "Allow", "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::tfstate-<ACCOUNT_ID>-ap-southeast-1/*" },
    { "Effect": "Allow", "Action": ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey"], "Resource": "<kms_key_arn output>" }
  ]
}
```

(Static keys are acceptable **only** in this personal lab. In the real design Jenkins uses an instance role and `sts:AssumeRole`; see `docs/05-automation.md` §5.3. Expect this question.)

---

## Part 4: Run Jenkins locally and deploy (45 min)

```bash
cd jenkins
docker compose up -d --build        # first build takes a few minutes
docker exec jenkins-lab cat /var/jenkins_home/secrets/initialAdminPassword
```

1. Open http://localhost:8080, paste the password, choose **Install suggested plugins**, create user `admin`.
2. **Add AWS credential:** Manage Jenkins → Credentials → System → Global credentials → Add Credentials → Kind **AWS Credentials** → ID `aws-lab` → paste the `jenkins-lab` access key and secret.
3. **Create the job:** New Item → name `payments-lab` → **Pipeline** → Pipeline section: *Definition* = **Pipeline script from SCM**, *SCM* = Git, *Repository URL* = your GitHub URL, *Branch* = `*/main`, *Script Path* = `Jenkinsfile` → Save.
4. Click **Build Now** once. The first run fails or runs with defaults; that is a known Jenkins behaviour: it reads the `parameters {}` block on the first run. After that you see **Build with Parameters**.
5. **Plan:** Build with Parameters → `ACTION=plan`, `STACK_DIR=lab`, `ENV=lab`, `TF_STATE_BUCKET=<your bucket>` → Build. Open the build → *Console Output*. Read each stage: fmt, validate, tflint, Checkov, plan, Conftest.
6. **Apply:** same parameters with `ACTION=apply`. The build pauses at **Approval**. Open `plan.txt` under build artifacts, then click *Approve and apply*.
7. Confirm in the AWS console (ap-southeast-1): VPC `payments-lab-vpc`, two subnets, route table `payments-lab-private-rt`.
8. Look in S3: `s3://<bucket>/evidence/lab/payments-lab/<build>/` contains plan, apply log and `evidence.json` (who, what, which commit, who approved). That is Task 5's evidence chain in miniature.

---

## Part 5: Simulate the Task 4 incident (30 min)

**Break it (you are the "unauthorised actor"):**
1. VPC console → Internet gateways → Create → attach to `payments-lab-vpc`.
2. Route tables → `payments-lab-private-rt` → Edit routes → Add `0.0.0.0/0` → target the IGW → Save.

**Detect it:**
3. Jenkins → `ACTION=drift-check` → build turns **UNSTABLE**; `plan.txt` shows Terraform wants to remove the `0.0.0.0/0` route. This works because the lab declares `route = []`, so Terraform owns the whole table.

**Identify the actor:**
4. CloudTrail → Event history → filter *Event name* = `CreateRoute`. Open the event: `userIdentity` (you), `sourceIPAddress`, `userAgent` (console), `requestParameters` (route table, IGW). That is §4.3 of the runbook.

**Restore through the pipeline (not the console):**
5. Jenkins → `ACTION=apply` → approve. The route is removed. Post-apply verification confirms the plan is clean.
6. Notice the IGW still exists: Terraform never managed it, so it does not know to delete it. Detach and delete it manually and talk about this in the interview: *unmanaged resources created during an incident must be imported into Terraform or removed through a recorded change.*

---

## Part 6: Clean up (5 min)

1. Jenkins → `ACTION=destroy`, `ENV=lab` → approve.
2. Delete the `jenkins-lab` IAM user's access key.
3. Optional: empty and delete the state bucket, schedule KMS key deletion, `docker compose down -v`.

---

## Part 7: Interview cheat sheet

**Two-minute pitch:** "I chose AWS. Control Tower and Organizations give an account per environment with the CDE isolated. Traffic goes through a Transit Gateway hub with Network Firewall in appliance mode, so app teams never own routing. The workload runs on EKS across three AZs with N+1 headroom and Aurora Multi-AZ, which delivers 99.95%. For a regional event, a warm standby in a second region with Aurora Global Database gives seconds of RPO, and the failover runbook budgets about 45 minutes against the 60-minute RTO. SCPs and permission boundaries stop app teams touching guardrails, Config and CloudTrail prove it, and every production change goes through a Jenkins pipeline with policy checks, two-person approval and evidence in Object Lock storage."

| Likely question | Strong answer |
|---|---|
| Why not just regional DR for 99.95%? | 99.95% allows about 22 min/month. A regional failover itself takes ~45 min, so the availability target must come from Multi-AZ in-region; DR is for RTO/RPO in a regional disaster. |
| SCP vs permission boundary? | SCP caps every principal in an account (org level, app team cannot change). Boundary caps roles the app team creates so "can create roles" does not become "is admin". Neither grants permissions. |
| Why appliance mode on TGW? | Keeps both directions of a flow on the same AZ firewall endpoint; otherwise the stateful firewall sees asymmetric traffic and drops it. |
| How do you know who changed the route? | CloudTrail Lake query on `ReplaceRoute`/`CreateRoute` for that route table, then map `userIdentity.arn` / `sourceIdentity` to the Identity Center user, verify against IdP sign-in logs. |
| Why restore via the pipeline in an incident? | Restores a reviewed desired state with evidence; a console fix is a second undocumented change. Break-glass exists if the pipeline itself is down. |
| What if Terraform state is corrupted? | Restore the previous S3 object version (versioning on), then run a plan to confirm it matches reality. |
| Why `use_lockfile` and no DynamoDB? | Terraform 1.10+ supports native S3 locking; DynamoDB locking is deprecated. |
| Why apply a saved plan file? | Guarantees what is applied is exactly what was approved; Terraform rejects a stale plan if state changed. |
| How is RPO 15 min met? | Aurora Global DB replicates at storage level, typically under 1 s; alarm at 60 s lag. S3 CRR with Replication Time Control (15-minute SLA). |
| Why warm standby, not pilot light? | EKS cluster creation alone takes 15+ min; with detection, decision and validation, pilot light risks the 60 min RTO. |
| Biggest cost surprises? | Data processing (NAT, TGW, cross-AZ), CloudWatch Logs ingestion, Network Firewall endpoints per AZ, Shield Advanced flat fee. |
| What would you do differently with more time? | Move ingress through Firewall Manager-managed WAF everywhere, add active-active for read paths, CodePipeline instead of Jenkins to reduce controller ops, and automate the DR runbook as an SSM Automation document. |

Be ready to say honestly: *"Jenkins and Terraform pipelines are areas I've been actively building up; I ran the full flow end-to-end in a personal lab, including a simulated drift incident."* That is a stronger answer than overclaiming.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Validate` fails on `terraform fmt -check` | Run `terraform fmt -recursive` locally, commit, push, rebuild. (This is the pipeline doing its job.) |
| `Init` fails with AccessDenied | Check the `aws-lab` credential, bucket name parameter, and the IAM inline policy bucket/KMS ARNs |
| No "Build with Parameters" button | Run the job once; Jenkins registers parameters on the first run |
| Approval button missing | You must be logged in as `admin` (the `APPROVERS` value in the Jenkinsfile) |
| `tflint --init` slow/fails | Needs internet to GitHub from the container; retry, or temporarily comment out that line |
| Docker build fails on Apple Silicon | Tools auto-detect arm64; if one still fails, add `platform: linux/amd64` under the service in `docker-compose.yml` |
