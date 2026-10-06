# Task 4: Drift Incident: Unauthorised Route-Table Change (AWS)

## 4.1 Scenario

A route in the Payments-Prod private app subnet route table was changed outside the pipeline. Example: `0.0.0.0/0` was moved from the Transit Gateway (`tgw-…`) to a new Internet Gateway or a peering connection, **bypassing Network Firewall**, or the on-prem route was deleted, **breaking settlement traffic**.

Either outcome is serious: one is a PCI segmentation breach (data could leave uninspected), the other is an availability incident.

## 4.2 Detection (how we find out)

| Signal | Source | Latency |
|---|---|---|
| EventBridge rule matches `CreateRoute`, `ReplaceRoute`, `DeleteRoute`, `ReplaceRouteTableAssociation` where `userIdentity.arn` is not the pipeline role | CloudTrail management events | Seconds to a few minutes |
| Config custom rule `route-table-approved-targets` goes NON_COMPLIANT | AWS Config | Minutes |
| Scheduled **Terraform drift detection** job (`terraform plan -detailed-exitcode` every hour; exit code 2 = drift) | Jenkins | Up to 1 hour |
| Symptom alarms: ALB 5xx, Synthetics canary failures, Network Firewall traffic drop on the inspection path, settlement queue depth rising | CloudWatch | Minutes |
| GuardDuty findings if traffic now reaches unusual destinations | GuardDuty | Minutes |

```json
{
  "source": ["aws.ec2"],
  "detail-type": ["AWS API Call via CloudTrail"],
  "detail": {
    "eventName": ["CreateRoute", "ReplaceRoute", "DeleteRoute",
                  "ReplaceRouteTableAssociation", "AssociateRouteTable",
                  "DisassociateRouteTable"],
    "userIdentity": {
      "arn": [{ "anything-but": { "prefix": "arn:aws:sts::222222222222:assumed-role/platform-network-deploy/" } }]
    }
  }
}
```

## 4.3 Identify the actor

**Step 1: Find the exact API call.** CloudTrail Lake (org event data store, queried from the Audit account):

```sql
SELECT eventTime, eventName, awsRegion, recipientAccountId,
       userIdentity.arn, userIdentity.sessionContext.sourceIdentity,
       userIdentity.principalId, sourceIPAddress, userAgent,
       requestParameters, errorCode
FROM   <event-data-store-id>
WHERE  eventSource = 'ec2.amazonaws.com'
  AND  eventName IN ('CreateRoute','ReplaceRoute','DeleteRoute',
                     'ReplaceRouteTableAssociation','AssociateRouteTable')
  AND  element_at(requestParameters, 'routeTableId') = 'rtb-0abc123'
  AND  eventTime > '2026-10-06 00:00:00'
ORDER BY eventTime DESC
```

**Step 2: Resolve the role session to a human.**

| Field | What it tells you |
|---|---|
| `userIdentity.arn` = `assumed-role/AWSReservedSSO_PaymentsAdmin_xxx/jane@example.my` | Identity Center user, session name is their email |
| `sessionContext.sourceIdentity` | Persisted identity across role chaining (we require it to be set) |
| `userAgent` = `console.amazonaws.com` vs `aws-cli/2.x` vs `Terraform/1.x` | Console click, script, or someone running Terraform locally |
| `sourceIPAddress` | Corporate egress IP vs. unknown IP (possible credential theft) |
| `errorCode` | Whether earlier attempts were denied (probing behaviour) |

Then confirm in IAM Identity Center / IdP sign-in logs that the user actually authenticated from that IP. If not, treat as **credential compromise** and escalate to a security incident.

**Step 3: What else did this principal do?** Pull every call from the same `principalId` / access key in a ±24 h window. A route change accompanied by `CreateInternetGateway`, `AuthorizeSecurityGroupIngress 0.0.0.0/0` or `CreateAccessKey` is a strong compromise indicator. **Amazon Detective** gives the same view graphically.

**Step 4: Why was it allowed?** If SCP-01 is attached, only `platform-network-deploy` and `break-glass-admin` can change routes, so the actor is one of those two. That narrows it immediately: a pipeline run nobody approved, or break-glass use. If the call came from another principal, the **SCP was missing or detached**, which becomes its own finding (check `DetachPolicy` events in the Management account).

## 4.4 Determine blast radius

| Question | How to answer it (AWS-native) |
|---|---|
| Which subnets use this route table? | `aws ec2 describe-route-tables --route-table-ids rtb-0abc123 --query 'RouteTables[].Associations'` |
| Which workloads sit in those subnets? | ENIs in the subnets: `aws ec2 describe-network-interfaces --filters Name=subnet-id,Values=...` → map to EKS nodes, Aurora, RDS Proxy |
| What did the route change? | AWS Config **resource timeline** for `AWS::EC2::RouteTable` shows before/after configuration |
| What is reachable now? | **VPC Reachability Analyzer** (EKS ENI → internet, EKS ENI → on-prem CIDR); **Network Access Analyzer** scope "CDE to internet without firewall" |
| Did data actually leave? | **VPC Flow Logs** (in Log Archive) queried with Athena for traffic from CDE subnets to non-RFC1918 destinations since `eventTime`; compare with Network Firewall logs (traffic that should have been logged but was not) |
| Business impact | Failed transactions from ALB/app metrics, settlement backlog, affected merchants |
| Other accounts? | Same CloudTrail Lake query without the route table filter, across all accounts |

```sql
-- Athena over VPC Flow Logs: egress from CDE subnets to public IPs after the change
SELECT srcaddr, dstaddr, dstport, SUM(bytes) AS bytes, MIN(start) AS first_seen
FROM   vpc_flow_logs
WHERE  account_id = '222222222222'
  AND  srcaddr LIKE '10.20.%'
  AND  NOT (dstaddr LIKE '10.%' OR dstaddr LIKE '172.16.%' OR dstaddr LIKE '192.168.%')
  AND  start >= to_unixtime(timestamp '2026-10-06 02:14:00')
  AND  action = 'ACCEPT'
GROUP BY srcaddr, dstaddr, dstport
ORDER BY bytes DESC;
```

## 4.5 Recovery runbook

**Severity:** SEV1 if CDE bypasses inspection or payments are failing; SEV2 otherwise.
**Roles:** Incident Commander (IC), Network on-call (executor), Security on-call, Payments app on-call, Scribe.

| # | Action | Who | Detail and safety check |
|---|---|---|---|
| 0 | Open incident, start timeline | IC | Ticket ID `INC-xxxx` used as session name for any elevated access |
| 1 | **Preserve evidence first** | Security | Snapshot current route table config to the incident bucket (`describe-route-tables` JSON), export the CloudTrail Lake query result, note Config timeline. Do not delete the rogue IGW yet; it is evidence |
| 2 | Contain the actor (if unauthorised or unknown) | Security | Revoke active sessions: attach inline deny with `aws:TokenIssueTime` less than now to the role (console "Revoke active sessions"); disable user in IdP; if access keys, deactivate |
| 3 | Confirm desired state | Network | Desired state = `main` branch of `terraform/modules/spoke-vpc`. Run pipeline in **plan-only** mode for Payments-Prod network stack. Plan must show **only** the route(s) reverting; anything else = stop and investigate |
| 4 | Restore via pipeline | Network + approver | Approve the plan in Jenkins (emergency change, 2nd approver = IC). Apply the **saved plan file**. Pipeline role is authorised by SCP; no console edits |
| 4b | If pipeline is unavailable | Network + IC | Break-glass: two custodians, session name `INC-xxxx`, run `aws ec2 replace-route --route-table-id rtb-0abc123 --destination-cidr-block 0.0.0.0/0 --transit-gateway-id tgw-0def456`. Afterwards run the pipeline to confirm zero drift |
| 5 | Verify | Network + App | Reachability Analyzer: CDE → internet path now traverses Network Firewall; CDE → on-prem reachable. Synthetics canaries green; test transaction succeeds; Network Firewall flow logs show traffic again |
| 6 | Clean up rogue resources | Network | After evidence is captured, remove the rogue IGW/peering **through Terraform** (import, then delete) or via break-glass with ticket |
| 7 | Data-exposure assessment | Security | Using flow log analysis; if CDE data left uninspected, invoke PCI incident response (acquirer/brand notification) and BNM reporting per RMiT incident timelines |
| 8 | Close | IC | Post-incident review within 5 working days |

**Why restore through the pipeline and not the console:** the pipeline applies a reviewed, versioned desired state and leaves evidence (plan, approval, apply log). A console fix restores service but creates a second undocumented change during an incident, which is exactly the failure we are recovering from.

## 4.6 Prevent recurrence

| Gap | Control | Type |
|---|---|---|
| Route could be changed by non-pipeline principals | SCP-01 on Workloads OU (Task 3) | Preventive |
| SCP could be detached silently | EventBridge on `DetachPolicy`/`UpdatePolicy` in Management account → P1 alert; SCP changes only via pipeline with Security approval | Detective |
| App-created roles might gain EC2 route rights | Permission boundary `DenyPlatformResources` | Preventive |
| Extra routes could be invisible to Terraform | Spoke module declares routes **inline** on `aws_route_table`, so Terraform owns the whole table and any unmanaged route appears as drift (separate `aws_route` resources would not detect an added route) | Detective |
| Drift detected only by symptoms | Real-time EventBridge rule + hourly Terraform drift job + Config custom rule | Detective |
| Desired state not continuously verified | Network Access Analyzer scope run daily, findings to Security Hub | Detective |
| Pipeline itself as attack path | Prod apply requires 2 approvers ≠ commit author; deploy role assumable only by Jenkins agent role; branch protection on `main` | Preventive |
| Break-glass used without follow-up | Break-glass alert auto-creates a ticket requiring Terraform back-port before closure | Corrective |

## 4.7 Post-incident review template

- Timeline (UTC): change made → detected → contained → restored → verified
- Detection gap: time between change and alert, and why
- Actor, intent (error vs. malicious), and how authorisation was possible
- Blast radius: subnets, workloads, data exposure finding
- Contributing factors (missing SCP, too-broad role, unclear ownership)
- Actions with owners and due dates, tracked to closure
