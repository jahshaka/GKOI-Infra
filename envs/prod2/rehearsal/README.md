# `envs/prod2/rehearsal` — the PRIVATE go-live rehearsal of prod 2

One command proves, per media region (usw2 / euc1 / use1), the whole streaming path of the GKOI Live app against the
ECS engine and the EC2 media boxes — before any DNS moves and with nothing live touched:

```
engine health ─ the boxes registered ─ a brokered device + token (site link mode)
  └ POST /api/v1/app/sessions {mode: relay, region}       placed in THAT region, ingest = rtmps://stream-<key>-p2.gkoi.com
      └ ~60 s 1080p60 H.264 + AAC at 6 Mb/s over RTMPS    (the box's pool; publish-auth through the internal ALB)
          ├ the engine: publishing + live, its measured kb/s
          ├ LL-HLS through the region's origin           https://origin-live-<key>-p2.gkoi.com/r/<key>/live/<sid>/hls/ + X-Origin-Verify (and 403 without it)
          └ LL-HLS through the engine's watch proxy      the api → the box's private HLS port (cross-region over peering)
      └ end → the recording available (the box uploads) → thumbnails (the box's vod job) → the Download MP4 (the ECS
        worker's vod job) → the objects in the SCRATCH bucket (ListObjectsV2 with the driver's own role)
→ a PASS/FAIL table with timings, exit 0 only when every region passed
```

State: `prod2/rehearsal/terraform.tfstate`. Reads network, edge-alb, data, compute and media state (the last stack:
nothing reads it; destroy it after the window).

## What it is made of

| Piece | Where | What |
|---|---|---|
| The rehearsal switch | `compute` `rehearsal` + `parked_services`, `media` `rehearsal` | the engine and every box record into the scratch bucket and can reach ONLY it; vod.gkoi.com unused; the NAT may reach each origin |
| The scratch bucket | `data` (`rehearsal-bucket.tf`) | `gkoi-prod2-rehearsal-vods-127214190346`: private, SSE-S3, TLS only, objects expire after 3 days, force_destroy |
| The driver task | here | family `gkoi-prod2-rehearsal-driver` (Fargate 2 vCPU / 4 GiB), log group `/gkoi/prod2/ecs/rehearsal-driver` (14 days), roles `/gkoi/gkoi-prod2-{exec,task}-rehearsal-driver`, SSM `/gkoi/prod2/rehearsal/run-config` |
| The driver | `driver/driver.mjs` (Node 22, no dependencies) + `driver/entrypoint.sh` | shipped INSIDE the task definition (gzip + base64 env, sha256-checked at start) — no bundle, no image build |
| The wrapper | `tools/gkoi-rehearsal` | run-task → follow the log → the driver's exit code; `--dry-run` prints the RunTask request |

### Design

- **Inside AWS, so the secrets stay there.** The driver signs `x-mikaido-identity` assertions with
  `gkoi/prod2/engine/GATEWAY_SHARED_SECRET` and sends `X-Origin-Verify` from `gkoi/media/<key>/origin-verify`; both
  reach only the driver container as ECS secrets. Its log redacts every token, the publish key (`?key=`) and the origin
  secrets (the 2026-11-11 dev run's log was grepped for the gateway secret, `key=` and bearer tokens: none; the origin
  secret was not exercised on dev).
- **The app's real path, site link mode.** The engine runs `AUTH_MODE=gateway`; the driver plays the SITE: it creates a
  brokered device for its test user (`POST /api/v1/broker/devices`) and mints the device's 1-hour token
  (`/broker/devices/:id/token`), then calls the APP routes with it exactly as GKOI Live does (`/api/v1/app/regions`,
  `/app/sessions`, `/app/sessions/:id/ingest`, `/end`). Engine code at f997524; no engine change needed.
- **Reaching the engine.** `engine.gkoi.com` still resolves to Lightsail. The driver connects to edge-alb's ALB
  (`ENGINE_CONNECT_HOST` = its DNS name) with TLS SNI + Host `engine.gkoi.com` — the ALB's certificate and host rule,
  then the engine edge. It leaves the VPC by the home NAT (32.189.104.202), which is in the edge allow-list
  (`cms_source_cidrs` → `EDGE_ALLOW_CIDR_2`), so the broker / gateway routes (`/api/`) are open to it — as they will be to
  the CMS on ECS after P4. The internal ALB serves only `/internal/*` + health: not enough for a client.
- **The stream.** ffmpeg encodes ONE 10 s clip at start (testsrc2 1920×1080 @ 60, x264 high 4.2, CBR 6000 kb/s, GOP
  2 s, no B-frames; AAC 128k 48 kHz — ~10 CPU-seconds), then publishes it looped with `-re -stream_loop -1 -c copy`:
  no encoding while live, a steady 6 Mb/s, three regions at once possible (`--parallel`). Alpine's ffmpeg 6.1 (libx264,
  lavfi, rtmps) is installed at task start (`apk`, through the NAT); the image is the official `node:22.11.0-alpine3.20`
  from ECR Public, by digest. The engine's own ffmpeg image has no lavfi/testsrc.
- **What "the recording is in the scratch bucket" means.** The api's recording URL (no CDN in rehearsal mode:
  `https://<bucket>.s3.us-west-2.amazonaws.com/<objectKey>/…`) must name the scratch bucket, and a SigV4
  `ListObjectsV2` of `<objectKey>/` with the driver's task role (s3:ListBucket on the scratch bucket, nothing else) must
  show the playlist, the pieces and the MP4.

### The test user

The driver signs as `cmsUserId = rehearsal-p2-driver` (`canStream: true`; variable `cms_user_id`). The engine
JIT-creates its account row on first sight — in the **rehearsal copy** of the engine database restored into RDS on
2026-11-11, which the window's own restore (`gkoi-db-restore engine … --drop-first`) replaces. Why a new identity and not
a real user from the copy: the CMS's user ids are numeric, so this id can never be a real account's (the variable
refuses an all-digit value); nothing of a real user changes (no device, session or recording appears in anyone's
studio); the engine stores no person data for it (the gateway row is an id + entitlements). The CMS database is not
touched at all (the CMS stays parked). What the driver leaves in the copy: that account, its brokered devices (revoked at
the end of each region), its sessions (ended) and recordings (objects in the scratch bucket, expiring after 3 days).
**If the window ever skips the fresh restore**, delete them first (`DELETE /api/v1/vods/:id` as the identity, then the
account) — otherwise they are dangling rows.

## The procedure, in order

Runner = `tools/gkoi-infra-run <stack> plan|apply` from a clean checkout (apply runs the committed HEAD — the switches are
variable DEFAULTS, flipped by a commit). Read every plan summary before its apply.

**0. Ready:** the media boxes are up and `media-bootstrap.sh check` is clean on each (media README "Bring one region
up", step 1); the engine release in `releases/mikaido.json` is the one to rehearse; the engine database copy is restored.

**1. This branch, switches OFF** (once): 

| Stack | Expect in the plan |
|---|---|
| `data` | **+6**: the scratch bucket + public-access block + ownership + SSE + lifecycle + TLS policy. Nothing else. |
| `compute` | no resource change (the `parked` → `parked_services` refactor keeps every service at 0, the same env) — outputs only |
| `media` | no resource change — outputs only (`boxes[*].region`, `rehearsal`) |

**2. Rehearsal ON** — one commit (e.g. branch `rehearsal/on`), three defaults:

```
envs/prod2/compute/variables.tf   parked_services default = ["cms", "fm-api", "fm-worker", "fm-web"]
                                  rehearsal       default = true
envs/prod2/media/variables.tf     rehearsal       default = true
```

**3. `compute apply --allow-destroy`.** Expect: new task-definition revisions for engine-api, engine-worker and
engine-migrate (`S3_BUCKET` = the scratch bucket, `CDN_DOWNLOAD_BASE` / `CDN_DISTRIBUTION_ID` blank) — a task
definition change is a replace (the runner's ALLOW_DESTROY; the replaced revisions are the only destroys — refuse the
apply if anything else is replaced); the `engine-media` role policies (scratch bucket only, no CloudFront); the
engine-api / engine-worker autoscaling targets 0 → 1 (their tasks start). The plan REFUSES the rehearsal if cms or the
file manager would run, if `engine_env` names a bucket/CDN key, or without the data stack's bucket.

**4. `media apply`.** Expect, per region: the SSM config `/gkoi/prod2/media/<key>/config` (the agent's `S3_BUCKET`),
the box role's recordings policy (scratch only), one new origin SG rule (443 from 32.189.104.202/32). No instance, ASG
or launch-template change. The plan REFUSES it while any region serves or manages a live name.

**5. Roll every box** (the role's rights changed at once; the agent's env changes only on a roll). With a credential
that may `ssm:SendCommand` (not the orchestrator's fallback role):

```
for r in us-west-2:usw2 eu-central-1:euc1 us-east-1:use1; do
  aws ssm send-command --region "${r%%:*}" --document-name AWS-RunShellScript \
    --targets "Key=tag:aws:autoscaling:groupName,Values=gkoi-prod2-media-${r##*:}" \
    --parameters 'commands=["/opt/gkoi-media/roll.sh --drain-wait 5"]' --timeout-seconds 1800
done
```

Each roll drains, recreates what changed (the agent: its env file), undrains, prints `check`. (A box the roll leaves on
the old bucket cannot upload at all — its role no longer reaches gkoi-beta-vods — and the driver's recording step fails
for that region.)

**6. `rehearsal apply`** — the driver task definition, roles, log group, run config. The plan must NOT warn
`check.rehearsal_armed` (it snapshots compute's + media's switches into the run config; apply this stack after 3–4,
never before). The apply log prints `run_task_request` and `run_config`.

**7. Wait for the engine** (the driver also waits up to 10 min for `/api/v1/healthz` through the ALB, then up to 15 min
for all three regions in `/api/v1/app/regions`): `aws ecs describe-services --region us-west-2 --cluster gkoi-prod2
--services engine-api engine-worker` → running 1 each; ALB target group `engine-api` healthy.

**8. Run the driver:**

```
tools/gkoi-rehearsal --dry-run                  # the RunTask request (reads SSM; or --config run_config.json)
tools/gkoi-rehearsal                            # run-task + follow the log + exit code (needs ecs:RunTask + iam:PassRole on the two driver roles)
#   options: --only usw2,euc1   --seconds 120   --parallel   --force (not armed)
```

The orchestrator's fallback role can neither `ecs:RunTask` nor read SSM: save the apply log's `run_config` output as
JSON and print the request with `tools/gkoi-rehearsal --config run_config.json --dry-run`; the RunTask-capable
credential then runs `aws ecs run-task --region us-west-2 --cli-input-json file://run-task.json` and follows
`aws logs tail /gkoi/prod2/ecs/rehearsal-driver --log-stream-name-prefix driver/driver/<task id> --follow`.
A run takes ~4–6 min per region sequentially (60 s live + the recording, thumbnails and the MP4 build), ~6 min with
`--parallel`.

**9. Read the result.** The log ends with the table and one line `REHEARSAL_PASS <n> regions` or
`REHEARSAL_FAIL <keys>`; the container's exit code: 0 pass · 1 a region failed (the reasons under the table) · 2 the
driver's configuration · 3 the engine or a region never came up · 10 the task's setup (apk / the driver unpack).
Columns: `create` (the 201, ms) · `publishing` (publish start → the engine sees the publisher) · `origin` / `watch`
(→ first playable LL-HLS: playlist + init + newest segment) · `kbps` (the engine's measured ingest) · `vod` (end →
available) · `thumbs` · `mp4` (the worker's Download build) · `bucket` (objects under the recording's key). Where to look
on a FAIL: `/gkoi/prod2/ecs/engine-api` (placement, publish-auth, watch proxy), `/gkoi/prod2/ecs/engine-worker` (the
MP4), `/gkoi/prod2/media/<key>/container` (agent, pools, origin), `media-bootstrap.sh check` on the box.

**10. Re-park + rehearsal OFF** — revert the ON commit, then in this order:

1. `compute apply --allow-destroy` — engine-api / engine-worker back to 0, the engine env and role back to
   gkoi-beta-vods + the CloudFront right.
2. `media apply`, then roll every box (step 5's command) — the agents back on gkoi-beta-vods, the origin SG rule gone.
3. `rehearsal apply` — the run config's `armed` back to false (the wrapper then refuses without `--force`; the driver
   would also stop at the regions check once the boxes serve live names).
4. Nothing to clean: the scratch objects expire after 3 days (or `aws s3 rm s3://gkoi-prod2-rehearsal-vods-127214190346
   --recursive`); the database rows go with the window's fresh restore. The bucket can stay (empty = free).

## What the rehearsal does NOT test

- **WebRTC**: the browser go-live (WHIP through the api), the WHEP preview, ICE over UDP 8189/8289 — the driver
  publishes RTMPS only.
- **SRT** (not built) and plain RTMP (closed by the SG).
- **The real GKOI Live app**: its TLS stack and pins, its region probing (`regionProbes`, E9 — the driver sends `region`),
  its site link, its standby → go-live flow (the driver creates live directly), its own encoder / bitrates.
- **The CMS path**: the real site's broker calls and token minting, the CMS proxy, the site-wide events stream the site
  consumes, the site's player and studio — the CMS stays parked; the driver stands in for it.
- **CloudFront**: `live.gkoi.com` in front of the origins (the window's X-Origin-Verify rotation, the use1 origin and
  behaviour) and `vod.gkoi.com` (blank in rehearsal mode) — the driver reaches the origins directly from the NAT.
- **DNS**: no name moves; `stream-<key>-p2` / `origin-live-<key>-p2` are the rehearsal names, `engine.gkoi.com` is reached
  by connecting to the ALB.
- **The file manager** (parked), platform restreams (no destinations: no YouTube / Twitch / Kick legs), chat.
- **The live bucket and its URLs** (rehearsal mode replaces them), the recording-length tiers, the drain / lifecycle
  hook, capacity (one stream per region, three with `--parallel`), 12 Mb/s GKOI bitrates (`VIDEO_KBPS` is a container
  override: `12000`).

## Validate (offline)

`terraform fmt -check`, `validate` (`init -backend=false -lockfile=readonly`) and `terraform test` (tests/plan.tftest.hcl:
mock provider; armed / not armed / no bucket / a numeric test user) in `hashicorp/terraform:1.9`; `shellcheck` over
`driver/entrypoint.sh` and `tools/gkoi-rehearsal`; `node --check driver/driver.mjs`. compute and media have their own
tests for the switch (`envs/prod2/{compute,media}/tests/`).

The driver itself ran against the DEV engine stack on 2026-11-11 (the same entrypoint + gzip/base64 unpack, gateway
mode, the dev pools' RTMPS on `stream-dev-lan.3dzuki.com`, `SKIP_ORIGIN=1 SKIP_BUCKET=1`): PASS — publishing 2.0 s
after the publish started, the watch proxy's LL-HLS 1.7 s later, 6517 kb/s measured, the recording available 3 s after
the end, the MP4 built 5 s later; and a region the engine does not offer fails the run with exit 3. The SigV4 listing
was checked against S3 with the orchestrator's credentials (read-only). Not run anywhere yet: the ALB connect, the
regional origins, the scratch bucket — the AWS run is the first.
