# `envs/prod2/media` — the GKOI media boxes on EC2 (P5)

PLAN-AWS-MIGRATION-PROD2-V1 §P5. One ASG of ONE EC2 instance per enabled region (`var.media_regions`: usw2 / euc1 /
use1 / apne1 — Tokyo added 2026-11-11, "Adding Tokyo (apne1)" below), each running the media agent, N MediaMTX relay pools and the
regional live origin, and **registering its pools with the engine** (SPEC-ENGINE-DYNAMIC-REGIONS-V1 C1:
`MEDIA_BOX_INSTANCES`, no `RELAY_POOL_INSTANCES` entry). Per the 2026-11-11 gap audit (B3-2/B3-3) the media plane moves
**with** the engine: these boxes are brought up and proven privately first, then ONE window flips engine + FM + media.

State: `prod2/media/terraform.tfstate`. Defaults: all four regions enabled, one box each (three by the P5 ruling; Tokyo
added 2026-11-11, media only).

## What an apply creates

Per enabled region (`modules/media-box`, in that region):

| Resource | Detail |
|---|---|
| ASG `gkoi-prod2-media-<key>` | min / desired / max 1 (validation: max ≤ 1 — one EIP per region); EC2 health; group metrics; a terminate lifecycle hook `drain` (heartbeat 900 s, default CONTINUE); **no instance refresh** (see "Replacing the box") |
| Launch template | Canonical Ubuntu 24.04 amd64 (SSM public parameter), `m7i.xlarge` (plan §1: 4 vCPU / 16 GiB, x86 — the images are amd64), gp3 100 GiB encrypted, IMDSv2 only with **hop limit 2** (the agent's S3 client uses the instance role from inside its container), public IP at launch, user-data = only the config parameter's name |
| Elastic IP | stable address for DNS; the box associates it to itself at boot (`phase eip`) |
| SG `gkoi-prod2-media-<key>` | public: RTMPS tcp 11936 / 21936, WebRTC ICE udp 8189 / 8289 (per pool); private: HLS 18888/28888, WHIP/WHEP 18889/28889, control API 19997/29997 from the engine only (home: the ECS tasks SG; spokes: the home VPC CIDR over peering). NOT open: plain RTMP 11935/21935, 22, 80 — exactly the live Lightsail firewall minus its stray 22/80 |
| SG `…-origin` | 443 from CloudFront's origin-facing prefix list (its own SG: the list weighs ~55 rules); `origin_ingress_cidrs` for a tester; `origin_open_to_world` = the Lightsail rule |
| IAM role + profile `/gkoi/gkoi-prod2-media-<key>` | SSM core + CloudWatch agent (managed); ECR pull of `gkoi/{media-agent,mediamtx,media-origin}` in its region; `GetSecretValue` on exactly the 5 engine secrets + its region's origin-verify; its own SSM parameter; S3 GET on the box bundle + `mikaido/*/source.zip`; the recordings bucket (the engine task role's object set); `AssociateAddress` on its own EIP (tag-conditioned); its own ASG's lifecycle calls; Route 53 TXT `_acme-challenge.<its 4 names>` only |
| SSM `/gkoi/prod2/media/<key>/config` | the box's whole configuration (no secret values: secrets are named by ARN) |
| Route 53 | A records (TTL 60) → the EIP for the two **rehearsal** names; the two **live** names only with `manage_live_records` (allow_overwrite + `prevent_destroy`) |
| Alarms → the region's `gkoi-ops-alerts` | in-service < min (10 min), CPU > 75 % (15 min), status check (5 min), disk > 80 % |

Once, in us-west-2: the box bundle in `s3://gkoi-build-sources-…/gkoi-infra/media-box/` (stable keys; the config
carries each file's sha256); the Valkey SG rule and the internal-ALB SG rule for the usw2 box (both SG references).

Elsewhere (this P5 work, other stacks): **edge-alb** owns the internal ALB `gkoi-prod2-engine-internal` (+ target
group `gkoi-prod2-engine-api-int`, its SG admitting every peered edge VPC on 3000, the ECS-tasks SG rule) and outputs
`engine_internal`; **compute** registers engine-api's `api:3000` in it (`extra_load_balancers`) and runs the engine with
`RELAY_REGISTRY_ONLY=1` and no `RELAY_POOL_INSTANCES`; **data** admits network's `edge_cidrs` to Valkey by default;
**registry** has `gkoi/ci-nginx` (the media origin's image mirror).

## Design choices

- **Registry mode, no static list.** `MEDIA_BOX_ID = <slug>-<instance id>` (one per INSTANCE: a replacement box never
  inherits a departed box's pool ids — A2/A4 re-claim or end those sessions), pool ids `<box>-p<i>`, its own queue
  `relay-box-<box>`. `MEDIA_BOX_INSTANCES` is rendered on the box from IMDS (private IP = `apiHost`) and the config:
  `publicHost` = the stream host, ports `(i+1)1935/1936/8888/8889/9997` and ICE `8189+100·i` exactly as the live box,
  `liveOriginBase https://live.gkoi.com`, `label` Oregon / Frankfurt / Virginia / Tokyo (the engine's built-in `REGION_LABELS` knows only us-west-2 + eu-central-1;
  the config's `label` wins for every region).
- **How a box reaches the engine (`PORTAL_INTERNAL_URL`).** The agent calls `/internal/**` (publish-auth on every
  publish, ingest heartbeats, session state/health, vod events). The public path cannot carry it: the engine edge
  (ECS sidecar, same `edge.conf.template`) answers `/internal/` with 404. Service Connect serves ECS clients only;
  Cloud Map DNS would need its private zone associated with every peered VPC and has no health gate. Chosen: an
  **internal ALB** (in the edge-alb stack, which owns every load balancer and target group, so no stack reads a
  later one) in the home private subnets, listener :3000 forwarding only `/internal/*` + `/api/v1/healthz` to the
  api container's own port 3000 (404 otherwise). Its DNS name is public DNS → private IPs, so every peered VPC uses it
  with no DNS work; peering traffic between regions is encrypted by AWS; the api authenticates these routes with the
  relay secret only (no source-address rule). `HTTP_KEEPALIVE_MS=55000` < the ALB's 60 s idle timeout (G4/G6).
- **Valkey** (`rediss://`, auth token): the agent reads `gkoi/prod2/engine/REDIS_URL` (the engine's own db /0 — the
  registry and the relay queues live there). Node's trust store accepts ElastiCache's certificate (no
  `REDIS_TLS_CA_FILE`). `REDIS_REQUIRE_NOEVICTION` stays unset (CONFIG is refused on ElastiCache; the parameter group
  enforces noeviction — as compute).
- **Images by digest from the box's own region's ECR** (registry replication, checked 2026-11-11: both digests of
  `gkoi-2026.11.11-1` are in euc1 + use1). `media-origin` is stock nginx with the engine's rendered config: the live
  box's exact image (`nginx:1.27-alpine`, Docker Hub index `sha256:65645c7b…`, amd64) mirrored once into
  `gkoi/ci-nginx:1.27-alpine` (replicated); each region resolves the tag to its digest at plan time (a missing push or
  replica stops the plan). No Docker Hub at boot. `media_origin_image_override` is the emergency escape.
- **The engine's config files** (`pool.yml`, `pool-entrypoint.sh`, `media-live-origin-entrypoint.sh`,
  `media-live-origin.conf.template` — bind-mounted by compose on the live box) come from the SAME release's
  `source.zip` that CodeBuild built the images from, checked against `releases/mikaido.json`'s `source_sha256`. No
  copies in this repo, no drift.
- **Compose** is rendered on the box (`media-bootstrap.sh render`): the live box's `compose.media.yml` +
  `compose.pool-rtmps.yml` + the media-origin profile flattened (same healthchecks, grace periods, ulimits, env split:
  the pools never see the agent's env). Secrets reach containers only through `/etc/gkoi-media/{agent,pool,origin}.env`
  (0600, single-quoted literal values). The resolver secret between nginx and the agent is box-local (generated once).
- **TLS:** Let's Encrypt per hostname by DNS-01 with the instance role (as the live box: `certbot --dns-route53`, ECDSA,
  lineage `/etc/letsencrypt/live/<host>/` — the path MediaMTX and the origin read). All four names of a region (2
  rehearsal + 2 live) are issued at first boot, so the window needs no cert step. Renewal: certbot's own timer
  (`snap.certbot.renew.timer` / Ubuntu's `certbot.timer` / `gkoi-certbot-renew.timer` — "No snap store needed" below) →
  `cert-hook.sh` (origin: `nginx -s reload`; pools: restart only when the box is idle, else an hourly retry — the
  engine's own hook rule). The plan's "wildcard in Secrets Manager" was not needed: per-name DNS-01 works on EC2.
- **The ASG** gives self-healing (a failed box is replaced) and the drain hook; with one EIP per region it is held at
  max 1 and has no instance refresh (a new box would take the address from the live one).
- **`roll.sh`** rolls a release IN PLACE over SSM (drain → wait idle → recreate → undrain); a release never replaces
  the instance.

## Apply order (cross-stack)

Every step through the runner, from a clean checkout of the branch/tag (`tools/gkoi-infra-run <stack> plan`, read the
summary, then `apply`). `network`, `observability` are unchanged.

| # | Command | What it creates / changes |
|---|---|---|
| 0 | **by hand:** the nginx mirror push (below) — after step 1 | `gkoi/ci-nginx:1.27-alpine` in us-west-2, replicated to euc1 + use1 |
| 1 | `tools/gkoi-infra-run registry apply` | + ECR repo `gkoi/ci-nginx` (immutable, scan, keep 20; replication covers `gkoi/*`) |
| 2 | `tools/gkoi-infra-run edge-alb apply` | + the internal ALB, its target group, listener :3000 (404 default) + the `/internal/*` + health rule, its SG (ingress 3000 from every `edge_cidrs` VPC, egress to the tasks SG), the tasks-SG ingress 3000 from it; output `engine_internal` |
| 3 | `tools/gkoi-infra-run data apply` | + Valkey ingress 6379 from 10.20.0.0/16 (euc1) and 10.30.0.0/16 (use1) |
| 4 | `tools/gkoi-infra-run compute apply` (maybe `--allow-destroy`, see below) | engine-api gets a second load balancer (`api:3000` → the internal TG); engine env: `RELAY_REGISTRY_ONLY=1` added, `RELAY_POOL_INSTANCES` removed (new task definitions for api / worker / migrate; services stay parked at 0) |
| 5 | `tools/gkoi-infra-run media apply` | the three boxes (per region: ASG + launch template, EIP, 2 SGs, role + profile, SSM config, 2 rehearsal A records, 4 alarms), the bundle objects, the usw2 Valkey + internal-ALB rules |

Order matters: media reads edge-alb's `engine_internal` (its plan STOPS without it) and the ci-nginx digests (STOPS if
not pushed/replicated); compute reads `engine_internal` with `try()` (it still plans if edge-alb has not been applied
yet — it then registers nothing extra). **Step 4 and `load_balancer`:** whether the AWS provider (5.100) updates an
ECS service's load balancers in place or REPLACES the service was not verified offline — read the plan: a replace of
`module.engine_api…aws_ecs_service.this` needs `--allow-destroy` (harmless while parked at 0 tasks; the service name
is kept).

The secrets this stack reads (all eight exist WITH a value — DescribeSecret, 2026-11-11; values not read):
`gkoi/prod2/engine/{REDIS_URL,RELAY_SHARED_SECRET,MK_POOL_API_PASS,MK_POOL_READ_SECRET,PREVIEW_TOKEN_KEY}` and
`gkoi/media/<key>/origin-verify` (32–128 of `[A-Za-z0-9_-]` — the origin entrypoint refuses anything else; plain
string, or set `origin_verify_secret_json_key`). Nothing to fill.

The runner role also needs `s3:PutObject` on `gkoi-build-sources-…/gkoi-infra/media-box/*` (the bundle) — see open
questions.

### The nginx mirror (by hand, once — the orchestrator's role may push `gkoi/ci-*`)

```
R=127214190346.dkr.ecr.us-west-2.amazonaws.com
gkoi-aws ecr get-login-password --region us-west-2 | docker login --username AWS --password-stdin $R
docker pull --platform linux/amd64 nginx@sha256:65645c7bb6a0661892a8b03b89d0743208a18dd2f3f17a54ef4b76fb8e2f2a10   # = nginx:1.27-alpine, the live media box's
docker tag nginx@sha256:65645c7bb6a0661892a8b03b89d0743208a18dd2f3f17a54ef4b76fb8e2f2a10 $R/gkoi/ci-nginx:1.27-alpine
docker push $R/gkoi/ci-nginx:1.27-alpine
# replication takes a minute or two; check both replicas before the media plan:
for r in eu-central-1 us-east-1; do gkoi-aws ecr describe-images --region $r --repository-name gkoi/ci-nginx --image-ids imageTag=1.27-alpine --query 'imageDetails[0].imageDigest' --output text; done
```

(The pushed digest is the amd64 manifest's, not Docker Hub's index digest — the stack resolves the tag, so either is
fine; all three regions must print the same digest.)

## Bring one region up privately and prove it against the ECS engine

1. Apply (all three regions are enabled by default; to go one at a time, set `enabled = false` on euc1 / use1 in a
   tfvars first). The ASG launches; the box bootstraps itself (~5–8 min:
   packages, certs, pulls). Follow it in CloudWatch `/gkoi/prod2/media/<key>/bootstrap`, or over SSM:
   `aws ssm start-session --target <instance>` → `sudo /opt/gkoi-media/media-bootstrap.sh check` (exit 0 = EIP on the
   box, 4 certs, env files, every container healthy, lifecycle watcher up; it prints the agent's `/drain` report).
   **Steps 2–5 are automated:** the rehearsal driver (`envs/prod2/rehearsal/README.md`: the rehearsal switch in
   compute + media, the scratch bucket, `tools/gkoi-rehearsal`) runs them for every region from an ECS task and prints
   PASS/FAIL. The manual version, for digging into a failure:
2. **Registration:** the agent log shows its box id + pools; `redis-cli` (from an ECS Exec shell in engine-api) →
   `SMEMBERS relay:registry:pools`, `GET relay:registry:pool:<box>-p0` (TTL 30 s, re-written every 10 s). With the
   engine unparked (rehearsal: api + worker — compute `parked_services`; `RELAY_REGISTRY_ONLY=1` is compute's default now):
   `GET https://engine.gkoi.com/api/v1/app/regions` through the ALB (`curl --connect-to engine.gkoi.com:443:<alb dns>:443`)
   lists the region with its label and probe host `stream-<key>-p2.gkoi.com`; the engine logs no "dropped registration".
3. **Go-live test:** a test user's relay session on the rehearsal DB (a copy of prod) placed in this region → the
   ingest URL names `rtmps://stream-<key>-p2.gkoi.com:11936/…`; publish to it (the app, or ffmpeg with the session's
   key); the agent's publish hook asks `/internal/relay/publish-auth` through the internal ALB → admitted; the session
   goes live; the api's watch proxy reads HLS from `<private ip>:18888` (proves the private SG path).
4. **Recording:** stop the session; the agent uploads the pieces + playlist to the recordings bucket and posts the
   vod event; the worker finalises it (check the vod row + the objects under its key). The bucket: with `rehearsal =
   true` here AND in compute, the data stack's SCRATCH bucket (`gkoi-prod2-rehearsal-vods-…`, 3-day expiry) — the
   boxes' and the engine's roles then cannot write `gkoi-beta-vods` at all; without the switch it is the LIVE
   `gkoi-beta-vods` (audit B3-7) — do not record there from the rehearsal DB.
5. **HLS via the origin:** `curl -H "X-Origin-Verify: <the region's secret>" https://origin-live-<key>-p2.gkoi.com/r/<key>/live/<sid>/hls/index.m3u8`
   from a CIDR in `origin_ingress_cidrs` (the SG admits only CloudFront otherwise; `rehearsal = true` adds the home NAT,
   so an ECS task / ECS Exec shell can) → 200 while live; without the header
   → 403; an unknown session → 404. (A request through CloudFront needs the window's origin change.)
6. **Drain / lifecycle:** over SSM `docker exec <agent> node -e …/drain` POST → the engine stops placing there; DELETE
   clears it. Optionally set the ASG desired to 0 once: the watcher drains, completes the hook; the registry entry
   expires within 30 s.
7. Re-park the engine services (and turn the rehearsal switch off — `envs/prod2/rehearsal/README.md` step 10). Repeat
   the proof for euc1 and use1.

## The window (engine + FM + media, nobody live)

Before: lower nothing (the four live records are TTL 300 already — wait ≥ 5 min after each flip); have the Lightsail IPs
for the rollback (stream.gkoi.com + origin-live-usw2 → `34.212.239.200`, stream-euc1 + origin-live-euc1 → `63.179.228.39`).

1. P3's own steps (dump/restore, compute unparked — the engine already runs registry-only, no static list —
   `engine` / `files` / `origin-live` → the ALB). The Lightsail media agents lose Redis at that moment — expected.
2. Per media region: `serve_live_names = true`, `manage_live_records = true`; apply `media`. The config now names the
   live hosts; the A records `stream[-euc1].gkoi.com` + `origin-live-<key>.gkoi.com` move to the EIP.
3. On each box: `roll.sh` over SSM (re-renders `publicHost`, the pools' RTMPS cert path, the origin's server name; the
   live-name certs were issued at boot). The agent re-registers with the live publicHost within 10 s.
4. CloudFront `live.gkoi.com` (E18952ZBU48RL9, hand-managed): set each region origin's `X-Origin-Verify` to the value
   in `gkoi/media/<key>/origin-verify` (the P5 rotation). Between steps 2 and 4 that region's `/r/<key>/*` answers 403
   (nobody live). **use1:** add an origin `origin-live-use1.gkoi.com` (https-only, TLSv1.2, the header, origin request
   policy `gkoi-live-viewer`) and a behaviour `/r/use1/*` like `/r/usw2/*` before taking traffic there; `stream-use1`
   and `origin-live-use1` are new names, so use1 can use `manage_live_records` any time.
5. Prove: an app go-live per region (RTMPS on `stream*.gkoi.com`), HLS through `live.gkoi.com/r/<key>/…`, a recording
   finalised, a WHEP preview (ICE UDP 8189).
6. Stop the Lightsail media stacks (do not delete; P7 retires them).

## Rollback

- **Before the window** (rehearsal): set `enabled = false` and apply — everything of that region goes (the rehearsal
  names included). Nothing live is touched.
- **In / after the window** (back to Lightsail): the engine itself must go back too (P3's DNS rollback) — the Lightsail
  agents only work against the Lightsail Redis. Then: (1) UPSERT the four live A records to the Lightsail IPs above
  (Route 53 console/CLI); (2) CloudFront origin headers back to the old values; (3) `terraform state rm
  'module.box_<key>[0].aws_route53_record.live["<name>"]'` for each live name; (4) `manage_live_records = false`,
  `serve_live_names = false`, apply. Skipping (3) makes the plan STOP (`prevent_destroy`) instead of deleting a live
  name — on purpose.
- **A bad release:** revert `releases/mikaido.json` (or `var.images`), apply, `roll.sh --drain-wait 60`.

## No snap store needed (2026-11-11)

The first Tokyo box could not reach `api.snapcraft.io` for 15+ minutes (and two game boxes hit the same flakiness that
day), so nothing on a box depends on the snap store any more:

- **user-data** (media + game) no longer uses the AWS CLI at all: the config parameter and the bundle are fetched with
  `python3-boto3` (on Canonical's 24.04 AMI — cloud-image manifest; apt-installed if a future AMI lacks it) with the
  instance role, every file sha256-checked as before.
- **The AWS CLI** (`media-lib.sh` / `game-lib.sh` `ensure_aws_cli`): an `aws` that runs is kept; else the snap (three
  tries, 90 s each); else the pinned v2 zip `awscli-exe-linux-x86_64-2.39.7.zip` (sha256 `707a900f…`, whose PGP signature
  was checked against the AWS CLI Team key FB5D B77F … 475C on 2026-11-11) into `/usr/local/aws-cli` + `/usr/local/bin/aws`.
  Bump `AWSCLI_VERSION` + `AWSCLI_SHA256` together (in BOTH libs).
- **certbot + dns-route53** (`media-lib.sh` `ensure_certbot`): a certbot that lists `dns-route53` is kept; else the snaps;
  else Ubuntu's `certbot` + `python3-certbot-dns-route53` (noble universe 2.9.0, renewed by `certbot.timer`); else a venv
  `/opt/certbot` (certbot + certbot-dns-route53 5.10.0 from PyPI, renewed by `gkoi-certbot-renew.timer`, written here).
  The deploy hook stays `/etc/letsencrypt/renewal-hooks/deploy/gkoi-media` → `cert-hook.sh` (every variant runs it).
  After three failed snap attempts the store counts as down for the rest of the run.
- **The SSM agent**: left alone when running (Canonical's preinstalled snap); started if installed but stopped; a missing
  agent is only a warning.
- **Game boxes:** certbot and the SSM check live in the War Room tool (`ops/warroom-game/bootstrap.sh`, GKOIBuilder_AI),
  which still requires the snaps — not changed here.

## Releases

Commit `releases/mikaido.json` (tools/gkoi-release) → apply `media` (rewrites the config parameter: digests, the engine
`source.zip`, the bundle) → on each box:

```
aws ssm send-command --region <r> --document-name AWS-RunShellScript \
  --targets Key=tag:aws:autoscaling:groupName,Values=gkoi-prod2-media-<key> \
  --parameters 'commands=["/opt/gkoi-media/roll.sh --drain-wait 60"]' --timeout-seconds 7200
```

`roll.sh --dry-run` shows the compose diff first. The roll drains the box (with one box per region, the region takes no
new sessions meanwhile), waits for idle (sessions, recordings uploaded, builds), recreates, undrains; still busy after
the wait → refused (exit 3) and the drain cleared; `--force` cuts the live streams. A change to `box/*` (the scripts)
reaches a running box the same way (every file is sha256-checked against the config).

## Replacing the box / more than one box per region

- **Replacing** (a new AMI, instance type, disk): the launch template changes on apply; the running box is not
  touched. In a quiet hour: drain it (roll.sh's drain, or `set-desired-capacity 0` — the hook drains and lets go),
  then desired 1: the new box takes the EIP (`phase eip` refuses while another instance holds it; it is free once the
  old one terminated, or `GKOI_MEDIA_TAKE_EIP=1`) and registers under its new box id.
- **More than one:** the engine side is ready (per-box ownership, A4 re-claim, A5 cross-box live origin). Here: one EIP
  per box (a pool of EIPs, or public IPs + per-box stream hosts), `publicHost` per box, the origin behind an NLB/ALB
  per region (C5), the validation `max ≤ 1` lifted. Not built (operator: server counts min/max 1 for now).

## Adding Tokyo (apne1) — 2026-11-11

A FOURTH media region: `ap-northeast-1`, key `apne1`, label "Tokyo", ONE `m7i.xlarge` box. Streaming only: the game
stack keeps `game_regions.apne1.enabled = false` (its plan stays "No changes").

What this branch changes: `modules/regions` (apne1 enabled → network / registry / observability create their apne1
parts, which were already written behind the flag), this stack (provider `aws.apne1`, `data.aws_ecr_image.origin_apne1`,
`module.box_apne1`, the `apne1` default — rehearsal names first — and `apne1` allowed by the `media_regions` validation),
the tests. `data` and `edge-alb` need NO edit: both read network's `edge_cidrs`, so a re-apply adds 10.40.0.0/16.

**Facts read 2026-11-11 (read-only):** Running On-Demand Standard vCPU quota in ap-northeast-1 = **640** (L-1216C47A; a
request for 64 is `CASE_CLOSED` — not 5: the box's 4 vCPUs fit with room for a game box); nothing runs there (no
instance, ASG, EIP, ECS cluster, log group, peering; only the default VPC 172.31/16); the Canonical 24.04 SSM parameter
resolves there (`ami-0830d2e7c1f17b903`); `m7i.xlarge` is offered in 1a / 1c / 1d (the VPC takes the first two, 1a + 1c);
none of `stream-apne1[-p2]` / `origin-live-apne1[-p2]` `.gkoi.com` exists in the zone; no SNS topic in ap-northeast-1;
the secret `gkoi/media/apne1/origin-verify` does not exist; ECR replication = euc1 + use1 only, no repository in
ap-northeast-1. (`gkoi-aws service-quotas get-service-quota` is DENIED for the orchestrator role — read through the
MCP sign-in.)

**The engine needs nothing** (checked at f997524): `regionSlug("ap-northeast-1")` = `apne1` (`liveOrigin.ts`; no
collision — `validateRegionSlugs` / `screenRegistrations` would drop a clash); there is NO region allow-list (the api
runs `RELAY_REGISTRY_ONLY=1`; a registry-only pool is screened only for a bad region name, a queue/slug owned by
another region); the label comes from the box's `MEDIA_BOX_INSTANCES` entry (`REGION_LABELS` knows only Oregon +
Frankfurt; the instance's own label wins); the HLS path is `liveOriginBase` (`https://live.gkoi.com`) + `/r/apn1/…`;
`/api/v1/app/regions` returns one row per region with a healthy, non-draining box (no cap in the engine; four rows).
No compute variable changes. The CMS needs nothing for streaming (its `GAME_REGION_CODES` already list apne1 — game only).

**READ THIS FIRST — there is no private bring-up any more.** The engine is LIVE. The moment the Tokyo agent registers
(seconds after the box's containers start) `/api/v1/app/regions` offers "Tokyo" to every GKOI Live app, and the apps'
region probe sends nearby streamers there. A drained box is hidden, but a drained box also refuses placement, so it
cannot be tested drained. And while the box serves the REHEARSAL names, CloudFront cannot reach it under the live
origin name: the origin nginx presents the certificate of the name it serves (`server_name` + lineage of
`MEDIA_ORIGIN_HOST`), so an origin `origin-live-apne1.gkoi.com` would fail TLS (502) — viewers of a Tokyo stream would
see nothing. Two ways, pick one BEFORE step 9:

- **Path A (as briefed): rehearsal names first.** The defaults in this branch. CloudFront's new origin then points at
  `origin-live-apne1-p2.gkoi.com` (step 8) and is re-pointed at the switch (steps 12–13). One extra roll + CloudFront edit.
- **Path B (recommended): live names from the first boot.** Both live names are NEW (nothing to take over, as use1):
  in `variables.tf` set `serve_live_names = true` + `manage_live_records = true` on apne1 in the same commit before
  step 9; CloudFront points at `origin-live-apne1.gkoi.com` once (step 8); no steps 12–13, no roll. The test (step 10) is the
  same; the region is public from step 9 either way.

Either way, do steps 1–8 first, so that the region works end to end the moment it appears. If the test fails: drain
it at once (step 10's "stop" line), fix, undrain.

Runner: `tools/gkoi-infra-run <stack> plan` → read the summary → `tools/gkoi-infra-run <stack> apply` (from a clean
checkout of the merged commit). "MCP" = a step the orchestrator role (`gkoi-aws`) may NOT do — run it through the AWS
MCP sign-in (boto3 in `run_script`); every value is created and used inside AWS, never printed.

| # | Step | Expect |
|---|---|---|
| 1 | **MCP — the alerts topic** (below) | `arn:aws:sns:ap-northeast-1:127214190346:gkoi-ops-alerts`, one email subscription (pending until confirmed) |
| 2 | `network` | **+28, 0 change, 0 destroy**: `module.vpc_apne1[0]` (VPC 10.40/16, IGW, 4 subnets, 3 route tables + 4 associations, the IGW route, S3 gateway endpoint, flow log + `/gkoi/prod2/vpc-flow/apne1`, the locked default SG = 18) + `module.peer_apne1[0]` (peering + accepter + 2 options + 6 routes: 10.40/16 in usw2's 3 route tables, 10.10/16 in apne1's 3 = 10). No change to usw2 / euc1 / use1 resources. |
| 3 | `registry` | **+1, 1 change, 0 destroy**: `module.template_apne1[0].aws_ecr_repository_creation_template.this`; `aws_ecr_replication_configuration.this[0]` gains the ap-northeast-1 destination (update in place) |
| 4 | **MCP — ECR backfill** (below): replication copies NEW pushes only | the three images in ap-northeast-1 with the source digests |
| 5 | `observability` | **+6**: `/gkoi/prod2/{media,game}/apne1/{container,syslog,bootstrap}` (30 days; the game ones stay empty). Output `alerts_topic_arns.apne1`. The plan FAILS if step 1 was skipped (`data.aws_sns_topic.alerts` in apne1). |
| 6 | `data`, then `edge-alb` | **+1 each**: `aws_vpc_security_group_ingress_rule.valkey_from_peers["10.40.0.0/16"]`; `aws_vpc_security_group_ingress_rule.engine_internal_spokes["apne1"]` (tcp 3000). Nothing else. |
| 7 | **MCP — the origin-verify secret** (below) | `gkoi/media/apne1/origin-verify` in us-west-2, 64 × `[A-Za-z0-9]` |
| 8 | **MCP — CloudFront** (below): origin `origin-live-apne1` + behaviour `/r/apn1/*` | `InProgress` → deployed; probe → 502 (no box / no DNS yet — expected until step 9) |
| 9 | `media` (Path B: after the two-line edit) | Path A **+29**, Path B **+31**; 0 destroy; all under `module.box_apne1[0]` (ASG, launch template, EIP, 2 SGs + 11 ingress + 1 egress rules, role + policy + 2 attachments + profile, SSM `/gkoi/prod2/media/apne1/config`, 4 alarms, the 2 rehearsal A records; Path B also the 2 live A records `stream-apne1` + `origin-live-apne1` — new names, nothing overwritten). `data.aws_ecr_image.origin_apne1` read. **No change to the usw2 / euc1 / use1 boxes' config, ASG, records, the bundle or the Valkey/ALB rules.** The one tolerated change elsewhere: a launch template update in another region if Canonical's AMI parameter moved since the last apply (no instance refresh — the running boxes are untouched). Anything else = stop. |
| 10 | Bring-up + test (below) | `check` exit 0 on the box; Tokyo in `/app/regions`; the scripted go-live passes |
| 11 | `game` + `compute` plans only | **No changes** (the catalogue flag does not touch them) |
| 12 | Path A only — the records: commit `manage_live_records = true` on apne1; `media` apply | **+2**: `module.box_apne1[0].aws_route53_record.live["stream-apne1.gkoi.com"]` + `["origin-live-apne1.gkoi.com"]` → the EIP (new names, nothing overwritten). The box still serves the rehearsal names; nothing uses the live ones yet. |
| 13 | Path A only — the names: commit `serve_live_names = true` on apne1; `media` apply; the roll (below); at once CloudFront's `origin-live-apne1` domain → `origin-live-apne1.gkoi.com` (step 8, the re-point variant) | media: **1 change** (`aws_ssm_parameter.config`: stream/origin host). Between the roll and the CloudFront edit `/r/apn1/*` answers 502 — do them back to back, in a quiet minute (the roll drains Tokyo while it runs). |

### Step 1 — the alerts topic in ap-northeast-1 (MCP)

The three existing topics were made by hand (P0): policy = CloudWatch / Budgets / EventBridge may publish (source
account), the account root may manage; tag `project=gkoi`; one email subscription. Same here, copied from us-west-2:

```python
src = "arn:aws:sns:us-west-2:127214190346:gkoi-ops-alerts"
dst = "arn:aws:sns:ap-northeast-1:127214190346:gkoi-ops-alerts"
pol = (await call_boto3(service_name="sns", operation_name="GetTopicAttributes", region_name="us-west-2",
                        params={"TopicArn": src}))["Attributes"]["Policy"].replace(src, dst)
t = await call_boto3(service_name="sns", operation_name="CreateTopic", region_name="ap-northeast-1",
                     params={"Name": "gkoi-ops-alerts", "Attributes": {"Policy": pol}, "Tags": [{"Key": "project", "Value": "gkoi"}]})
subs = await call_boto3(service_name="sns", operation_name="ListSubscriptionsByTopic", region_name="us-west-2", params={"TopicArn": src})
n = 0
for x in subs["Subscriptions"]:
    if x["Protocol"] == "email":
        await call_boto3(service_name="sns", operation_name="Subscribe", region_name="ap-northeast-1",
                         params={"TopicArn": t["TopicArn"], "Protocol": "email", "Endpoint": x["Endpoint"]})
        n += 1
result = {"topic": t["TopicArn"], "email_subscriptions_requested": n}
result
```

The address then gets a confirmation mail. **Note:** on 2026-11-11 the email subscription of EVERY existing
`gkoi-ops-alerts` topic (usw2, euc1, use1) is still `PendingConfirmation` — no alarm reaches anyone today.

### Step 4 — the images in ap-northeast-1 (MCP: `ecr:StartReplicationBackfill`)

ECR replicates only images pushed AFTER a destination is configured ("Only repository content pushed or restored to a
repository after replication is configured is replicated" — ECR user guide, Private image replication). The existing
images reach a new destination through a **replication backfill** (one per destination; it copies every image that
matches the CURRENT rules — `gkoi/*`: 17 repos, ~2.2 GB on 2026-11-11 ≈ $0.22/month of replica storage; tags come with
the images, so `gkoi/ci-nginx:1.27-alpine` resolves there). After step 3:

```bash
aws ecr start-replication-backfill --region us-west-2 --registry-id 127214190346 \
  --destination region=ap-northeast-1,registryId=127214190346          # → replicationBackfillId
aws ecr list-replication-backfills --region us-west-2 --registry-id 127214190346   # until COMPLETE (minutes)
# then (gkoi-aws may read ECR):
for r in gkoi/media-agent gkoi/mediamtx gkoi/ci-nginx; do
  gkoi-aws ecr describe-images --region ap-northeast-1 --repository-name "$r" \
    --query 'imageDetails[].[imageDigest,join(`,`,imageTags)]' --output text; done
```

Expect exactly (`releases/mikaido.json` gkoi-2026.11.11-1 + the mirror):
`gkoi/media-agent sha256:0ca2d707ab6dd37ea0b9447322413bfe198d27e523d6a2e810f8f4e0f0313c3a`,
`gkoi/mediamtx sha256:2dfc8522735bfbbe1b3be4eba71074a8e3685a86dfa8ca56e6b80de5bf63afa1`,
`gkoi/ci-nginx sha256:62223d644fa234c3a1cc785ee14242ec47a77364226f1c811d2f669f96dc2ac8 1.27-alpine`.
The media plan resolves ci-nginx by tag in apne1 and STOPS if it is missing; media-agent / mediamtx are pulled by digest
at boot (a missing replica fails the box's `phase pull`, not the plan). The replicas get the creation template of step 3
(immutable, keep 20) only if step 3 is applied BEFORE the backfill.

(Without the backfill API: push a NEW tag of each image in us-west-2 — `batch-get-image` → `put-image` with the same
manifest and a tag such as `<tag>-apne1` — which replicates to every destination; ci-nginx would then need
`media_origin_image_tag` changed for all regions. The backfill is simpler.)

### Step 7 — the origin-verify secret (MCP; the value is generated by Secrets Manager and never printed)

`gkoi/media/{usw2,euc1,use1}/origin-verify` were made by hand in P0: us-west-2, the default `aws/secretsmanager` key,
a plain string, tags `project=gkoi` + `phase`, description "X-Origin-Verify for the <region> media origin …". The origin
entrypoint and edge-alb accept `[A-Za-z0-9_-]{32,128}`; 64 alphanumerics as the others:

```python
pw = await call_boto3(service_name="secretsmanager", operation_name="GetRandomPassword", region_name="us-west-2",
                      params={"PasswordLength": 64, "ExcludePunctuation": True, "IncludeSpace": False, "RequireEachIncludedType": True})
r = await call_boto3(service_name="secretsmanager", operation_name="CreateSecret", region_name="us-west-2", params={
    "Name": "gkoi/media/apne1/origin-verify",
    "Description": "X-Origin-Verify for the ap-northeast-1 media origin (new 2026-11-11)",
    "SecretString": pw["RandomPassword"],
    "Tags": [{"Key": "project", "Value": "gkoi"}, {"Key": "phase", "Value": "P5"}]})
pw = None
result = {"arn": r["ARN"]}
result
```

(CLI, any shell that may: `aws secretsmanager create-secret --region us-west-2 --name gkoi/media/apne1/origin-verify
--description "…" --tags Key=project,Value=gkoi Key=phase,Value=P5 --secret-string "$(aws secretsmanager
get-random-password --region us-west-2 --password-length 64 --exclude-punctuation --no-include-space
--require-each-included-type --query RandomPassword --output text)"`.) Check without printing:
`… get-secret-value … --query SecretString --output text | tr -d '\n' | grep -cE '^[A-Za-z0-9]{64}$'` → `1`.
The box role reads it by ARN (this stack's `data.aws_secretsmanager_secret.origin_verify["apne1"]` — the media plan
STOPS without it); the rehearsal driver gets it as `ORIGIN_VERIFY_APNE1` once the rehearsal stack is re-applied.

### Step 8 — CloudFront `live.gkoi.com` (E18952ZBU48RL9, hand-managed; MCP for the secret read)

Read 2026-11-11: origins `origin-live-usw2` / `-euc1` / `-use1` / `origin-live` (default), each https-only TLSv1.2 with
Origin Shield in its region and a 64-char `X-Origin-Verify`; behaviours `/r/{euc1,usw2,use1}/*` with cache policy
`gkoi-live-hls` (79d102a8…), origin request `gkoi-live-viewer` (a565c3fd…), response `gkoi-live-cors` (8f657904…);
PriceClass_All (Asian edges included). The use1 script (GKOIBuilder_AI `docs/specs/RUNBOOK-AWS-P3-P5-WINDOW.md` §1.7) for
apne1 — `DOM` = `origin-live-apne1-p2.gkoi.com` on Path A, `origin-live-apne1.gkoi.com` on Path B:

```bash
D=E18952ZBU48RL9; DOM=origin-live-apne1.gkoi.com; W=$(mktemp -d); chmod 700 "$W"; cd "$W"
aws cloudfront get-distribution-config --id $D > cf.json; ETAG=$(jq -r .ETag cf.json)
V=$(aws secretsmanager get-secret-value --region us-west-2 --secret-id gkoi/media/apne1/origin-verify --query SecretString --output text)
jq --arg v "$V" --arg dom "$DOM" '.DistributionConfig
  | (.Origins.Items[] | select(.Id=="origin-live-usw2")) as $o
  | .Origins.Items += [ $o | .Id="origin-live-apne1" | .DomainName=$dom
      | .OriginShield={"Enabled":true,"OriginShieldRegion":"ap-northeast-1"}
      | .CustomHeaders.Items=[{"HeaderName":"X-Origin-Verify","HeaderValue":$v}] ]
  | .Origins.Quantity = (.Origins.Items|length)
  | (.CacheBehaviors.Items[] | select(.PathPattern=="/r/usw2/*")) as $b
  | .CacheBehaviors.Items += [ $b | .PathPattern="/r/apn1/*" | .TargetOriginId="origin-live-apne1" ]
  | .CacheBehaviors.Quantity = (.CacheBehaviors.Items|length)' cf.json > new.json
unset V
aws cloudfront update-distribution --id $D --if-match "$ETAG" --distribution-config file://new.json --query Distribution.Status --output text
shred -u cf.json new.json; aws cloudfront wait distribution-deployed --id $D
```

Path A's step 13 (re-point): the same, but `| (.Origins.Items[] | select(.Id=="origin-live-apne1") | .DomainName) = $dom`
instead of the two `+=` blocks (the header stays). Check after the box is up (from anywhere):
`curl -s -o /dev/null -w '%{http_code}\n' https://live.gkoi.com/r/apne1/live/nosuch/hls/index.m3u8` → **404** (origin
reached with the right header, unknown session). 403 = wrong header; 502/504 = DNS / certificate / name mismatch.
(The orchestrator role has `cloudfront:UpdateDistribution` but not `secretsmanager:GetSecretValue`: run it where both are allowed.)

### Step 10 — bring-up and the test

1. The ASG launches; bootstrap ~5–8 min (packages, 4 certs by DNS-01, the cross-region pulls from apne1's ECR, the bundle
   + engine `source.zip` from the us-west-2 bucket — S3 is global, the box has a public IP, no NAT needed). Follow
   `/gkoi/prod2/media/apne1/bootstrap` (ap-northeast-1), or over SSM: `sudo /opt/gkoi-media/media-bootstrap.sh check` → exit 0.
2. The engine: `engine-api` logs show no "dropped registration"; through the app API (a brokered device token)
   `GET https://engine.gkoi.com/api/v1/app/regions` lists `{region: ap-northeast-1, label: Tokyo, probeHost:
   stream-apne1[-p2].gkoi.com, probePort: 11936}`. **From here Tokyo is public.**
3. **The scripted go-live — the rehearsal driver, apne1 only, against the LIVE engine.** It cannot run in rehearsal
   mode (media's `rehearsal = true` is global and refused while any region serves live names; compute's would move the
   live engine onto the scratch bucket). It can run UN-armed for one region:
   - Let the driver reach the origin: in this stack set `origin_ingress_cidrs = ["32.189.104.202/32"]` on apne1 only
     (the home NAT — 443 from it, besides CloudFront) and apply `media` (+1 SG rule).
   - `tools/gkoi-infra-run rehearsal apply --allow-destroy` — the task definition is REPLACED (its `REGIONS` gains
     apne1, the secret `ORIGIN_VERIFY_APNE1`); nothing else should change.
   - `tools/gkoi-rehearsal --only apne1 --force --dry-run` → the RunTask request; add
     `{"name":"SKIP_BUCKET","value":"1"}` to its `containerOverrides[0].environment` (the recording lands in the LIVE
     `gkoi-beta-vods`, not the scratch bucket); run it with an `ecs:RunTask` + `iam:PassRole` credential (MCP) and follow
     the log (rehearsal README step 8). PASS = the session placed in ap-northeast-1 with ingest
     `rtmps://stream-apne1[-p2].gkoi.com:11936`, publishing, LL-HLS through the origin (with and without the header),
     through the engine's watch proxy (Oregon → Tokyo over peering), the recording available, thumbnails, the MP4.
   - It writes to the LIVE engine database: the identity `rehearsal-p2-driver` (JIT account), its brokered devices
     (revoked by the driver), one ended session and its recording in `gkoi-beta-vods`. Delete them after (`DELETE
     /api/v1/vods/:id` as that identity, then the account), and remove `origin_ingress_cidrs` again (apply `media`).
   - Not verified offline: that the un-armed driver still passes the broker routes against the post-window engine
     (it last ran before P3/P4). Alternative: a manual go-live as a real test account with the orchestrator's app-link
     tooling (`mintlink-prod`, GKOIBuilder_AI `scripts/session-tools/`) and a GKOI Live build or ffmpeg to the ingest
     URL the 201 returns, as in the P3 verification; then watch it on the site (`live.gkoi.com/r/apne1/…`).
4. Plus what the driver does not cover: a WHEP preview (ICE udp 8189), a viewer through `live.gkoi.com` (step 8's
   probe with a real session id), the app's own region probe choosing Tokyo from Asia.
5. **Stop line:** any failure → drain at once (hides the region from `/app/regions` within seconds and stops placement):
   over SSM `docker exec <agent> …/drain` POST (README "Bring one region up" step 6), or the engine admin
   `POST /api/v1/admin/media/boxes/<box>/drain {draining:true}`. Undrain after the fix. Full retreat: `enabled = false`
   on apne1 and apply `media` (the rehearsal-name records go; live records on Path B have `prevent_destroy` — the
   Rollback section's `state rm` first).

### Step 13 on Path A — the roll

```bash
aws ssm send-command --region ap-northeast-1 --document-name AWS-RunShellScript \
  --targets Key=tag:aws:autoscaling:groupName,Values=gkoi-prod2-media-apne1 \
  --parameters 'commands=["/opt/gkoi-media/roll.sh --drain-wait 60"]' --timeout-seconds 7200
```

(re-renders `publicHost` = `stream-apne1.gkoi.com`, the pools' cert path, the origin's server name + lineage; the
live-name certs were issued at first boot). Then the CloudFront re-point at once. The orchestrator role may
`ssm:SendCommand`.

### Cost (Tokyo, per month)

Box ~$210 (table above). Elsewhere: flow logs into `/gkoi/prod2/vpc-flow/apne1` (ingestion ~$0.76/GB in Tokyo); the
alarms ~$0.40; ECR replicas ~$0.22 now (+ every future `gkoi/*` image also lands in Tokyo); Origin Shield in
ap-northeast-1 (per-request fee). Traffic (list prices from memory): a recording uploaded Tokyo → the us-west-2 bucket
and the Valkey / internal-ALB calls cross the peering at ~$0.09/GB (APAC inter-region — not the $0.02 of the US/EU
regions): ≈ $0.24 per recorded 6 Mb/s stream-hour; platform relays leave Tokyo at $0.114/GB (first 10 TB; Pricing
API) ≈ $0.31 per platform per stream-hour; EC2 → CloudFront free. **≈ $215/month + traffic**; the four regions ≈
$750/month (the plan budgeted ~$650 for four). Latency: Tokyo → Oregon is ~100 ms per round trip for the publish-auth,
the 5-s heartbeats and the BullMQ calls to Valkey (G4: keep-alive set; G5's regional api would remove it).

## Validate (offline)

`terraform fmt -check`, `validate` (`init -backend=false`) and `terraform test` (tests/plan.tftest.hcl: mock providers,
no AWS call — three regions, the default four, Tokyo's defaults + its live-name switch, an unknown region key, a bad pool
count, the live-records switch, the rehearsal switch; the runs share one state, so their ORDER matters — see the file) in `hashicorp/terraform:1.9`;
`shellcheck -x` over `box/*.sh` (and the rendered user-data) in `koalaman/shellcheck`.

## Cost (on-demand list prices from memory, per month, one box per region)

| Item | usw2 | euc1 | use1 | apne1 |
|---|---|---|---|---|
| m7i.xlarge | ~$147 | ~$168 | ~$147 | **$190** ($0.2604/h, Pricing API 2026-11-11) |
| gp3 100 GiB | ~$8 | ~$9.5 | ~$8 | $9.6 ($0.096/GB-mo, Pricing API) |
| Elastic IP (public IPv4) | ~$3.6 | ~$3.6 | ~$3.6 | ~$3.6 |
| CloudWatch: ~20 agent metrics (ASG + instance aggregations) + 4 alarms + log ingestion | ~$7 + logs | ~$7 + logs | ~$7 + logs | ~$7 + logs (Tokyo ingestion ~$0.76/GB) |
| **Region** | **~$166** | **~$188** | **~$166** | **~$210** |

Once (in edge-alb): the internal ALB ~$16.4 + LCUs (~$5) ≈ **$22**. All three ≈ **$540/month** (+ egress: platform relays
$0.09/GB ≈ $0.24 per platform per stream-hour at 6 Mb/s; a spoke's recording upload to the us-west-2 bucket and its
Valkey/API traffic cross peering at $0.02/GB — ≈ $0.05 per recorded stream-hour; EC2 → CloudFront is free). The plan
budgeted ~$650 for four regions incl. Tokyo. The live Lightsail boxes are 8 vCPU / 32 GB (`2xlarge_3_0`): the 4/16 box
is the plan's size, unproven by a capacity test (plan §5.5) — watch the CPU alarm; `instance_type` per region resizes.

## Assumptions and open questions

1. **Done in this branch** (were open): compute registers engine-api in the internal TG; the engine env is
   registry-only with no static list; data admits the spoke VPCs to Valkey; nginx comes from our ECR. Left: whether
   step 4 replaces the engine-api service (read the plan).
2. **The rollback to Lightsail** needs the Lightsail list back in compute (`engine_env = { RELAY_POOL_INSTANCES = … }`
   + `RELAY_REGISTRY_ONLY` off) only if the ECS engine should drive the Lightsail boxes — it cannot (no route); the
   real rollback is P3's DNS flip back to the Lightsail engine.
3. **No engine code change found necessary.** Checked in the code at the release commit f997524: the agent boots with
   `MEDIA_BOX_INSTANCES` and no static list (`config.ts`), validates its own registration (`registeredInstanceProblem`),
   uses the default AWS credential chain when `S3_ACCESS_KEY/SECRET` are unset (D3), supports `rediss://` + keep-alive
   (G6), and the api's `/internal/**` checks only the relay secret. Not verified by a run: C1-5's "producers accept a
   queue learned from the registry" for a HOME-region box on `relay-box-<id>` (the spec says verified; the dev proof
   used a non-home region) — the rehearsal's go-live in usw2 proves it.
4. **G1 / G2 / G5** are engine/data work (read replicas, regional cache, the regional api) — nothing here needs them;
   G4 measured Frankfurt → Oregon at ~143 ms RTT per call (the publish-auth on every publish, every heartbeat, the
   BullMQ round trips to Valkey); G6's keep-alive (set) removes the extra ~145 ms of a fresh TLS handshake. That
   distance stays for euc1 (and ~65 ms for use1) until G5. **G3** (noeviction) is the data stack's parameter group.
5. **Frankfurt's live bucket:** every box writes `gkoi-beta-vods` (us-west-2), as the Lightsail boxes do (only
   Oregon's env was read — the Frankfurt box's `S3_BUCKET` was not checked; per-region buckets (C6) are not created).
6. **Valkey from the spokes** admits whole VPC CIDRs (10.20/16, 10.30/16): the game boxes there could connect too;
   the TLS auth token still gates every connection. Narrow to the media SG's subnets if wanted.
7. **The runner role** needs `s3:PutObject` on the bundle prefix in `gkoi-build-sources-…`, and the bucket's policy (if
   any) must let the box roles GET `gkoi-infra/media-box/*` + `mikaido/*/source.zip` — neither policy was read.
8. **origin-verify secrets** — values not read (by design). The P5 rotation means CloudFront's headers change in the
   window (step 4). A value outside `[A-Za-z0-9_-]{32,128}` makes the origin container refuse to start.
9. **Certs:** the new box issues `stream.gkoi.com` / `stream-euc1` / `origin-live-*` while the Lightsail boxes still
   renew theirs by DNS-01 on the same `_acme-challenge` names — a renewal colliding in the same minute fails once and
   retries (twice-daily timers). Let's Encrypt's duplicate-cert limit (5/week/name) allows ~2 box replacements a week
   per region; a third needs `acme_staging` or a wait.
10. **CloudFront live** is hand-managed (not in Terraform); its use1 origin/behaviour and the header rotation are
    manual window steps.
11. **No Global Accelerator** (plan §4 latency line) — out of scope here.
12. **Plain RTMP** (11935/21935) is published by compose but closed by the SG, as on the live box; open it per region
    only if an encoder without TLS must ingest.
