# iam/ — policies for roles this repo does NOT manage

`gkoi-orchestrator` (`/gkoi/gkoi-orchestrator`, the dev box's unattended AWS access through IAM Roles Anywhere,
`~/.local/bin/gkoi-aws`) was created by hand in P0 with hand-attached inline policies (`gkoi-orchestrator-ci-images`,
`-night`, `-sprint`); the runner role may not edit it, so these files are attached by the operator or an AWS MCP
sign-in, never by a stack.

- `gkoi-orchestrator-ops.json` — what `scripts/session-tools/prod-psql.sh` (GKOIBuilder_AI) needs to run SQL on prod 2's
  RDS through the `ops` stack's task: `ssm:GetParameter` on `/gkoi/prod2/ops/psql-run-config`; `ecs:RunTask` on the
  three `gkoi-prod2-ops-psql-{cms,engine,fm}` families, only in cluster `gkoi-prod2`; `iam:PassRole` on
  `/gkoi/gkoi-prod2-exec-ops-psql` only, only to ECS tasks; `ecs:DescribeTasks` in that cluster; `logs:GetLogEvents` on
  `/gkoi/prod2/ecs/ops-psql`. Nothing else — no Secrets Manager, no ECS Exec, no SSM sessions, no S3 (the SQL travels
  in the RunTask override; the task reads its database password itself, through its execution role). Access Analyzer
  `ValidatePolicy`: no findings (2026-11-11). Attach it AFTER `envs/prod2/ops` is applied (the ARNs must exist for it to
  be useful, not for it to be valid):

```bash
aws iam put-role-policy --role-name gkoi-orchestrator --policy-name gkoi-orchestrator-ops \
  --policy-document file://iam/gkoi-orchestrator-ops.json
# check from the dev box (should print the run config JSON, no AccessDenied):
gkoi-aws ssm get-parameter --name /gkoi/prod2/ops/psql-run-config --query Parameter.Value --output text
```

- `gkoi-orchestrator-origin-lock.json` — `secretsmanager:GetSecretValue`, `ListSecretVersionIds` and
  `UpdateSecretVersionStage` on the ONE secret `gkoi/prod2/edge/site-origin` (edge-alb's site-origin lock, README "The
  site-origin lock"). `tools/gkoi-origin-header` needs it from the FIRST roll-out on: `set` reads the stored value back
  (to prove it has no trailing newline) before it goes to CloudFront, `check` compares CloudFront's header with the
  secret, a rotation stages / promotes versions. (Storing a value uses the role's existing `PutSecretValue` on
  `gkoi/prod2/*`, CloudFront its existing `cloudfront:UpdateDistribution`, the lock's state `elasticloadbalancing:Describe*`.)
  Attach it BEFORE `gkoi-origin-header set` (the ARN pattern is valid before the secret exists):

```bash
aws iam put-role-policy --role-name gkoi-orchestrator --policy-name gkoi-orchestrator-origin-lock \
  --policy-document file://iam/gkoi-orchestrator-origin-lock.json
# check from the dev box, after edge-alb created the secret (prints 0, no AccessDenied):
gkoi-aws secretsmanager list-secret-version-ids --secret-id gkoi/prod2/edge/site-origin --query 'length(Versions)'
```
