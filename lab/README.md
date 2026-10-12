# Lab: Deployable Slice of the Design

A low-cost slice of the design that runs end to end through the real pipeline: Terraform remote state, the [`Jenkinsfile`](../Jenkinsfile), policy checks, approval, evidence upload, and the Task 4 drift scenario.

**What it creates:** one VPC, two private subnets in two AZs, a route table that Terraform fully owns (`route = []`), and a locked-down default security group. No NAT, TGW or compute, so the resources themselves are free. The state bucket's KMS key costs about USD 1/month.

> Use a personal sandbox account only. The lab uses static access keys for Jenkins, which is acceptable **only** here; real environments use `sts:AssumeRole` from the Jenkins agent role ([05 Automation §5.3](../docs/05-automation.md)).

Results of running this lab are recorded in [docs/07-validation-and-limitations.md](../docs/07-validation-and-limitations.md).

## Prerequisites

Terraform ≥ 1.10, AWS CLI v2, Docker. An AWS CLI profile with admin rights in the sandbox account.

## 1. State bucket (local state, run once)

```bash
cd terraform/bootstrap
export AWS_PROFILE=lab REGION=ap-southeast-1
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
terraform init
terraform plan -out=tfplan -var="region=${REGION}" -var="bucket_name=tfstate-${ACCOUNT_ID}-${REGION}"
terraform apply tfplan
```

Create a least-privilege IAM user for Jenkins (`jenkins-lab`): `AmazonVPCFullAccess` plus an inline policy allowing `s3:ListBucket` on the state bucket, `s3:GetObject/PutObject/DeleteObject` on its objects, and `kms:Encrypt/Decrypt/GenerateDataKey` on the state key only.

## 2. Jenkins

```bash
cd jenkins
docker compose up -d --build
docker exec jenkins-lab cat /var/jenkins_home/secrets/initialAdminPassword
```

1. Open http://localhost:8080, install suggested plugins, create user `admin` (the approver allowed by the Jenkinsfile).
2. Add a credential of kind **AWS Credentials** with ID `aws-lab` (the `jenkins-lab` key).
3. If deploying outside `ap-southeast-1`, set a global environment variable `TF_VAR_region=<region>` (Manage Jenkins → System → Global properties).
4. Create a Pipeline job from SCM pointing at this repository, script path `Jenkinsfile`. Run it once so Jenkins registers the parameters.

## 3. Deploy

Build with parameters: `STACK_DIR=lab`, `ENV=lab`, `TF_STATE_BUCKET=<bucket>`, `AWS_REGION=<bucket region>`.

| ACTION | Expected result |
|---|---|
| `plan` | Validate, Checkov (soft-fail outside prod), plan, Conftest. Conftest **warns** on route-table changes (needs Network review) |
| `apply` | Pauses at **Approval**; approve after reading `plan.txt`; apply the saved plan; post-apply plan must be clean |

Evidence (plan, apply log, `evidence.json`) is uploaded to `s3://<bucket>/evidence/lab/<job>/<build>/`.

## 4. Task 4 drift scenario

1. **Break:** in the console, create and attach an Internet Gateway to `payments-lab-vpc`, then add `0.0.0.0/0 → IGW` to `payments-lab-private-rt`.
2. **Detect:** `ACTION=drift-check` → build is UNSTABLE, `plan.txt` shows the route being removed.
3. **Identify the actor:** CloudTrail Event history, event name `CreateRoute`: `userIdentity`, `onBehalfOf` / session name, `sourceIPAddress`, `userAgent`, `requestParameters`.
4. **Restore through the pipeline:** `ACTION=apply`, plan must show only the route reverting (`0 to add, 1 to change, 0 to destroy`), approve.
5. **Remove the unmanaged IGW** (Terraform never owned it, so it will not delete it), then `ACTION=drift-check` must be green.

## 5. Clean up

1. `ACTION=destroy`, `ENV=lab` → approve.
2. Empty and delete the state bucket (versioned, `prevent_destroy`), schedule the KMS key for deletion.
3. Delete the `jenkins-lab` access key and user; `docker compose down -v`.
