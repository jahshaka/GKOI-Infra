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
