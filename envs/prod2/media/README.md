# `envs/prod2/media` — the GKOI media boxes on EC2 (P5)

PLAN-AWS-MIGRATION-PROD2-V1 §P5. One ASG of ONE EC2 instance per enabled region (`var.media_regions`: usw2 / euc1 /
use1; Tokyo needs a provider + module block first), each running the media agent, N MediaMTX relay pools and the
regional live origin, and **registering its pools with the engine** (SPEC-ENGINE-DYNAMIC-REGIONS-V1 C1:
`MEDIA_BOX_INSTANCES`, no `RELAY_POOL_INSTANCES` entry). Per the 2026-11-11 gap audit (B3-2/B3-3) the media plane moves
**with** the engine: these boxes are brought up and proven privately first, then ONE window flips engine + FM + media.

State: `prod2/media/terraform.tfstate`. Defaults: only `usw2` is enabled.

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
carries each file's sha256); the **internal
ALB** `gkoi-prod2-engine-internal` (+ target group `gkoi-prod2-engine-api-int`, SG, the ECS-tasks SG rule for 3000);
the Valkey SG rule for the usw2 box.

## Design choices

- **Registry mode, no static list.** `MEDIA_BOX_ID = <slug>-<instance id>` (one per INSTANCE: a replacement box never
  inherits a departed box's pool ids — A2/A4 re-claim or end those sessions), pool ids `<box>-p<i>`, its own queue
  `relay-box-<box>`. `MEDIA_BOX_INSTANCES` is rendered on the box from IMDS (private IP = `apiHost`) and the config:
  `publicHost` = the stream host, ports `(i+1)1935/1936/8888/8889/9997` and ICE `8189+100·i` exactly as the live box,
  `liveOriginBase https://live.gkoi.com`, `label` Oregon / Frankfurt / Virginia (us-east-1 has no built-in label).
- **How a box reaches the engine (`PORTAL_INTERNAL_URL`).** The agent calls `/internal/**` (publish-auth on every
  publish, ingest heartbeats, session state/health, vod events). The public path cannot carry it: the engine edge
  (ECS sidecar, same `edge.conf.template`) answers `/internal/` with 404. Service Connect serves ECS clients only;
  Cloud Map DNS would need its private zone associated with every peered VPC and has no health gate. Chosen: an
  **internal ALB** in the home private subnets, listener :3000 forwarding only `/internal/*` + `/api/v1/healthz` to the
  api container's own port 3000 (404 otherwise). Its DNS name is public DNS → private IPs, so every peered VPC uses it
  with no DNS work; peering traffic between regions is encrypted by AWS; the api authenticates these routes with the
  relay secret only (no source-address rule). `HTTP_KEEPALIVE_MS=55000` < the ALB's 60 s idle timeout (G4/G6).
- **Valkey** (`rediss://`, auth token): the agent reads `gkoi/prod2/engine/REDIS_URL` (the engine's own db /0 — the
  registry and the relay queues live there). Node's trust store accepts ElastiCache's certificate (no
  `REDIS_TLS_CA_FILE`). `REDIS_REQUIRE_NOEVICTION` stays unset (CONFIG is refused on ElastiCache; the parameter group
  enforces noeviction — as compute).
- **Images by digest from the box's own region's ECR** (registry replication, checked 2026-11-11: both digests of
  `gkoi-2026.11.11-1` are in euc1 + use1). `media-origin` is stock nginx with the engine's rendered config: default =
  the live box's exact image `nginx:1.27-alpine@sha256:65645c7b…` from Docker Hub (see open questions).
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
  rehearsal + 2 live) are issued at first boot, so the window needs no cert step. Renewal: certbot's snap timer →
  `cert-hook.sh` (origin: `nginx -s reload`; pools: restart only when the box is idle, else an hourly retry — the
  engine's own hook rule). The plan's "wildcard in Secrets Manager" was not needed: per-name DNS-01 works on EC2.
- **The ASG** gives self-healing (a failed box is replaced) and the drain hook; with one EIP per region it is held at
  max 1 and has no instance refresh (a new box would take the address from the live one).
- **`roll.sh`** rolls a release IN PLACE over SSM (drain → wait idle → recreate → undrain); a release never replaces
  the instance.

## Apply order (cross-stack)

1. `network`, `data`, `registry`, `observability` (exist). `compute` exists (parked).
2. **The secrets this stack reads** (all eight exist WITH a value — DescribeSecret, 2026-11-11; values not read):
   `gkoi/prod2/engine/{REDIS_URL,RELAY_SHARED_SECRET,MK_POOL_API_PASS,MK_POOL_READ_SECRET,PREVIEW_TOKEN_KEY}` and
   `gkoi/media/<key>/origin-verify` (made in P0, "rotated at P5": its value must be 32–128 of `[A-Za-z0-9_-]` — the
   origin entrypoint refuses anything else; plain string, or set `origin_verify_secret_json_key`).
3. **`media`** (this stack). Creates the box(es); the internal ALB's target group is empty until step 4.
4. **`compute` — a change this stack cannot make** (`modules/ecs-service` takes ONE load balancer): register the
   engine-api service's `api` container port 3000 in this stack's output `engine_internal_target_group_arn` as a second
   load balancer. Until then every agent call answers 503 and no publish is admitted.
5. **`data`** — for each spoke region enabled here: `valkey_peer_cidrs = <this stack's output valkey_peer_cidrs>`
   (cross-region peering cannot reference an SG; the usw2 box gets an SG-referenced rule from this stack).
6. **For the rehearsal and the window, compute's engine env:** `RELAY_REGISTRY_ONLY=1` and `RELAY_POOL_INSTANCES=""`
   on the api (the worker defaults to an empty list). **Never leave the Lightsail static list in it**: a static entry
   never leaves the registry, so placement would keep choosing the unroutable Lightsail pools (172.26.x / 10.88.x).

Each through the runner as usual (`TF_STACK=media TF_ACTION=plan`, read the summary, then `apply`). The runner role
also needs `s3:PutObject` on `gkoi-build-sources-…/gkoi-infra/media-box/*` (the bundle) — see open questions.

## Bring one region up privately and prove it against the ECS engine

1. `media_regions.<key>.enabled = true` (usw2 first), apply. The ASG launches; the box bootstraps itself (~5–8 min:
   packages, certs, pulls). Follow it in CloudWatch `/gkoi/prod2/media/<key>/bootstrap`, or over SSM:
   `aws ssm start-session --target <instance>` → `sudo /opt/gkoi-media/media-bootstrap.sh check` (exit 0 = EIP on the
   box, 4 certs, env files, every container healthy, lifecycle watcher up; it prints the agent's `/drain` report).
2. **Registration:** the agent log shows its box id + pools; `redis-cli` (from an ECS Exec shell in engine-api) →
   `SMEMBERS relay:registry:pools`, `GET relay:registry:pool:<box>-p0` (TTL 30 s, re-written every 10 s). With the
   engine unparked (rehearsal: api + worker, `RELAY_REGISTRY_ONLY=1`, step 4 done):
   `GET https://engine.gkoi.com/api/v1/app/regions` through the ALB (`curl --connect-to engine.gkoi.com:443:<alb dns>:443`)
   lists the region with its label and probe host `stream-<key>-p2.gkoi.com`; the engine logs no "dropped registration".
3. **Go-live test:** a test user's relay session on the rehearsal DB (a copy of prod) placed in this region → the
   ingest URL names `rtmps://stream-<key>-p2.gkoi.com:11936/…`; publish to it (the app, or ffmpeg with the session's
   key); the agent's publish hook asks `/internal/relay/publish-auth` through the internal ALB → admitted; the session
   goes live; the api's watch proxy reads HLS from `<private ip>:18888` (proves the private SG path).
4. **Recording:** stop the session; the agent uploads the pieces + playlist to the recordings bucket and posts the
   vod event; the worker finalises it (check the vod row + the objects under its key). NOTE the bucket is the LIVE
   `gkoi-beta-vods` (as the parked compute shares it — audit B3-7): a rehearsal recording is a few new objects there,
   referenced only by the rehearsal DB. Delete them after, or point `recordings_bucket` (+ compute's) at a scratch
   bucket for the rehearsal.
5. **HLS via the origin:** `curl -H "X-Origin-Verify: <the region's secret>" https://origin-live-<key>-p2.gkoi.com/r/<key>/live/<sid>/hls/index.m3u8`
   from a CIDR in `origin_ingress_cidrs` (the SG admits only CloudFront otherwise) → 200 while live; without the header
   → 403; an unknown session → 404. (A request through CloudFront needs the window's origin change.)
6. **Drain / lifecycle:** over SSM `docker exec <agent> node -e …/drain` POST → the engine stops placing there; DELETE
   clears it. Optionally set the ASG desired to 0 once: the watcher drains, completes the hook; the registry entry
   expires within 30 s.
7. Re-park the engine services. Repeat for euc1 (enable, apply, `data` valkey_peer_cidrs) and use1.

## The window (engine + FM + media, nobody live)

Before: lower nothing (the four live records are TTL 300 already — wait ≥ 5 min after each flip); have the Lightsail IPs
for the rollback (stream.gkoi.com + origin-live-usw2 → `34.212.239.200`, stream-euc1 + origin-live-euc1 → `63.179.228.39`).

1. P3's own steps (dump/restore, compute unparked with `RELAY_REGISTRY_ONLY=1` + an empty `RELAY_POOL_INSTANCES`,
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

## Validate (offline)

`terraform fmt -check`, `validate` (`init -backend=false`) and `terraform test` (tests/plan.tftest.hcl: mock providers,
no AWS call — three regions, the default, a bad pool count, the live-records switch) in `hashicorp/terraform:1.9`;
`shellcheck -x` over `box/*.sh` (and the rendered user-data) in `koalaman/shellcheck`.

## Cost (on-demand list prices from memory, per month, one box per region)

| Item | usw2 | euc1 | use1 |
|---|---|---|---|
| m7i.xlarge | ~$147 | ~$168 | ~$147 |
| gp3 100 GiB | ~$8 | ~$9.5 | ~$8 |
| Elastic IP (public IPv4) | ~$3.6 | ~$3.6 | ~$3.6 |
| CloudWatch: ~20 agent metrics (ASG + instance aggregations) + 4 alarms + log ingestion | ~$7 + logs | ~$7 + logs | ~$7 + logs |
| **Region** | **~$166** | **~$188** | **~$166** |

Once: the internal ALB ~$16.4 + LCUs (~$5) ≈ **$22**. All three ≈ **$540/month** (+ egress: platform relays
$0.09/GB ≈ $0.24 per platform per stream-hour at 6 Mb/s; a spoke's recording upload to the us-west-2 bucket and its
Valkey/API traffic cross peering at $0.02/GB — ≈ $0.05 per recorded stream-hour; EC2 → CloudFront is free). The plan
budgeted ~$650 for four regions incl. Tokyo. The live Lightsail boxes are 8 vCPU / 32 GB (`2xlarge_3_0`): the 4/16 box
is the plan's size, unproven by a capacity test (plan §5.5) — watch the CPU alarm; `instance_type` per region resizes.

## Assumptions and open questions

1. **Compute must register the api in the internal target group** (step 4) — `modules/ecs-service` takes one load
   balancer; make it a list. Without it the boxes run but admit no publish.
2. **The window's engine env** — `RELAY_REGISTRY_ONLY=1` + an empty `RELAY_POOL_INSTANCES` in compute (step 6). Today
   compute's `env-defaults.tf` carries the Lightsail list.
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
6. **Docker Hub for media-origin:** nginx is pulled anonymously from Docker Hub (rate limits; an outage blocks a new
   box). Mirror it into `gkoi/media-origin` (exists in us-west-2 only — create it replicated) and set `media_origin_image`.
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
