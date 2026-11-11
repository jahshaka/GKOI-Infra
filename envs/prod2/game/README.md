# `envs/prod2/game` — the War Room GAME servers on EC2 ASGs (P6)

PLAN-AWS-MIGRATION-PROD2-V1 §P6 (+ R2). One ASG of ONE EC2 instance per enabled region (`var.game_regions`: usw2 /
euc1 / use1 on, apne1 defined and OFF — `modules/regions` enables apne1 since 2026-11-11 for a Tokyo MEDIA box only), each running the War Room game
stack (matchd + wasm-gateway + one UnrealServer per match) through the War Room's OWN hosting tool `ops/warroom-game`
(GKOIBuilder_AI). The two live game boxes (usw2 `i-08b3f695d885fe5bb`, euc1 `i-0d024ca1ecbc63523`, default VPC, hand-made
on 2026-11-07) are NOT touched by this stack: the new boxes come up beside them on rehearsal names, then take the live
names one region at a time.

State: `prod2/game/terraform.tfstate`.

## What an apply creates

Per enabled region (`modules/game-box`, in that region's VPC, public subnets):

| Resource | Detail |
|---|---|
| ASG `gkoi-prod2-game-<key>` | min / desired / max 1 (validation: max ≤ 1 — one EIP per region, and no matchd launcher across boxes until the War Room's C15); EC2 health; group metrics; terminate lifecycle hook `drain` (heartbeat 900 s, default CONTINUE); **no instance refresh** |
| Launch template | Canonical Ubuntu 24.04 amd64 gp3 (SSM public parameter — the live boxes run `ubuntu-noble-24.04-amd64-server-20261023`), **`t3a.xlarge`, credits `standard`** (= the live boxes, read 2026-11-11), gp3 40 GiB encrypted (= live), IMDSv2 only, hop limit 2 (= live), public IP at launch, user-data = only the config parameter's name |
| Elastic IP | stable address for DNS; the box associates it to itself at boot (`phase eip`) |
| SG `gkoi-prod2-game-<key>` | **exactly the live SG's IPv4 rules**: tcp 9443 (matchd), tcp 8443 (gateway WSS), udp 8443 (gateway WebTransport), from 0.0.0.0/0; egress all. Not open: 22, 80, the loopback monitors 9544/9545, the UE ports. The live SGs also carry `::/0` copies — dropped: the prod2 VPCs have no IPv6 |
| IAM role + profile `/gkoi/gkoi-prod2-game-<key>` | SSM core + CloudWatch agent (managed); ECR pull of `gkoi/warroom-game` in its region; `GetSecretValue` on the match-server key (+ the region's ticket key if named); its own SSM parameter; S3 GET on the box bundle + `warroom-game/*/source.zip` + `warroom-game/tool/*`; `AssociateAddress` on its own EIP (tag-conditioned); its own ASG's lifecycle calls; Route 53 TXT `_acme-challenge.<its 4 names>` only. (The live boxes use the hand-made `gkoi-game-instance` profile, not under `/gkoi/`; its policies were not readable with the orchestrator role — SPEC-AWS-GAME-SERVERS-EC2 §1 lists them: the same three parts) |
| SSM `/gkoi/prod2/game/<key>/config` | the box's whole configuration (no secret values: secrets are named by ARN) |
| Log group `/gkoi/prod2/game/<key>/metrics` | the CloudWatch agent's Prometheus EMF records (3 days); the `container` / `syslog` / `bootstrap` groups are observability's |
| Route 53 | A records (TTL 60) → the EIP for the **rehearsal** names `game-<key>-p2` + `gw-<key>-p2.gkoi.com`; the **live** names `game-<key>` + `gw-<key>.gkoi.com` (TTL 300, as today) only with `manage_live_records` (allow_overwrite + `prevent_destroy`) |
| Alarms → the region's `gkoi-ops-alerts` | in-service < min (10 min), status check (5 min), CPU > 70 % (15 min), **CPU credit balance < 100** (T types), disk > 80 %, **matchd silent** (no `/metrics` sample for 15 min), **steal > 10 %** (matchd's 5-min window, 15 min) |

Once (us-west-2): the secret `gkoi/prod2/game/match-server-key` (EMPTY: no value in Terraform) and the box bundle in
`s3://gkoi-build-sources-…/gkoi-infra/game-box/` (stable keys; the config carries each file's sha256).

## Design choices

- **One source of truth for the box: the War Room tool itself.** The box runs `ops/warroom-game` unpacked from the
  SAME `warroom-game/<tag>/source.zip` that `gkoi-release warroom-game <tag>` uploaded and CodeBuild built the image from
  (sha256 + the commit in the zip comment checked, from `releases/warroom-game.json`). Its `bootstrap.sh` does packages,
  Docker, SSM, sysctl (rmem/wmem_max 4194304), ufw, the DNS-01 cert + deploy hook; its `warroom-game.sh` does deploy /
  drain / up / rollback with all its checks; its `drain-hook.sh` is the ASG hook's body. `box/game-bootstrap.sh` (this
  stack) only adds what an ASG box needs around it: the config from SSM, the env overlay (the names), the EIP, `/etc/hosts`,
  ECR instead of `docker load`, the secrets from Secrets Manager, our CloudWatch config, the IMDS guard, the lifecycle
  watcher. Forking the tool into this repo was rejected: two copies of the floor/config/secret checks would drift, and
  CodeBuild already reads the tool from GKOIBuilder_AI. The cost of the coupling: a tool/config-only change between War
  Room releases needs `warroom_tool_override` (below) — the tool and the image otherwise move together.
- **The names are an overlay, not new tool files.** `ops.box.env` = the tool's `ops.beta-<key>.env` with
  `WARROOM_{MATCHD,GATEWAY}_PUBLIC_URL` set to the served names (+ the prod2 CloudWatch prefix); `matchd.json` = the tool's
  `config/matchd.beta-<key>.json` with `gateway.public_url` / `admission_url` set the same way and the box's current
  version fields kept (the tool's `deploy` rewrites them from the image labels). `WARROOM_ENV` stays `beta-<key>`
  (container `warroom-game-beta-<key>`, ticket kid `beta-<key>-1`). Proven offline (Ubuntu 24.04 container, the real
  tool files at GKOIBuilder_AI 7c5b637): render, an idempotent second render, a rehearsal → live switch (version fields kept).
- **`/etc/hosts` pins the served names to the box's own EIP**, so the tool's post-`up` checks (`/v1/version`,
  `/v1/admission` by the public URL — the live boxes reach their own EIP, measured) and matchd's admission call test THIS
  box even while public DNS still points the live names at the old instance.
- **Certs:** Let's Encrypt by DNS-01 with the instance role, through the tool's `bootstrap.sh certs` (one lineage named
  after the matchd host, both names). The IAM condition covers both name sets, but the box holds ONE lineage at a time:
  the tool's certbot deploy hook copies WHATEVER lineage renews into the secrets dir, so a second (stale) lineage would one
  day swap the served cert out. `phase certtidy` deletes every other lineage after a switch. (The media boxes issue all
  names at boot; the game tool's hook makes that unsafe here — see "Noticed" in the P6 report: the hook should check
  `RENEWED_LINEAGE`.) A switch therefore issues one new cert (~1 min; Let's Encrypt allows 5 per week per name set).
- **Secrets:** `match-server-key.txt` from `gkoi/prod2/game/match-server-key` (one secret for every region: the key is
  not region-bound in the CMS — `plays` carry the match server's body `region`). `ticket.p8` is generated ONCE on the box
  (Ed25519, PKCS#8 **v2** DER, 83 bytes — matchd refuses v1; construction proven offline with OpenSSL 3.5): matchd signs
  and the gateway verifies with the same file on the same box, nothing else holds it, so a replacement box simply makes
  its own. `ticket_key_secret` per region pins one in Secrets Manager instead (base64 of the DER) if ever wanted. A box
  whose secret has no value yet does everything else, then `gkoi-game-start.timer` retries `secrets,image,stack` every
  5 min until the stack is up.
- **The IMDS guard:** the game container uses host networking, so the IMDS hop limit does not keep it from the instance
  role. `phase imdsguard` REJECTs uid 10001 (the runtime user) → 169.254.169.254 (a boot unit). The live boxes lack this.
- **CloudWatch:** our config replaces the tool's (`fetch-config` = one config): cpu incl. `usage_steal`, mem, swap,
  disk, net; **procstat** for `UnrealServer`, `matchd`, `wasm-gateway` (cpu, rss, pid count); **matchd `/metrics`
  scraped** (Prometheus → EMF, label `region_key`): `matchd_box_steal_percent{window}`, `matchd_box_cpu_busy_percent{window}`
  (dims region_key + window), `matchd_server_cpu_percent` / `matchd_server_rss_bytes` (dims region_key + kind + server);
  logs: the container json logs, syslog, both bootstrap logs, certbot → `/gkoi/prod2/game/<key>/…`. Never the match
  folders (join keys). The tool's own `bootstrap.sh check` therefore shows ONE expected FAIL (its CloudWatch line);
  `game-bootstrap.sh check` runs it and ignores that line only.
- **Instance type / credits:** the live boxes' `t3a.xlarge` + `standard` (R2: the owner skipped type and credit changes;
  the War Room asked about `unlimited` and `m6a.xlarge`). Both are per-region knobs (`instance_type`, `cpu_credits`); the
  new credit-balance and steal alarms are the evidence for that decision. `unlimited` changes the launch template only:
  the running box keeps its mode until replaced (or `modify-instance-credit-specification` by hand).
- **The switch is DNS, not an EIP move.** Each new box has its own EIP; the live names move with `manage_live_records`.
  The old instance keeps its EIP and is STOPPED (not terminated): rollback = the records back + start it.

## Before the first apply (by hand, once)

1. **The War Room image in ECR.** `gkoi/warroom-game` exists in us-west-2 and is EMPTY (2026-11-11); no
   `warroom-game/` prefix in the sources bucket — 1.0.15.3.3-h6 reached the live boxes by `docker save` + S3. Its inputs
   are on the dev box and match the committed pin (checked 2026-11-11: all 6 files + sidecars OK;
   `pins/1.0.15.3.3-h6.sha256` is on GKOIBuilder_AI origin/main, as are `ops.beta-use1.env` + `matchd.beta-use1.json`):
   ```
   tools/gkoi-release warroom-game 1.0.15.3.3-h6 --dry-run      # GKOIBuilder_AI main → ops/warroom-game zip, inputs.tar, sha256s
   tools/gkoi-release warroom-game 1.0.15.3.3-h6                # upload, CodeBuild gate + build + push → releases/warroom-game.json
   git add envs/prod2/releases/warroom-game.json && git commit   # the stack reads it
   for r in eu-central-1 us-east-1; do gkoi-aws ecr describe-images --region $r --repository-name gkoi/warroom-game \
     --image-ids imageTag=1.0.15.3.3-h6 --query 'imageDetails[0].imageDigest' --output text; done   # the replicas
   ```
   The release's tool zip is ops/warroom-game at that GKOIBuilder_AI commit (`--ref`, default main): it must contain
   `ops.beta-<key>.env` + `config/matchd.beta-<key>.json` for every enabled region (main does for usw2/euc1/use1/apne1).
2. Nothing else: network, observability (the `/gkoi/prod2/game/<key>/{container,syslog,bootstrap}` groups, the alert
   topics) and registry (the repo, replication to euc1 + use1) are applied.

## Apply order

```
tools/gkoi-infra-run game plan        # read the summary: per region ~24 creates (ASG, LT, EIP, SG + 4 rules, role + 2 attachments + policy, profile, SSM, log group, 2 A records, 7 alarms), + the secret + 6 bundle objects + preflight
tools/gkoi-infra-run game apply
```

The plan STOPS (precondition) without `releases/warroom-game.json`, and on a missing ECR replica (the `aws_ecr_image`
lookup per region). The runner role needs `s3:PutObject` on `gkoi-build-sources-…/gkoi-infra/game-box/*` (media needed
the same for its prefix) and `secretsmanager:CreateSecret` on `gkoi/prod2/game/*` — neither was verified.

Then **the secret** (the boxes are up and waiting for it — `gkoi-game-start.timer`):

```
# RECOMMENDED: mint a NEW match-server key on www.gkoi.com (Games admin → keys: invites:read + plays:write, label
# "prod2 game boxes") — revocable apart from the live boxes' key. Or copy the live one: its value is in
# /var/lib/warroom-game/secrets/match-server-key.txt on either live box (read it over SSM as root — the orchestrator's
# role cannot run SSM commands; the operator can). Never print it.
printf '%s' "<the gk_… key>" > key.txt            # no trailing newline (the box refuses whitespace)
gkoi-aws secretsmanager put-secret-value --region us-west-2 --secret-id gkoi/prod2/game/match-server-key --secret-string file://key.txt
shred -u key.txt
```

Within 5 minutes each box starts its stack (`deploy 1.0.15.3.3-h6`).

## Bring up use1 first (new region, no users) and prove it

1. Watch the bootstrap: CloudWatch `/gkoi/prod2/game/use1/bootstrap` (streams `<instance>`, `<instance>-warroom`,
   `<instance>-certbot`), ~6–10 min: packages, Docker, the cert, the image pull (~1.3 GB from the us-east-1 replica).
2. From anywhere:
   ```
   curl -s https://game-use1-p2.gkoi.com:9443/v1/version      # {"checksum":367651359,"matchd":"0.5.7","net":44,"version":"1.0.15.3.3"}
   curl -s https://gw-use1-p2.gkoi.com:8443/v1/admission       # 200
   curl -s -o /dev/null -w '%{http_code}\n' https://gw-use1-p2.gkoi.com:8443/v1/session/m00   # 403 (no ticket)
   curl --http3-only -sI https://gw-use1-p2.gkoi.com:8443/v1/admission   # UDP 8443 / QUIC, if the local curl has HTTP/3
   ```
3. On the box (operator, SSM): `sudo /opt/gkoi-game/game-bootstrap.sh check` → exit 0 (tool @ commit, env, EIP, hosts, the
   tool's own check, one lineage, CloudWatch, IMDS guard, secrets, the tag running, `/v1/version`, the lifecycle watcher);
   `sudo -u ubuntu /opt/warroom-game/warroom-game.sh --env /opt/warroom-game/ops.box.env status`.
4. CloudWatch: `GKOI/Game` `matchd_box_steal_percent` {region_key=use1, window=5m} has samples (the matchd-silent alarm
   goes OK).
5. **A real match.** The site decides a player's region from the viewer's COUNTRY (the CloudFront header; the token's
   `region` claim; matchd answers `wrong_region` to anyone else) — players do not pick it. So a match on use1 needs the
   region on the site's setting (next section) — or the War Room's headless load-test clients with tokens carrying
   `region: use1` (ask the War Room agent: do they have such a harness against a public box, and how do they mint the
   tokens?). The smallest real exposure: enable use1 with `"countryMap": {"US": "usw2"}` first (the built-in table sends
   ALL the Americas to use1 once it is enabled): only Canada / Latin America land there; then the 10-match load test;
   then drop the US override (or keep it — the operator's call, below).

### Registering a region on the site (CMS games plugin, prod www.gkoi.com, admin → Labs tab)

No code change: `use1` is already a valid code (`GAME_REGION_CODES`), named "US East"; matchd's `matchd.beta-use1.json`
already says `region` / `default_region` `use1`; the match-server key is not region-bound. Steps:
1. The box runs the CURRENT release (publishing a War Room release checks `/v1/version` on EVERY enabled region's
   matchd: an enabled region on another version blocks the publish).
2. Edit `labs.game_regions` (JSON). Today's value is not in this repo — read it in the admin first; add `use1` to
   `enabled` and its hosts (the stack prints them: output `boxes.use1.cms_hosts`), keep `default` as it is (euc1:
   defaults are Europe):
   ```
   "enabled": ["euc1", "usw2", "use1"],
   "hosts": { …, "use1": {"matchd": "https://game-use1-p2.gkoi.com:9443", "gateway": "https://gw-use1-p2.gkoi.com:8443"} },
   "countryMap": {"US": "usw2"}          ← optional staging override (see above)
   ```
   use1 has no live names yet, so it can stay on its `-p2` names, or switch to `game-use1` / `gw-use1.gkoi.com` with
   `serve_live_names = true` + `manage_live_records = true` (new names: nothing to take over) + `roll.sh`, then the hosts
   entry changes to those names.
3. New tokens (10-min TTL) carry the new region; a player's existing presence/hint ages out on the next mint.
4. **Decision for the operator:** with use1 enabled, the built-in table sends every US player (one country) to use1,
   West Coast included; usw2 then serves East/South-East Asia + Oceania (until apne1). `countryMap {"US": "usw2"}` keeps
   all of the US on Oregon instead. Per-state routing does not exist (country only).

## Replace usw2 and euc1, one at a time (old box → ASG box)

Per region, in a quiet hour (players are only ever in-region; the other region is unaffected):

1. **Up + verify on the rehearsal name** — the initial apply already did it: steps 1–4 above with `game-<key>-p2`.
2. **Serve the live names on the NEW box** (records untouched; the old box keeps serving players):
   set `game_regions.<key>.serve_live_names = true` (variables.tf default or the map), commit, `gkoi-infra-run game apply`,
   then on the new box (operator, SSM):
   ```
   aws ssm send-command --region <r> --document-name AWS-RunShellScript \
     --targets Key=tag:aws:autoscaling:groupName,Values=gkoi-prod2-game-<key> \
     --parameters 'commands=["/opt/gkoi-game/roll.sh"]' --timeout-seconds 9000
   ```
   (`roll.sh --dry-run` first shows the env/matchd.json diff.) The roll drains the new box's stack (idle), issues the live
   cert `game-<key>.gkoi.com` (+ gw), deletes the `-p2` lineage, writes the live names, ups, and checks itself through
   `/etc/hosts`. The `-p2` A records stay (harmless; the box no longer has a cert for them).
3. **Switch DNS:** `manage_live_records = true`, commit, apply → `game-<key>` + `gw-<key>.gkoi.com` → the new EIP
   (allow_overwrite takes over the hand-made records; TTL 300).
4. **Verify from outside** (after ≥ 5 min): `dig +short game-<key>.gkoi.com` = the new EIP; `/v1/version`; a real match in
   that region (the War Room / the operator).
5. **Retire the old instance — STOP, never terminate** (operator, after its last match: `warroom-game.sh … status` shows
   `matchesLive 0`, ≥ 10 min after step 3 so cached DNS has expired):
   `sudo -u ubuntu -H /opt/warroom-game/warroom-game.sh --env /opt/warroom-game/ops.beta-<key>.env drain`, then
   `aws ec2 stop-instances --region <r> --instance-ids <i-08b3f695d885fe5bb | i-0d024ca1ecbc63523>`. Its EIP stays
   associated while stopped (54.213.198.54 / 63.184.213.26; ~$3.6/month each) — the rollback address. P7 releases it.
6. Next region.

**Rollback** (either region, any time after step 3): (1) UPSERT `game-<key>` + `gw-<key>.gkoi.com` A 300 → the old EIP
by hand (Route 53 console/CLI); (2) start the old instance and its stack — the drain in step 5 removed the container, so
`sudo -u ubuntu -H /opt/warroom-game/warroom-game.sh --env /opt/warroom-game/ops.beta-<key>.env up` (its state file's
current tag), then `/v1/version`; (3) `terraform state rm 'module.box_<key>[0].aws_route53_record.live["game-<key>.gkoi.com"]'` and the
`gw-` one; (4) `manage_live_records = false`, `serve_live_names = false`, apply, `roll.sh` on the new box (back to `-p2`).
Skipping (3) makes the plan STOP (`prevent_destroy`) instead of deleting a live name — on purpose.

**Alternative switch without DNS (instant, rollback = one setting):** point the region's `labs.game_regions` hosts entry at
`game-<key>-p2` / `gw-<key>-p2.gkoi.com` (the game reads the hosts from `/api/v1/labs/regions`; new mints use them at once).
The live names then stay on the old box until it is stopped; switch the names later or never.

## Releases (in place, no new instance)

`gkoi-release warroom-game <tag>` → commit `releases/warroom-game.json` → `gkoi-infra-run game apply` (rewrites each
`/gkoi/prod2/game/<key>/config`: tag, digest, tool zip) → `roll.sh` on each box (SSM, above). The roll pulls the new image
from the region's replica and runs the tool's `deploy <tag>` (drain: live matches finish, up to `WARROOM_DRAIN_TIMEOUT`
7500 s — keep the SSM timeout above it). Roll EVERY enabled region before publishing the release on the Games tab (the
publish checks each region's `/v1/version`). Rollback: the tool's own `rollback` (the previous image stays on the box), or
revert the json + apply + roll. A change to `box/*` reaches a running box the same way (every file sha256-checked).

**A tool/config-only change** (a new `ops/warroom-game` commit, no new image): zip it exactly as gkoi-release does and
name it in `warroom_tool_override`:
```
git -C ~/Development/mikaido archive --format=zip -o /tmp/wr-tool.zip <commit> ops/warroom-game
sha256sum /tmp/wr-tool.zip
cd /tmp && gkoi-aws s3 cp wr-tool.zip s3://gkoi-build-sources-127214190346/warroom-game/tool/<commit>.zip   # gkoi-aws sees only $PWD
# variables.tf: warroom_tool_override = { s3_key = "warroom-game/tool/<commit>.zip", sha256 = "<hex>", commit = "<40 hex>" }
```
The two OLD boxes keep using `ops/warroom-game/roll.sh` (presigned `docker save` + tool tarball) until they are stopped.

## Replacing the box (AMI, type, disk) / more than one box per region

- **Replacing:** the launch template changes on apply; the running box is untouched. In a quiet hour: `set-desired-capacity
  0` (the hook drains: live matches finish, max `drain_max_minutes`; the not-in-service alarm fires meanwhile) then back to 1 — the new box takes the EIP once the old
  one has terminated (`phase eip` refuses while another instance holds it; `GKOI_GAME_TAKE_EIP=1` forces). The new box
  issues a fresh cert for the served names and generates its own ticket key.
- **More than one:** blocked on the War Room's matchd launcher across boxes (plan C15) and one EIP per box; the
  validation `max ≤ 1` stays until then.

## Tokyo (apne1)

Defined, disabled. Since 2026-11-11 the catalogue, network (VPC + peering), registry (replication to ap-northeast-1)
and observability (the `/gkoi/prod2/game/apne1/*` log groups, the topic) are ON for the Tokyo media box
(`envs/prod2/media/README.md` "Adding Tokyo (apne1)"). What is left for a game box: the vCPU headroom (Running
On-Demand Standard = 640 vCPUs in ap-northeast-1, read 2026-11-11; the media box uses 4), a `gkoi/warroom-game` replica
there (replication now covers ap-northeast-1; an image pushed before that needs `aws ecr start-replication-backfill`),
then `game_regions.apne1.enabled = true` and apply. The tool already has `ops.beta-apne1.env` + `config/matchd.beta-apne1.json`.

## The 10-match load test (spec §4.1 / SPEC-AWS-GAME-SERVERS-EC2 §6)

Per region before players: the War Room's headless clients, 10 concurrent matches (+ the room + the spare), at least an
hour (a `standard` t3a spends credits above its 40 % baseline: watch `CPUCreditBalance`, the steal alarm, `matchd_box_cpu_busy_percent`,
per-server CPU/RSS in `GKOI/Game`). Expected from the 2026-11-07 measurements: ~1.0 GiB per match, ~1 core in total. If
credits drain or steal climbs: `cpu_credits = "unlimited"` (surplus ≤ ~$0.05 per vCPU-hour) or `instance_type =
"m6a.xlarge"` / `"m7a.xlarge"` (non-burstable), then replace the box.

## Validate (offline)

`terraform fmt -check`, `validate` (`init -backend=false -lockfile=readonly`) and `terraform test` (tests/plan.tftest.hcl:
mock providers, a fixture release record — 9 runs) in `hashicorp/terraform:1.9`; `shellcheck -x` over `box/*.sh` and the
rendered user-data in `koalaman/shellcheck`.

## Cost (on-demand list prices from memory, per month — verify with the pricing data)

| Item | usw2 | euc1 | use1 | (apne1) |
|---|---|---|---|---|
| t3a.xlarge, standard credits | ~$110 | ~$126 | ~$110 | ~$143 |
| gp3 40 GiB | ~$3.2 | ~$3.8 | ~$3.2 | ~$3.8 |
| Elastic IP (public IPv4) | ~$3.6 | ~$3.6 | ~$3.6 | ~$3.6 |
| CloudWatch: ~40 agent metrics (instance + ASG aggregation, procstat) + matchd gauges (4 box + up to ~2 × 13 per-server while live) + 7 alarms + logs | ~$15–25 | ~$15–25 | ~$15–25 | |
| **Region** | **~$135–145** | **~$150–160** | **~$135–145** | |

The match-server secret $0.40. Three regions ≈ **$420–450/month** (today's two hand-made boxes ≈ $245). During a
replacement both boxes run (≈ a few dollars a day); a STOPPED old instance costs only its 40 GiB volume + EIP (~$7). The
per-server CloudWatch series are the biggest knob: drop the second `metric_declaration` (per-server) in
`box/cloudwatch-agent.json.tmpl` to save ~$5–8 per region. `unlimited` credits: at most ~$87/month extra per box if pinned
at 100 % (4 vCPUs − the 1.6 baseline × $0.05/h).

## Open questions

1. **The CMS region policy** (above): US → use1 (the built-in table) or keep US on usw2 (`countryMap`)?
2. **Testing a real match on a box before players are routed to it:** the site only hints by country; is there a War
   Room headless harness that can mint `region: use1` tokens against the prod site? (Question for the War Room agent.)
3. **The certbot deploy hook** of `ops/warroom-game` copies any renewed lineage; `certtidy` keeps one lineage here, but the
   hook should ignore lineages other than the env's cert name (a change in GKOIBuilder_AI, not made here).
4. **The live boxes' IMDS exposure** (host networking, no guard) — same fix available for them by hand.
5. **Runner rights** (`s3:PutObject` on the bundle prefix, `secretsmanager:CreateSecret` on `gkoi/prod2/game/*`) and the
   orchestrator's `s3:PutObject` on `warroom-game/tool/*` were not verified.
6. **m6a / unlimited** — decide after the load test (alarms now show it).
