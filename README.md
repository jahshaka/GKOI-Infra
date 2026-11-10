# GKOI-Infra — the AWS infrastructure for GKOI prod 2, as code

Terraform for account 127214190346 (PLAN-AWS-MIGRATION-PROD2-V1 in GKOIBuilder_AI `docs/specs/`).

- **Regions:** us-west-2 (home: control plane + data), eu-central-1, us-east-1 (media + game); ap-northeast-1 PAUSED
  (a disabled entry in `modules/regions/main.tf` — see "Enabling a paused region").
- **Rule (operator 2026-11-10):** the full infrastructure is built properly (ALB, NAT, endpoints, RDS, Valkey, EFS, CloudFront,
  Secrets Manager/KMS, CloudWatch, CI); only SERVER COUNTS stay minimal — every ECS service and ASG min 1 / max 1 until raised.
- **No secrets in this repo.** Values live in Secrets Manager; Terraform state lives in the encrypted, versioned S3 bucket
  `gkoi-tfstate-127214190346` (us-west-2) with the DynamoDB lock table `gkoi-tflock`, never in git.
- **CI (ruled 2026-11-10): AWS CodeBuild fed from our own checkout, not GitHub.** The `gkoi-infra-runner` project runs
  `buildspec.yml`; anything that deletes or replaces needs the operator's approval (`ALLOW_DESTROY=yes`).
- **IAM:** every role and policy this repo creates lives under the path `/gkoi/` (the runner role may only touch that path).
- **Tags:** every resource carries `project=gkoi`, `env=prod2`, `managed-by=terraform` (+ `stack=<name>`) via the
  providers' `default_tags`.
- **Terraform 1.9.8 everywhere** (the stacks pin `required_version = "= 1.9.8"`; the buildspec checks the zip's SHA256).
  Provider lock files (`.terraform.lock.hcl`) are committed; CI inits with `-lockfile=readonly`.

## Layout

```
buildspec.yml            the gkoi-infra-runner build (install Terraform 1.9.8, run tools/tf-run.sh)
tools/tf-run.sh          init → plan -out → (apply the saved plan) for one stack, with a plan summary
modules/
  regions/               the region catalogue: CIDRs, roles, enabled/paused — the ONE place to enable a region
  vpc/                   one region's VPC (2 AZs, public + private, IGW, optional NAT, S3 gateway + interface endpoints, flow logs)
  vpc-peering/           hub ↔ spoke inter-region peering with routes on both sides
  codebuild-project/     one app repo's CodeBuild project + its /gkoi/ role + log group
  ecr-creation-template/ replica settings for gkoi/* in a replication destination region
  region-log-groups/     log groups in one region + a read of its existing gkoi-ops-alerts topic
envs/prod2/
  network/  edge-alb/  data/  registry/  observability/      one state file each: prod2/<stack>/terraform.tfstate
```

The state bucket, lock table, runner project and its role were created by hand in P0 (not managed here).

## The stacks

| Stack | Creates | Reads (never changes) |
|---|---|---|
| `network` | A VPC per enabled region (usw2 10.10/16, euc1 10.20/16, use1 10.30/16; apne1 10.40/16 when enabled), 2 AZs, public + private /20s, IGW; ONE NAT gateway in usw2 (`home_nat_mode = per_az` for one per AZ); S3 gateway endpoint everywhere; interface endpoints in usw2 (ecr.api, ecr.dkr, secretsmanager, logs, ssm, ssmmessages, ec2messages, kms, sts); peering usw2 ↔ each spoke with routes in every route table; flow logs (ALL, 10-min aggregation) to `/gkoi/prod2/vpc-flow/<region>` (7 days) + the role `/gkoi/gkoi-prod2-vpc-flow-logs`; each VPC's default SG locked; the shared `gkoi-prod2-ecs-tasks` SG | — |
| `edge-alb` | The public ALB `gkoi-prod2-alb` (usw2, 2 AZs, deletion protection on); an ACM cert for engine / files / origin-www / origin-cdn / origin-labs / origin-live `.gkoi.com` with its DNS-validation CNAMEs; HTTP→HTTPS 301; HTTPS default 404; host rules → target groups `cms` (origin-www/cdn/labs), `engine-api` (engine), `fm-api` (files), `fm-web` (no host: the FM admin is reached through the site's admin mount); the origin-live lock (below); ALB↔tasks SG rules | Route 53 zone `gkoi.com`; secret `gkoi/edge/live-origin`; network state |
| `data` | RDS PostgreSQL 16 `gkoi-prod2-pg` (db.t4g.small, single-AZ, gp3 20→100 GiB, encrypted, 7-day backups, deletion protection, master password managed by RDS in Secrets Manager, parameter group `rds.force_ssl=1` + slow/lock/temp/autovacuum/connection logging, logs to CloudWatch 30 days); ElastiCache Valkey 8 `gkoi-prod2-valkey` (one cache.t4g.small, `maxmemory-policy noeviction`, TLS + at-rest encryption, auth token in `gkoi/prod2/valkey` with a `rediss://` URL, slow-log to CloudWatch); EFS `gkoi-prod2-cms` (encrypted, general purpose, elastic throughput, AWS Backup on, TLS-only policy) + the access point `/cms-content` at uid/gid 33; SGs: each store admits only the ECS tasks SG | network state |
| `registry` | ECR `gkoi/{cms-server, cms-nginx, engine-api, engine-worker, engine-web, media-agent, media-origin, mediamtx, fm-api, fm-worker, fm-web, warroom-game}` (immutable tags, scan on push, keep last 20); registry replication of `gkoi/*` to euc1 + use1 with creation templates there; CodeBuild `gkoi-build-{aisolver-www, mikaido, filemanager}` (privileged, BUILD_GENERAL1_LARGE, S3 source `<repo>/source.zip`, local Docker layer cache), each with role `/gkoi/gkoi-build-<repo>` (read `<repo>/*`, read/write `cache/<repo>/*`, push its own repos, write `/gkoi/codebuild/<repo>`) | bucket `gkoi-build-sources-127214190346` |
| `observability` | Log groups (30 days): `/gkoi/prod2/ecs/<service>`, `/gkoi/prod2/ops`, `/gkoi/prod2/{media,game}/<region>/{container,syslog,bootstrap}` per enabled region; dashboard `gkoi-prod2` (ALB, RDS, Valkey, EFS); alarms → `gkoi-ops-alerts` (usw2): RDS CPU / storage / memory / connections, Valkey memory / CPU, ALB 5xx, per-target-group unhealthy hosts, EFS IO limit | the `gkoi-ops-alerts` topics; network, edge-alb and data state |

**Service counts.** No stack here runs a service yet. `edge-alb`'s `services` variable carries each control-plane service's
port, health path, hosts and ECS `min_capacity` / `max_capacity` (all default 1 / 1, operator 2026-11-10) and outputs them
for the compute stack. Raise a `max_capacity` there, never in the compute stack. (The CMS must stay at max 1 until C16.)

**The origin-live lock (edge-alb).** The engine edge's nginx (`mikaido/infra/nginx/edge-live-origin-on.conf.template`)
serves ONLY GET/HEAD/OPTIONS `/api/v1/watch/**`, and only with `X-Origin-Verify: <secret>`. The ALB reproduces what a rule can:
priority 10–11 forward host + secret + `/api/v1/watch/*` + GET/HEAD or OPTIONS to engine-api; 12 = secret but another
path/method → 404; 13 = no or wrong secret → 403. A plan-time precondition requires the secret to be 32–128 characters of
`[A-Za-z0-9_-]` (an ALB condition value is at most 128 characters; header matching is case-insensitive). What the ALB can NOT do
(the nginx did): rewrite `X-Forwarded-For` from `CloudFront-Viewer-Address`, strip `Cookie` / `Authorization` /
`X-Origin-Verify`, validate the LL-HLS query string, answer OPTIONS itself. Those need the api (or an nginx in the engine task)
before origin-live moves to the ALB in P3.

## Apply order

1. `network`
2. `edge-alb` (needs network; the ACM validation waits for DNS — a few minutes)
3. `data` (needs network)
4. `registry` (independent — any time)
5. `observability` (last: reads network, edge-alb and data)

Each stack: `plan`, read the summary, then `apply` (which re-plans and applies exactly that saved plan).

## How the orchestrator runs a stack (from this box, which has no AWS credentials of its own)

```bash
cd ~/Development/mikaido/gkoi-infra
git archive --format=zip -o /tmp/gkoi-infra-source.zip HEAD          # committed files only, lock files included
# upload (aws-mcp get_presigned_url for a PUT, or any credentialed shell):
#   s3://gkoi-build-sources-127214190346/gkoi-infra/source.zip
# start (aws-mcp run_script → codebuild StartBuild, us-west-2):
#   projectName = gkoi-infra-runner
#   environmentVariablesOverride = [
#     {name: TF_STACK,  value: network, type: PLAINTEXT},
#     {name: TF_ACTION, value: plan,    type: PLAINTEXT}]               # then apply
#   (+ {name: ALLOW_DESTROY, value: yes} ONLY after the operator approves a plan that deletes/replaces)
# read the result: the build's CloudWatch log ("== plan summary: …" and the per-resource lines)
```

`tools/tf-run.sh` exits 2 on a bad `TF_STACK`/`TF_ACTION`, with the plan's exit code on a failed plan, and 3 when an apply
would delete or replace without `ALLOW_DESTROY=yes`. Sensitive values are never printed (the plan JSON is read only for the
counts and addresses, then deleted).

## Cost-bearing resources per stack (us-west-2 list prices from memory — verify with the pricing data)

| Stack | Monthly floor | Items |
|---|---|---|
| `network` | **~$170** | NAT gateway ~$33 + $0.045/GB processed; its public IPv4 ~$3.6; interface endpoints 9 × 2 AZs × ~$7.3 ≈ **$131** + $0.01/GB; flow-log ingestion $0.50/GB (+ storage); inter-region peering $0.02/GB each way. Free: VPCs, subnets, IGW, S3 gateway endpoints, routes, peering connections. |
| `edge-alb` | **~$30** | ALB ~$16.4 + LCUs (~$5.8 per LCU-month); 2 public IPv4 ~$7.3. Free: ACM, target groups, rules; validation records are a few Route 53 queries. |
| `data` | **~$55** | RDS db.t4g.small ~$23.4 + gp3 20 GiB ~$2.3 (backups free up to the DB size); Valkey cache.t4g.small ~$19–23; EFS ~$0.30/GB-month (18 GB ≈ $5.4) + elastic transfer $0.03/GB read / $0.06/GB write; EFS backups ~$0.05/GB; 2 secrets ~$0.80; CloudWatch log ingestion. |
| `registry` | **a few $** | ECR $0.10/GB-month × 3 regions (replicas); replication $0.02/GB; CodeBuild LARGE ~$0.02/min only while building (~$0.20–0.40 per release). |
| `observability` | **~$4** | ~12 alarms × $0.10; dashboard $3 (after the account's first 3); log storage $0.03/GB-month, ingestion $0.50/GB. |

Cheaper knobs if wanted: endpoints in one AZ only (~−$65), drop flow logs to `REJECT`, Valkey `cache.t4g.micro` (~−$10).

## Enabling a paused region (ap-northeast-1)

1. Create the SNS topic `gkoi-ops-alerts` in ap-northeast-1 (observability reads it; it does not create it).
2. In `modules/regions/main.tf` set `apne1.enabled = true`.
3. Apply `network` (VPC + peering to usw2), `registry` (replication destination + creation template), `observability`.

## Things to know before the first apply

- **edge-alb, validation CNAMEs:** ACM's validation record for a name is the same for every cert of that name in this account.
  If an existing cert (e.g. a CloudFront one) already validated `engine.gkoi.com` etc., the record exists with the same value and
  `allow_overwrite` adopts it unchanged — but destroying this stack would then delete it and stop that other cert's renewal.
  No other record in the zone is touched; the ALB's own hostnames are NOT pointed at it here (that is the P3/P4 cut-over).
- **edge-alb, the secret format:** `gkoi/edge/live-origin` is read as a plain string. If it is JSON, set
  `live_origin_secret_json_key`. The value lands in this stack's (encrypted) state.
- **registry, replication:** ECR replication is ONE registry-wide setting per region. This stack owns it in us-west-2; an
  existing replication configuration there (old workloads) would be replaced. Check with `ecr describe-registry` first.
- **data:** deletion protection is on and a final snapshot is taken; `terraform destroy` will fail until it is turned off.
- **Valkey from the media boxes (P5):** the media agent needs `REDIS_URL`; add the peered VPC CIDRs to `valkey_peer_cidrs`
  (the network stack's `edge_cidrs` output) when that phase starts.
