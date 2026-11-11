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
  ecs-service/           one Fargate task definition + ECS service (surge 100/200, circuit breaker, Exec) + CPU target tracking
  media-box/             one region's media box: ASG (1) + launch template, EIP, SGs, /gkoi/ role, SSM config, DNS, alarms
envs/prod2/
  network/  edge-alb/  data/  registry/  observability/  compute/  media/  rehearsal/   one state file each: prod2/<stack>/terraform.tfstate
  releases/<repo>.json   the pinned image digests gkoi-release records (compute reads them)
```

The state bucket, lock table, runner project and its role were created by hand in P0 (not managed here).

## The stacks

| Stack | Creates | Reads (never changes) |
|---|---|---|
| `network` | A VPC per enabled region (usw2 10.10/16, euc1 10.20/16, use1 10.30/16; apne1 10.40/16 when enabled), 2 AZs, public + private /20s, IGW; ONE NAT gateway in usw2 (`home_nat_mode = per_az` for one per AZ); S3 gateway endpoint everywhere; interface endpoints in usw2 (ecr.api, ecr.dkr, secretsmanager, logs, ssm, ssmmessages, ec2messages, kms, sts); peering usw2 ↔ each spoke with routes in every route table; flow logs (ALL, 10-min aggregation) to `/gkoi/prod2/vpc-flow/<region>` (7 days) + the role `/gkoi/gkoi-prod2-vpc-flow-logs`; each VPC's default SG locked; the shared `gkoi-prod2-ecs-tasks` SG | — |
| `edge-alb` | The public ALB `gkoi-prod2-alb` (usw2, 2 AZs, deletion protection on); an ACM cert for engine / files / origin-www / origin-cdn / origin-labs / origin-live `.gkoi.com` with its DNS-validation CNAMEs; HTTP→HTTPS 301; HTTPS default 404; host rules → target groups `cms` (origin-www/cdn/labs + www; the apex 301s to www), `engine-api` (engine), `fm-api` (files: public paths for all, the rest from `cms_source_cidrs` only), `fm-web` (no host: the FM admin is reached through the site's admin mount); the origin-live lock (below); ALB↔tasks SG rules; the INTERNAL ALB `gkoi-prod2-engine-internal` (:3000, `/internal/*` + health → target group `gkoi-prod2-engine-api-int`; from every peered edge VPC — the media boxes' path to the engine api, output `engine_internal`) | Route 53 zone `gkoi.com`; secret `gkoi/edge/live-origin`; network state |
| `data` | RDS PostgreSQL 16 `gkoi-prod2-pg` (db.t4g.small, single-AZ, gp3 20→100 GiB, encrypted, 7-day backups, deletion protection, master password managed by RDS in Secrets Manager, parameter group `rds.force_ssl=1` + slow/lock/temp/autovacuum/connection logging, logs to CloudWatch 30 days); ElastiCache Valkey 8 `gkoi-prod2-valkey` (one cache.t4g.small, `maxmemory-policy noeviction`, TLS + at-rest encryption, auth token in `gkoi/prod2/valkey` with a `rediss://` URL, slow-log to CloudWatch); EFS `gkoi-prod2-cms` (encrypted, general purpose, elastic throughput, AWS Backup on, TLS-only policy) + the access point `/cms-content` at uid/gid 33; SGs: each store admits only the ECS tasks SG; the rehearsal's scratch recordings bucket `gkoi-prod2-rehearsal-vods-127214190346` (private, 3-day expiry) | network state |
| `registry` | ECR `gkoi/{cms-server, cms-nginx, engine-api, engine-worker, engine-web, media-agent, media-origin, mediamtx, fm-api, fm-worker, fm-web, warroom-game}` (immutable tags, scan on push, keep last 20); registry replication of `gkoi/*` to euc1 + use1 with creation templates there; CodeBuild `gkoi-build-{aisolver-www, mikaido, filemanager}` (privileged, BUILD_GENERAL1_LARGE, S3 source `<repo>/source.zip`, local Docker layer cache), each with role `/gkoi/gkoi-build-<repo>` (read `<repo>/*`, read/write `cache/<repo>/*`, push its own repos, write `/gkoi/codebuild/<repo>`) | bucket `gkoi-build-sources-127214190346` |
| `observability` | Log groups (30 days): `/gkoi/prod2/ecs/<service>`, `/gkoi/prod2/ops`, `/gkoi/prod2/{media,game}/<region>/{container,syslog,bootstrap}` per enabled region; dashboard `gkoi-prod2` (ALB, RDS, Valkey, EFS); alarms → `gkoi-ops-alerts` (usw2): RDS CPU / storage / memory / connections, Valkey memory / CPU, ALB 5xx, per-target-group unhealthy hosts, EFS IO limit | the `gkoi-ops-alerts` topics; network, edge-alb and data state |
| `media` | Per enabled media region (usw2, euc1, use1 — all three by default; a map turns one off): an ASG of ONE EC2 media box (`m7i.xlarge`, Ubuntu 24.04, SSM only), its EIP, SGs (public RTMPS / ICE / CloudFront→443; the engine's private pool ports), role `/gkoi/gkoi-prod2-media-<key>`, `/gkoi/prod2/media/<key>/config`, rehearsal A records, alarms; once: the box bundle in the sources bucket, the usw2 box's rules on Valkey + the internal ALB. README in `envs/prod2/media/` | network, edge-alb (`engine_internal`), data, observability state; `gkoi/ci-nginx` in each region's ECR; the engine + origin-verify secrets (ARNs); `releases/mikaido.json`; zone `gkoi.com` |
| `compute` | ECS cluster `gkoi-prod2` (Container Insights, FARGATE); services `cms`, `engine-api`, `engine-worker`, `fm-api`, `fm-worker`, `fm-web` (each held at 0 while in `parked_services` — default all; `rehearsal = true` points the engine at the scratch bucket only); migrator task definitions `gkoi-prod2-{cms,engine,fm}-migrate`; 25 EMPTY secrets `gkoi/prod2/<app>/<NAME>`; execution roles `/gkoi/gkoi-prod2-exec-{cms,engine,fm}` + task roles `/gkoi/gkoi-prod2-task-*`; log group `/gkoi/prod2/ecs/engine-edge` | network, edge-alb, data, registry state; the existing `gkoi/edge/live-origin` secret (ARN only); the buckets `gkoi-beta-vods` / `gkoi-beta-files`; observability's log groups |
| `rehearsal` | The private go-live rehearsal driver: task definition `gkoi-prod2-rehearsal-driver` (Node 22 Alpine from ECR Public + ffmpeg; the driver inlined), roles `/gkoi/gkoi-prod2-{exec,task}-rehearsal-driver`, log group `/gkoi/prod2/ecs/rehearsal-driver`, SSM `/gkoi/prod2/rehearsal/run-config`. README in `envs/prod2/rehearsal/` | network, edge-alb, data, compute and media state; the gateway + origin-verify secrets (ARNs) |

**Service counts.** The services live in `compute`. `edge-alb`'s `services` variable carries each control-plane service's
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
5. `observability` (reads network, edge-alb and data)
6. `compute` (last: reads network, edge-alb, data and registry; writes into observability's log groups)
7. `media` (P5: after edge-alb's internal ALB, compute's registration in it, data's spoke Valkey rules and the
   `gkoi/ci-nginx` mirror push — `envs/prod2/media/README.md` "Apply order")
8. `rehearsal` (the private go-live rehearsal's driver task: after compute + media flipped their `rehearsal` switch —
   `envs/prod2/rehearsal/README.md`)

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
| `compute` | **~$160 + ~$10** | Fargate at min 1 ("The compute stack" below); 25 secrets × $0.40; Container Insights metrics; log ingestion $0.50/GB. A deploy briefly doubles a service. |
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
  `live_origin_secret_json_key`. The value lands in this stack's (encrypted) state. Terraform only READS it (a data source — no
  `random_password`, no `aws_secretsmanager_secret_version`): an apply never writes it. After its value is changed (audit
  B3-4), re-apply edge-alb (rules 10–12 carry the value and update in place) and force a new engine-api deployment (the
  edge reads it at task start).
- **edge-alb, the cms hosts (audit 2026-11-11 B4-2/3/4).** Prod's host nginx on the site box fronted the container nginx
  per name. The ALB reproduces: `origin-cdn` → only `/content/*` + `/assets/*` GET/HEAD (else 403 on those paths, 404
  elsewhere); `origin-labs` → `/content/labs/*` GET/HEAD, other GET/HEAD 302 to `https://www.gkoi.com/labs`, other
  methods 403; `gkoi.com` → 301 to `www`; `origin-www` + `www` → the whole site. It can NOT (provider < 6.0 has no rule
  `transform`): rewrite Host — so `origin-cdn` / `origin-www` / `origin-labs` reach the container nginx's DEFAULT (main)
  server, and the LABS server block (`server_name labs.invalid ${LABS_HOST}`) is never chosen: isolated-mode Labs builds
  lose their COOP/COEP/DIP headers until aisolver-www names the origin host there (or CloudFront labs forwards Host
  `labs.gkoi.com` and that name joins the cms hosts + certificate); nor strip `Cookie` / `Set-Cookie` /
  `X-Labs-Isolation` (harmless while no `CMS_LABS_ISOLATION_TOKEN` is set: no header value can match an empty token map).
- **edge-alb, the files allow-list (audit B3-6).** `files.gkoi.com`: `fm_public_paths` (prod's public listener:
  `/api/v1/app/*`, `/thumbs/*`, `/api/v1/healthz`, `/api/v1/readyz`) for everyone; every other path only from
  `cms_source_cidrs` (the Lightsail site box until P4, then the home NAT — which EVERY ECS task leaves by, the engine
  pilot included); else 404. Prod's nginx also refused dot-segment / `%2e` / `%2f` / `//` paths before routing; the ALB
  matches the raw path with no such guard: probe `curl --path-as-is https://files.gkoi.com/api/v1/app/../admin/…` after
  the apply (an ALB rule refusing those shapes is a possible follow-up).
- **registry, replication:** ECR replication is ONE registry-wide setting per region. This stack owns it in us-west-2; an
  existing replication configuration there (old workloads) would be replaced. Check with `ecr describe-registry` first.
- **data:** deletion protection is on and a final snapshot is taken; `terraform destroy` will fail until it is turned off.
- **Valkey from the media boxes (P5):** the media agent needs `REDIS_URL`; `valkey_peer_cidrs` defaults (null) to the
  network stack's `edge_cidrs` (Frankfurt + Virginia); the usw2 box gets an SG-referenced rule from the media stack.

## The compute stack (`envs/prod2/compute`)

ECS Fargate (amd64, platform 1.4.0) in the home VPC's private subnets, every task in the SG `gkoi-prod2-ecs-tasks`, no
public IP (ECR, logs, Secrets Manager, SSM through the interface endpoints; S3 through the gateway endpoint; the rest via
the NAT). Every service: min healthy 100 % / max 200 % (a deploy surges, never dips), the circuit breaker with rollback,
ECS Exec on, CPU target tracking at 60 % between min and max. The load-balanced services read min/max from `edge-alb`'s
`services` (raise them THERE); the workers from `worker_capacity` here. All are 1 / 1 today; the CMS stays at max 1
until C16 is proven on two tasks.

| Service | Containers (port) | Size | Notes |
|---|---|---|---|
| `cms` | `cache-init` (one shot) → `server` (8090) → `nginx` (8080 → target group `cms`) | 1 vCPU / 2 GB | EFS access point `/cms-content` at `/data/content`: read-write in `server`, READ-ONLY in `nginx`. A task volume `/data/nginx-cache` shared by both (the server purges what nginx caches); `cache-init` (the nginx image as root) hands it to uid 33 first, because a Fargate task volume starts root:0755. nginx waits for the server to be HEALTHY. |
| `engine-api` | `api` (3000) + `edge` (8080 → target group `engine-api`) | 1 vCPU / 2 GB | SPEC-ENGINE-EDGE-SIDECAR-V1. `engine_edge_sidecar = false` = the api alone on 3000 (a rehearsal before the edge image exists). The api trusts only 127.0.0.1 with the edge, the VPC CIDR without it. |
| `engine-worker` | `worker` | 1 vCPU / 2 GB, **60 GiB** ephemeral | The Download MP4 build's scratch is a task volume at `/scratch/vod-build` (`VOD_BUILD_DIR`). Worst case 130 min × 12 Mb/s ≈ 11.7 GB; the build needs ~2.2× ≈ 25.7 GB + the 2 GB reserve ≈ 27.7 GB, plus the image layers on the same disk: 60 GiB = 2× headroom. |
| `fm-api` | `api` (3200 → target group `fm-api`) | 0.5 vCPU / 1 GB | |
| `fm-worker` | `worker` | 0.5 vCPU / 2 GB | compose caps it at 1536 MiB |
| `fm-web` | `web` (80) | 0.25 vCPU / 0.5 GB | NOT in its target group (`fm_web_attach_lb = false`): edge-alb gives it no listener rule, and ECS refuses a target group no load balancer uses. See "fm-web" below. |

`engine-web` (the engine's admin test console) is NOT run: prod runs no engine web today (compose.engine.yml has none).

### Images and tags

`envs/prod2/releases/<repo>.json` (written by `tools/gkoi-release`, committed) pins each image by digest; the stack reads
every file there, and `-var 'images={...}'` (a tag or `sha256:…` per name) overrides one. A task runs
`<account>.dkr.ecr.us-west-2.amazonaws.com/gkoi/<name>@sha256:…` (or `:<tag>`). Until every needed image resolves, the
plan STOPS naming the missing ones (`terraform_data.preflight`); it also stops when the registry stack has no repository
for one (today: `engine-edge`), when a container references a secret the stack does not create, and while an env value
is still `__SET_ME__`. A release = commit the new `releases/<repo>.json`, run the migrator (below), then `compute` apply.

### Secrets: fill before the first task

The stack creates each `gkoi/prod2/<app>/<NAME>` EMPTY (no version — no value is ever in Terraform state); the
`secrets_to_fill` output lists them. A task whose secret has no value does not start. Fill each once:

```
aws secretsmanager put-secret-value --secret-id gkoi/prod2/engine/VAULT_MASTER_KEY --secret-string file://value.txt
```

(from a file you delete afterwards, never on a command line that lands in shell history). One value shared by two apps is
ONE secret: the CMS's `GATEWAY_SHARED_SECRET` IS `engine/GATEWAY_SHARED_SECRET`, its `FILES_SHARED_SECRET` IS
`fm/GATEWAY_SHARED_SECRET`. The engine's and the FM's `POSTGRES_PASSWORD` read their `POSTGRES_APP_PASSWORD` (their
schemas require the admin pair, and the RDS master never reaches a task — it stays RDS-managed). The three Redis URLs are
the data stack's Valkey (`gkoi/prod2/valkey`, key `url`) with a database number each — `engine/REDIS_URL` …`:6379/0`,
`fm/REDIS_URL` …`:6379/1`, `cms/RATE_LIMIT_REDIS_URL` …`:6379/2` (`rediss://`, TLS) — so a Valkey auth-token rotation updates
all three. The engine edge reads the existing `gkoi/edge/live-origin` (the ALB's lock reads the same one).

Per app: `cms` DB_PASSWORD, AUTH_ENCRYPTION_KEY, APP_API_SECRET, LABS_SUB_KEY, COMMERCE_PAYOUT_KEY, RATE_LIMIT_REDIS_URL,
SMTP_PASS · `engine` POSTGRES_APP_PASSWORD, REDIS_URL, SESSION_COOKIE_SECRET, VAULT_MASTER_KEY, GATEWAY_SHARED_SECRET,
RELAY_SHARED_SECRET, MK_POOL_READ_SECRET, MK_POOL_API_PASS, PREVIEW_TOKEN_KEY, TWITCH_CLIENT_SECRET, GOOGLE_CLIENT_SECRET,
KICK_CLIENT_SECRET · `fm` POSTGRES_APP_PASSWORD, REDIS_URL, SESSION_COOKIE_SECRET, VAULT_MASTER_KEY, GATEWAY_SHARED_SECRET,
CDN_PRIVATE_KEY_B64. Optional: `extra_secrets = { cms = ["CMS_LABS_ISOLATION_TOKEN"] }` + `cms_nginx_secret_env`.

Plain env: the defaults are in `env-defaults.tf`; the `*_env` variables are merged on top (one key at a time). The data
addresses (RDS endpoint, buckets, the VPC CIDR) come from state. `__SET_ME__` marks what only the prod box knows (the
CMS DB name/role, `SESSION_COOKIE_NAME` — must equal prod's or everyone is signed out once —, the SMTP set,
`MK_POOL_API_USER`, the platform client ids, the FM's `CDN_KEY_PAIR_ID`): pass them in a git-ignored
`*.tfvars` or `-var`, never a secret. The engine runs `RELAY_REGISTRY_ONLY=1` with NO `RELAY_POOL_INSTANCES`: the media
boxes register their pools (envs/prod2/media); never pass the Lightsail list here.

### Migrate, then update

Migrators run as ONE one-off task BEFORE the service update, never inside every task (the engine and FM migrators take no
lock). Same image and env as the service:

```
aws ecs run-task --cluster gkoi-prod2 --launch-type FARGATE --task-definition gkoi-prod2-engine-migrate \
  --network-configuration 'awsvpcConfiguration={subnets=[…],securityGroups=[…],assignPublicIp=DISABLED}'   # output run_task_network
aws ecs wait tasks-stopped …; check the container's exitCode = 0 (and its log /gkoi/prod2/ecs/engine-migrate)
# then: compute apply with the new release (the service rolls, surging to 2)
```

The CMS: `gkoi-prod2-cms-migrate` runs `node dist/index.js --migrate` (exit 0 ok · 1 failed · 2 db unreachable · 4 refused
· 5 no ack). A release carrying an `-- update: stop` migration (C17): override the command to
`["node","dist/index.js","--migrate","--enter-maintenance"]`, apply the service, then run it once more with
`["node","dist/index.js","--maintenance=off"]` when every task runs the new build. The CMS boot also migrates (additive files)
— the one-off run makes the order explicit. The FM's `bucket-init` one-shot does not exist here (the bucket and its CORS are
configured outside the app; `S3_CREATE_BUCKET=0`, `S3_MANAGE_CORS=0`).

### Roles

Execution roles, one per app (`/gkoi/gkoi-prod2-exec-{cms,engine,fm}`): `ecr:GetAuthorizationToken` + pull of its own
`gkoi/*` repos, logs to its own `/gkoi/prod2/ecs/*` groups, `GetSecretValue` on exactly the secret ARNs its containers
name. Task roles, one per service (`/gkoi/gkoi-prod2-task-*`), all with the four `ssmmessages` actions (ECS Exec):
`cms` EFS ClientMount/ClientWrite through the content access point; `engine-api` / `engine-worker` the recordings bucket(s)
(`gkoi-beta-vods` + `engine_extra_vod_buckets`), `cloudfront:CreateInvalidation` on vod.gkoi.com's distribution,
`cloudwatch:PutMetricData` in `GKOI/Engine` only; `fm-api` / `fm-worker` the assets bucket `gkoi-beta-files`; `fm-web` and
`migrate` (engine + FM migrators) nothing else. No task role reads Secrets Manager (ECS injects the values through the
execution role; the apps never call it) and no KMS grant is needed (the secrets use the AWS-managed key; both buckets
are SSE-S3).

### TLS to RDS

`PGSSLMODE=require` (encrypted, the certificate NOT verified): no image carries the RDS CA bundle yet, and `verify-full`
needs it (`PGSSLROOTCERT`). Bake the RDS global bundle into the three images, then set `PGSSLMODE=verify-full` +
`PGSSLROOTCERT=<path>` in the `*_env` maps.

### fm-web

The FM admin console is reached through the site's admin mount (`/admin/files-api/**` → the FM API), so nothing routes to
fm-web, and its nginx proxies `/api/` to `fm-api:3200` through Docker's resolver `127.0.0.11` — neither exists on Fargate.
It runs (min 1, ~$9/month) only because the target group exists; `fm_web_enabled = false` removes it.

### Monthly cost at min 1 (us-west-2 Fargate Linux/x86 list: $0.04048 per vCPU-hour, $0.004445 per GB-hour, 730 h)

| Service | Size | ≈ $/month |
|---|---|---|
| cms | 1 vCPU / 2 GB | 36.0 |
| engine-api | 1 vCPU / 2 GB | 36.0 |
| engine-worker | 1 vCPU / 2 GB + 40 GB extra ephemeral ($0.000111/GB-h) | 39.3 |
| fm-api | 0.5 vCPU / 1 GB | 18.0 |
| fm-worker | 0.5 vCPU / 2 GB | 21.3 |
| fm-web | 0.25 vCPU / 0.5 GB | 9.0 |
| **Total** | | **≈ $160** (+ 25 secrets ≈ $10, Container Insights, log ingestion; migrators cost seconds) |

### Things to decide / know before the first apply

- **engine-edge:** the registry has no `gkoi/engine-edge` repository and the mikaido buildspec does not build it yet
  (lane B, SPEC-ENGINE-EDGE-SIDECAR-V1). Until both exist, plan with `engine_edge_sidecar = false` or the preflight stops.
  The edge's env names (`EDGE_TLS`, `EDGE_API_HOST`, `EDGE_LIVE_ORIGIN_HOST`, `UPSTREAM`, `REALIP_MODE`, `EDGE_REALIP_FROM`,
  `EDGE_LIVE_ORIGIN_SECRET`) are the spec's — align them with the image.
- **edge-alb's `engine-api` entry** still says port 3000 / health `/api/v1/healthz`. ECS registers the task at the edge's
  8080 (the target group's port is only a default) and the health check follows the traffic port, so it works — and the
  ALB→tasks SG rule for 8080 exists only because the CMS uses 8080 too. Set edge-alb's `engine-api` port to 8080 (and the
  health path to the edge's own, `/healthz` per E3) so the SG rule and the check are explicit.
- **Service to service:** `MIKAIDO_ENGINE_URL` / `FILES_SERVICE_URL` default to the PUBLIC names (CMS → NAT → ALB). That
  works, but costs NAT processing and hides the viewer's address behind the NAT IP on the engine's side. A private path
  (ECS Service Connect / an internal ALB) is not built — decide before P3/P4.
- **Wait for steady state:** off by default (an apply returns once ECS accepted the new task definition); set
  `wait_for_steady_state = true` to have an apply fail on a rollback.
