# `envs/prod2/ops` — SQL on prod 2's RDS from the dev box

RDS `gkoi-prod2-pg` is private to the VPC. The orchestrator's prod tools (GKOIBuilder_AI `scripts/session-tools/`:
`prod-psql.sh`, and on it `prodop.sh`, `mintlink-prod.sh`, `prod-del-ids.sh`, `stale-members.py`, `mac-readback.py`)
reach it through ONE one-off Fargate task per call:

```
prod-psql.sh <cms|engine|fm> [--write] [-F SEP] [-c SQL | -f FILE | < stdin]
  ssm get-parameter /gkoi/prod2/ops/psql-run-config      cluster, families, subnets, SG, log group
  ecs run-task gkoi-prod2-ops-psql-<app>                 override: RUN_ID, SQL_GZ_B64 (≤ 7000 chars), SQL_SHA256, WRITE, FIELD_SEP
  ecs describe-tasks … until STOPPED
  logs get-log-events /gkoi/prod2/ecs/ops-psql <app>/psql/<task id>   → @@BEGIN / @@OUT / @@ERR / @@END rc=N, base64
```

| Piece | What |
|---|---|
| `aws_ecs_task_definition.psql` | `gkoi-prod2-ops-psql-{cms,engine,fm}`: 0.25 vCPU / 0.5 GiB, `gkoi/ci-postgres:16.15-alpine` by digest, user `postgres`, `scripts/psql.sh` inlined; PGHOST/PGDATABASE/PGUSER = the app's database + ONE role (db-restore's `apps` triples), `PGPASSWORD` = that app's password secret (an ECS secret), `PGSSLMODE=require` |
| `aws_iam_role.exec` | `/gkoi/gkoi-prod2-exec-ops-psql`: pull the mirror, write the log group, read the THREE app password secrets (ARNs from compute's `secrets_to_fill`). **No task role** — the container has no AWS credentials. Never the RDS master. |
| `aws_cloudwatch_log_group.psql` | `/gkoi/prod2/ecs/ops-psql`, 1 day (it holds query RESULTS, base64; the tool reads them within seconds) |
| `aws_ssm_parameter.run_config` | `/gkoi/prod2/ops/psql-run-config` — no secret in it |

Inside the task (`scripts/psql.sh`): the SQL's sha256 is checked, then `psql -X -q -t -A -1 -v ON_ERROR_STOP=1` — ONE
transaction, stopped + rolled back at the first error; `default_transaction_read_only=on` unless `WRITE=1` (a
seatbelt, not a fence: the app role OWNS its database, so the task can do whatever the service can — the brief's
"SELECT/INSERT/DELETE only" would need a separate grant-limited DB role, created as the master; not done here);
`statement_timeout` 120 s, `lock_timeout` 10 s, a 300 s wall clock (busybox `timeout`), so a task always stops by
itself. The SQL text is never logged (its size is). Exit = psql's code; 64 bad input.

Why this path (2026-11-11), not ECS Exec into the cms container or an SSM port-forward through a box: both of those
need the Session Manager plugin and an interactive websocket session, which `gkoi-aws` (the AWS CLI in a plain
container) cannot run, and Exec would put ops SQL inside the one live CMS task with its full environment. RunTask +
logs are plain API calls, the pattern db-restore and the rehearsal already use, and the task holds only one password.
Cost: ~30–90 s per call (a Fargate start), cents per month.

## Apply order

1. Apply this stack (reads data, compute, registry state; `gkoi/ci-postgres:16.15-alpine` is already mirrored):
   `tools/gkoi-infra-run ops plan`, read it (creates 1 log group, 1 role + policy, 3 task definitions, 1 SSM
   parameter — nothing replaced or destroyed), then `tools/gkoi-infra-run ops apply`.
2. Attach `iam/gkoi-orchestrator-ops.json` to `gkoi-orchestrator` (`iam/README.md` — the operator or an MCP sign-in).
3. From the dev box: `scripts/session-tools/prod-psql.sh cms -c 'select 1'` → `1`; then a read the tools rely on
   (`prod-psql.sh fm -c 'select count(*) from assets'`).
