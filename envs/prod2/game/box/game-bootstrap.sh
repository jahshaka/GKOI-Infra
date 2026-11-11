#!/bin/bash
# game-bootstrap.sh — a GKOI prod2 War Room game box (envs/prod2/game), idempotent. It WRAPS the War Room hosting tool
# (ops/warroom-game of GKOIBuilder_AI, unpacked into /opt/warroom-game from the SAME source.zip CodeBuild built the
# image from) and adds only what an ASG box needs around it. The tool stays the one source of truth for the box
# (packages, Docker, SSM, sysctl, ufw, certs, matchd.json, compose, deploy/drain/rollback, the drain hook).
#
#   game-bootstrap.sh apply [--only P[,P…]]   as root (user-data, SSM Run Command): the phases below, in order
#   game-bootstrap.sh check                   read-only: exit 0 = the box is set up and the stack runs the config's tag
#   game-bootstrap.sh render                  print the env file + matchd.json this box would run (no secrets in them)
#
# The phases:
#   config     /gkoi/prod2/game/<key>/config (SSM) → /etc/gkoi-game/config.json; this bundle refreshed (sha256-checked;
#              a changed game-bootstrap.sh re-executes the run)
#   tool       the War Room tool zip (S3, sha256 + the commit in its zip comment checked) → /opt/warroom-game
#   render     /opt/warroom-game/ops.box.env = the tool's ops.<warroom_env>.env with THIS box's names (rehearsal or
#              live), + matchd.json from the tool's config/matchd.<warroom_env>.json with the same names (+ rooms.json,
#              the word list). A change on a RUNNING stack drains it first (live matches finish), then writes
#   eip        the region's Elastic IP onto THIS instance (refused while another instance holds it, unless
#              GKOI_GAME_TAKE_EIP=1)
#   hosts      /etc/hosts: the names this box serves → its own EIP (the tool's self-checks and matchd's admission
#              call reach THIS box whatever public DNS says — e.g. before the live names move here)
#   warroom    the tool's own bootstrap.sh apply --only packages,tool,ssm,sysctl,firewall,certs (its cloudwatch
#              phase is replaced by ours below)
#   certtidy   every Let's Encrypt lineage but the served one is deleted (the tool's deploy hook copies WHATEVER
#              lineage renews into the secrets dir: a stale rehearsal lineage would swap the live cert out)
#   cloudwatch the CloudWatch agent (signature-checked .deb) with OUR config: the tool's logs + metrics, matchd's
#              /metrics scraped (Prometheus → EMF: steal %, busy %, per-server CPU/RSS) and procstat for the processes
#   imdsguard  REJECT the game runtime uid (host networking!) → 169.254.169.254: the game server never reaches the
#              instance role (a systemd unit, re-applied at boot)
#   secrets    Secrets Manager (us-west-2) → the tool's secrets dir: match-server-key.txt; ticket.p8 from its secret
#              when the region names one, else generated ONCE on this box (Ed25519, PKCS#8 v2 DER, 83 bytes)
#   image      ECR (this region's replica) gkoi/warroom-game@<digest> → tagged warroom-game:<tag> (what the tool runs)
#   stack      the tool: `deploy <tag>` when another (or no) tag runs; drain + up when the env/config/secrets changed;
#              nothing otherwise. Missing secrets: skipped, and gkoi-game-start.timer retries every 5 min
#   lifecycle  gkoi-game-lifecycle.service (lifecycle-watch.sh: the ASG terminate hook → the tool's drain-hook.sh)
#
# Nothing here prints a secret. Logs: /var/log/gkoi-game-bootstrap.log → CloudWatch /gkoi/prod2/game/<key>/bootstrap.
set -euo pipefail
# SSM Run Command starts with no HOME and the agent's snap directory as cwd; the aws CLI and docker want both sane.
export HOME="${HOME:-/root}"; cd /
GKOI_GAME_WHO=game-bootstrap
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=game-lib.sh
. "$HERE/game-lib.sh"

PHASES=(config tool render eip hosts warroom certtidy cloudwatch imdsguard secrets image stack lifecycle)
WARROOM_PHASES=packages,tool,ssm,sysctl,firewall,certs
CWAGENT_KEY_FPR=937616F3450B7D806CBD9725D58167303B789C72
CW_CTL=/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl
CW_CONF=/opt/aws/amazon-cloudwatch-agent/etc/gkoi-game-prod2.json
PROM_CONF=/opt/aws/amazon-cloudwatch-agent/etc/gkoi-game-prometheus.yaml
HOSTS_BEGIN='# BEGIN gkoi-game (game-bootstrap.sh phase hosts)'
HOSTS_END='# END gkoi-game'
FINGERPRINT="$STATE/stack.fingerprint"
PENDING="$STATE/secrets.pending"

need_root() { [ "$(id -u)" -eq 0 ] || die "run as root (sudo / SSM)"; }
install_if_changed() { # src dst mode → 0 = written, 1 = unchanged
  if [ -e "$2" ] && cmp -s "$1" "$2"; then return 1; fi
  install -D -m "$3" -o root -g root "$1" "$2" || die "cannot install $2"
  say "wrote $2"; return 0
}
write_file() { # MODE DST < content → 0 = written, 1 = unchanged
  local tmp rc=1; tmp="$(mktemp)"; cat > "$tmp"
  install_if_changed "$tmp" "$2" "$1" && rc=0
  rm -f "$tmp"; return $rc
}
base_env() { printf '%s/ops.%s.env' "$WR" "$(cfg .warroom_env)"; }
base_matchd() { printf '%s/config/matchd.%s.json' "$WR" "$(cfg .warroom_env)"; }

# =====================================================================================================================
phase_config() {
  local region key param val tmp
  have aws || { snap install aws-cli --classic || die "snap install aws-cli failed"; }
  local missing=() t
  for t in jq unzip rsync; do have "$t" || missing+=("$t"); done
  if [ ${#missing[@]} -gt 0 ]; then
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 update -q || die "apt-get update failed"
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install -yq --no-install-recommends "${missing[@]}" \
      || die "apt-get install ${missing[*]} failed"
  fi
  region="$(own_region)" || die "no region from IMDS"
  key="$(cfg .key)" || die "no key in $CFG (the user-data writes the first copy)"
  param="/gkoi/prod2/game/$key/config"
  # Captured, not redirected: under SSM Run Command the snap aws CLI wrote NOTHING to a redirected file and exited 0.
  val="$(aws ssm get-parameter --region "$region" --name "$param" --query Parameter.Value --output text)" || die "cannot read $param"
  tmp="$(mktemp)"; printf '%s\n' "$val" > "$tmp"
  jq -e '.v == 1 and (.key | type == "string") and (.image.tag | type == "string")' "$tmp" >/dev/null \
    || { rm -f "$tmp"; die "$param is not a v1 game box config"; }
  install_if_changed "$tmp" "$CFG" 0644 || say "config: $param unchanged"
  rm -f "$tmp"

  local bucket bregion prefix f sha have_sha self_changed=0
  bucket="$(cfg .bundle.bucket)"; bregion="$(cfg .bundle.region)"; prefix="$(cfg .bundle.prefix)"
  while read -r f sha; do
    [[ "$f" =~ ^[A-Za-z0-9._-]+$ ]] || die "bundle file name '$f' is not plain"
    have_sha="$( [ -f "$BOX/$f" ] && sha256sum "$BOX/$f" | cut -d' ' -f1 || true)"
    [ "$have_sha" = "$sha" ] && continue
    aws s3 cp --only-show-errors --region "$bregion" "s3://$bucket/$prefix$f" "$BOX/$f.new" || die "cannot download $prefix$f"
    echo "$sha  $BOX/$f.new" | sha256sum -c --quiet - || { rm -f "$BOX/$f.new"; die "$f: sha256 mismatch"; }
    case "$f" in *.sh) chmod 0755 "$BOX/$f.new" ;; *) chmod 0644 "$BOX/$f.new" ;; esac
    mv "$BOX/$f.new" "$BOX/$f"
    say "bundle: $f updated"
    [ "$f" = game-bootstrap.sh ] && self_changed=1
  done < <(jq -r '.bundle.files | to_entries[] | "\(.key) \(.value)"' "$CFG")
  if [ $self_changed -eq 1 ] && [ -z "${GKOI_GAME_REEXEC:-}" ]; then
    say "bundle: game-bootstrap.sh changed — re-executing"
    GKOI_GAME_REEXEC=1 exec "$BOX/game-bootstrap.sh" "${ORIG_ARGS[@]}"
  fi
}

# =====================================================================================================================
phase_tool() {
  local bucket region key want commit marker="$WR/.gkoi-tool" zip got comment stage src e
  bucket="$(cfg .tool.bucket)"; region="$(cfg .tool.region)"; key="$(cfg .tool.s3_key)"
  want="$(cfg .tool.sha256)"; commit="$(cfg .tool.commit)"
  if [ -f "$marker" ] && [ "$(cat "$marker")" = "$want $commit" ] && [ -x "$WR/warroom-game.sh" ]; then
    say "tool: $WR is ops/warroom-game@${commit:0:12} (sha256 ${want:0:12})"; return 0
  fi
  zip="$(mktemp --suffix .zip)"; stage="$(mktemp -d)"
  aws s3 cp --only-show-errors --region "$region" "s3://$bucket/$key" "$zip" || { rm -rf "$zip" "$stage"; die "cannot download s3://$bucket/$key"; }
  got="$(sha256sum "$zip" | cut -d' ' -f1)"
  [ "$got" = "$want" ] || { rm -rf "$zip" "$stage"; die "tool zip sha256 is $got, the config says $want"; }
  # git archive writes the commit into the zip comment (tools/gkoi-release checks the same)
  comment="$(python3 -I -c 'import sys,zipfile; print(zipfile.ZipFile(sys.argv[1]).comment.decode())' "$zip")"
  [ "$comment" = "$commit" ] || { rm -rf "$zip" "$stage"; die "the tool zip says commit '$comment', the config says $commit"; }
  unzip -q "$zip" -d "$stage" || { rm -rf "$zip" "$stage"; die "unzip of the tool failed"; }
  rm -f "$zip"
  src="$stage/ops/warroom-game"
  for e in warroom-game.sh bootstrap.sh drain-hook.sh certbot-deploy-hook.sh compose.yml \
           "ops.$(cfg .warroom_env).env" "config/matchd.$(cfg .warroom_env).json"; do
    [ -e "$src/$e" ] || { rm -rf "$stage"; die "the tool at ${commit:0:12} has no $e (a region added after that commit? warroom_tool_override)"; }
  done
  install -d -m 0755 -o root -g root "$WR"
  # ops.box.env is THIS box's (phase render); never overwritten by a tool refresh. Nothing is deleted.
  rsync -rlpt --chown=root:root --chmod=Du=rwx,Dgo=rx,Fgo-w --exclude 'ops.box.env' --exclude '*.bak*' "$src/" "$WR/" \
    || { rm -rf "$stage"; die "rsync of the tool to $WR failed"; }
  chmod 0755 "$WR"/*.sh
  rm -rf "$stage"
  printf '%s %s\n' "$want" "$commit" > "$marker"
  say "tool: $WR = ops/warroom-game@${commit:0:12} from s3://$bucket/$key"
}

# =====================================================================================================================
# The env file: the tool's region file with THIS box's public URLs (and the prod2 CloudWatch prefix, ACME staging).
set_kv() { # FILE KEY VALUE — replace the one KEY= line, or append it; two lines = refused
  local n; n="$(grep -c "^$2=" "$1" || true)"
  case "$n" in
    0) printf '%s=%s\n' "$2" "$3" >> "$1" ;;
    1) local esc; esc="$(printf '%s' "$3" | sed 's/[&|\\]/\\&/g')"; sed -i "s|^$2=.*|$2=$esc|" "$1" ;;
    *) die "render: $2 is set $n times in the base env file" ;;
  esac
}
render_env() { # → stdout
  local base tmp mp gp; base="$(base_env)"; tmp="$(mktemp)"
  [ -r "$base" ] || die "render: no $base (phase tool first)"
  mp="$(sed -n 's/^WARROOM_MATCHD_PORT=//p' "$base" | tail -1)"; gp="$(sed -n 's/^WARROOM_GATEWAY_PORT=//p' "$base" | tail -1)"
  [ "$mp" = "$(cfg .matchd_port)" ] && [ "$gp" = "$(cfg .gateway_port)" ] \
    || die "render: $base has matchd $mp / gateway $gp, the stack's SG opens $(cfg .matchd_port) / $(cfg .gateway_port)"
  {
    printf '# Written by game-bootstrap.sh (phase render) from %s @ %s: DO NOT EDIT — change the stack, re-apply.\n' \
      "$(basename "$base")" "$(cfg .tool.commit | cut -c1-12)"
    printf '# GKOI prod2 game box %s (%s), serving %s + %s. Literal values only (compose reads this file too).\n' \
      "$(cfg .key)" "$(cfg .region)" "$(cfg .matchd_host)" "$(cfg .gateway_host)"
    grep -v '^# warroom-game — \|^# NOT A BOX YET\|^# ticket key\. Written ahead' "$base"
  } > "$tmp"
  set_kv "$tmp" WARROOM_MATCHD_PUBLIC_URL "https://$(cfg .matchd_host):$(cfg .matchd_port)"
  set_kv "$tmp" WARROOM_GATEWAY_PUBLIC_URL "https://$(cfg .gateway_host):$(cfg .gateway_port)"
  set_kv "$tmp" WARROOM_CW_LOG_PREFIX "$(cfg .cw.log_prefix)"
  set_kv "$tmp" WARROOM_CW_NAMESPACE "$(cfg .cw.namespace)"
  set_kv "$tmp" WARROOM_ACME_STAGING "$( [ "$(cfg_or .acme_staging false)" = true ] && echo 1 || true)"
  set_kv "$tmp" WARROOM_TOOL_DIR "$WR"
  cat "$tmp"; rm -f "$tmp"
}
render_matchd() { # → stdout: the tool's region config with this box's gateway URLs; the version fields of the box's
                  # current matchd.json kept (the tool's deploy rewrites them from the image labels)
  local base cur gw; base="$(base_matchd)"; gw="https://$(cfg .gateway_host):$(cfg .gateway_port)"
  [ -r "$base" ] || die "render: no $base"
  cur="$(env_get WARROOM_CONFIG_DIR 2>/dev/null)/matchd.json"
  [ "$(jq -r .region "$base")" = "$(cfg .key)" ] || die "render: $base says region $(jq -r .region "$base"), the box is $(cfg .key)"
  if [ -r "$cur" ]; then
    jq --indent 1 --arg gw "$gw" --slurpfile c "$cur" \
      '.gateway.admission_url = ($gw + "/v1/admission") | .gateway.public_url = $gw
       | .game_version = $c[0].game_version | .net_version = $c[0].net_version | .net_checksum = $c[0].net_checksum' "$base"
  else
    jq --indent 1 --arg gw "$gw" '.gateway.admission_url = ($gw + "/v1/admission") | .gateway.public_url = $gw' "$base"
  fi
}

phase_render() {
  local env_new cfg_new cfg_dir user changed="" f
  env_new="$(mktemp)"; cfg_new="$(mktemp)"
  render_env > "$env_new"
  # the box folders the tool's bootstrap would make (render runs before it on a fresh box)
  cfg_dir="$(sed -n 's/^WARROOM_CONFIG_DIR=//p' "$env_new" | tail -1)"; user="$(sed -n 's/^WARROOM_BOX_USER=//p' "$env_new" | tail -1)"
  user="${user:-ubuntu}"
  [ -n "$cfg_dir" ] || die "render: no WARROOM_CONFIG_DIR"
  install -d -m 0755 -o "$user" -g "$user" "$cfg_dir" "$(dirname "$(sed -n 's/^WARROOM_STATE_FILE=//p' "$env_new" | tail -1)")"
  [ -f "$BOX_ENV" ] || cp "$env_new" "$BOX_ENV"   # env_get needs it for the first render_matchd
  render_matchd > "$cfg_new"
  jq -e . "$cfg_new" >/dev/null || die "render: the rendered matchd.json is not JSON"
  cmp -s "$env_new" "$BOX_ENV" || changed+=" env"
  cmp -s "$cfg_new" "$cfg_dir/matchd.json" 2>/dev/null || changed+=" matchd.json"
  for f in $(jq -r '[.rooms.catalogue // empty, .chat.words_file // empty] | .[]' "$cfg_new"); do
    [[ "$f" =~ ^[A-Za-z0-9._-]+$ ]] || die "render: catalogue file name '$f' is not plain"
    cmp -s "$WR/config/$f" "$cfg_dir/$f" 2>/dev/null || changed+=" $f"
  done
  if [ -z "$changed" ]; then rm -f "$env_new" "$cfg_new"; say "render: env + matchd.json current ($(cfg .matchd_host))"; return 0; fi
  if [ -n "$(running_tag)" ] && [ "${GKOI_GAME_DRY:-}" != 1 ]; then
    say "render:$changed changed on a RUNNING stack: draining first (live matches finish; up to $(env_get WARROOM_DRAIN_TIMEOUT) s)"
    wr drain || die "render: the drain failed (the stack keeps the old config; warroom-game.sh status)"
  fi
  if [ "${GKOI_GAME_DRY:-}" = 1 ]; then
    say "dry run:$changed would change"; diff -u "$BOX_ENV" "$env_new" || true; diff -u "$cfg_dir/matchd.json" "$cfg_new" 2>/dev/null || true
    rm -f "$env_new" "$cfg_new"; return 0
  fi
  install -m 0644 -o root -g root "$env_new" "$BOX_ENV"
  [ ! -e "$cfg_dir/matchd.json" ] || cp -p "$cfg_dir/matchd.json" "$cfg_dir/matchd.json.bak-$(date -u +%Y%m%dT%H%M%SZ)"
  install -m 0644 -o "$user" -g "$user" "$cfg_new" "$cfg_dir/matchd.json"
  for f in $(jq -r '[.rooms.catalogue // empty, .chat.words_file // empty] | .[]' "$cfg_new"); do
    install -m 0644 -o "$user" -g "$user" "$WR/config/$f" "$cfg_dir/$f"
    case "$f" in *.txt) [ ! -f "$WR/config/${f%.txt}.README.md" ] || install -m 0644 -o "$user" -g "$user" "$WR/config/${f%.txt}.README.md" "$cfg_dir/" ;; esac
  done
  rm -f "$env_new" "$cfg_new"
  say "render:$changed written (serving $(cfg .matchd_host) + $(cfg .gateway_host))"
}

# =====================================================================================================================
phase_eip() {
  local alloc want iid region assoc_iid _
  alloc="$(cfg .eip_allocation_id)"; want="$(cfg .eip_public_ip)"
  iid="$(instance_id)" || die "no instance id from IMDS"; region="$(own_region)"
  if [ "$(public_ip)" = "$want" ]; then say "eip: $want is this box's"; return 0; fi
  assoc_iid="$(aws ec2 describe-addresses --region "$region" --allocation-ids "$alloc" --query 'Addresses[0].InstanceId' --output text 2>/dev/null || true)"
  if [ -n "$assoc_iid" ] && [ "$assoc_iid" != None ] && [ "$assoc_iid" != "$iid" ] && [ "${GKOI_GAME_TAKE_EIP:-}" != 1 ]; then
    die "eip: $want is held by $assoc_iid (a live box?). Drain + stop that box, or re-run with GKOI_GAME_TAKE_EIP=1"
  fi
  aws ec2 associate-address --region "$region" --allocation-id "$alloc" --instance-id "$iid" --allow-reassociation >/dev/null \
    || die "eip: associate-address failed"
  for _ in $(seq 1 30); do [ "$(public_ip)" = "$want" ] && break; sleep 2; done
  [ "$(public_ip)" = "$want" ] || warn "eip: associated, but IMDS still shows $(public_ip)"
  say "eip: $want → $iid"
}

# =====================================================================================================================
phase_hosts() {
  local tmp; tmp="$(mktemp)"
  awk -v b="$HOSTS_BEGIN" -v e="$HOSTS_END" '$0==b{skip=1; next} $0==e{skip=0; next} !skip' /etc/hosts > "$tmp"
  { printf '%s\n' "$HOSTS_BEGIN"; printf '%s %s %s\n' "$(cfg .eip_public_ip)" "$(cfg .matchd_host)" "$(cfg .gateway_host)"; printf '%s\n' "$HOSTS_END"; } >> "$tmp"
  if cmp -s "$tmp" /etc/hosts; then say "hosts: $(cfg .matchd_host) + $(cfg .gateway_host) → $(cfg .eip_public_ip)"
  else cat "$tmp" > /etc/hosts; say "hosts: wrote $(cfg .matchd_host) + $(cfg .gateway_host) → $(cfg .eip_public_ip)"; fi
  rm -f "$tmp"
}

# =====================================================================================================================
phase_warroom() {
  [ -x "$WR/bootstrap.sh" ] || die "no $WR/bootstrap.sh (phase tool)"
  "$WR/bootstrap.sh" --env "$BOX_ENV" apply --only "$WARROOM_PHASES" || die "ops/warroom-game bootstrap.sh apply failed (above; /var/log/warroom-game-bootstrap.log)"
}

# =====================================================================================================================
phase_certtidy() {
  local active conf name
  active="$(cfg .matchd_host)"
  [ -s "/etc/letsencrypt/live/$active/fullchain.pem" ] || { warn "certtidy: no live lineage $active yet: nothing deleted"; return 0; }
  for conf in /etc/letsencrypt/renewal/*.conf; do
    [ -e "$conf" ] || continue
    name="$(basename "$conf" .conf)"
    [ "$name" = "$active" ] && continue
    certbot delete --non-interactive --cert-name "$name" >/dev/null 2>&1 || die "certtidy: certbot delete $name failed"
    say "certtidy: deleted the lineage $name (this box serves $active)"
  done
}

# =====================================================================================================================
phase_cloudwatch() {
  if [ ! -x "$CW_CTL" ]; then
    local r d g fpr base arch
    r="$(own_region)" || die "no region from IMDS"; arch="$(dpkg --print-architecture)"
    d="$(mktemp -d)"; g="$d/gnupg"; install -d -m 0700 "$g"
    base="https://amazoncloudwatch-agent-$r.s3.$r.amazonaws.com/ubuntu/$arch/latest"
    if ! { curl -fsSL -o "$d/key.gpg" https://amazoncloudwatch-agent.s3.amazonaws.com/assets/amazon-cloudwatch-agent.gpg \
      && curl -fsSL -o "$d/agent.deb" "$base/amazon-cloudwatch-agent.deb" \
      && curl -fsSL -o "$d/agent.deb.sig" "$base/amazon-cloudwatch-agent.deb.sig"; }; then
      rm -rf "$d"; die "cannot download the CloudWatch agent"
    fi
    gpg --homedir "$g" --batch --quiet --import "$d/key.gpg" 2>/dev/null
    fpr="$(gpg --homedir "$g" --batch --with-colons --fingerprint 2>/dev/null | awk -F: '$1=="fpr"{print $10; exit}')"
    [ "$fpr" = "$CWAGENT_KEY_FPR" ] || { rm -rf "$d"; die "the CloudWatch agent key is '$fpr', not the pinned $CWAGENT_KEY_FPR"; }
    gpg --homedir "$g" --batch --quiet --verify "$d/agent.deb.sig" "$d/agent.deb" 2>/dev/null \
      || { rm -rf "$d"; die "the CloudWatch agent package's signature does NOT verify"; }
    dpkg -i "$d/agent.deb" >/dev/null || { rm -rf "$d"; die "dpkg -i amazon-cloudwatch-agent failed"; }
    rm -rf "$d"
    say "cloudwatch: agent installed (signature verified)"
  fi
  local tmp ptmp changed=1
  tmp="$(mktemp)"; ptmp="$(mktemp)"
  cw_render "$BOX/cloudwatch-agent.json.tmpl" > "$tmp"
  cw_render "$BOX/prometheus.yaml.tmpl" > "$ptmp"
  jq -e . "$tmp" >/dev/null || { rm -f "$tmp" "$ptmp"; die "the rendered CloudWatch config is not JSON"; }
  install_if_changed "$ptmp" "$PROM_CONF" 0644 && changed=0
  install_if_changed "$tmp" "$CW_CONF" 0644 && changed=0
  rm -f "$tmp" "$ptmp"
  if [ $changed -eq 0 ] || ! systemctl is-active --quiet amazon-cloudwatch-agent.service; then
    # fetch-config REPLACES the agent's config: ours only (never the tool's gkoi-game.json)
    "$CW_CTL" -a fetch-config -m ec2 -s -c "file:$CW_CONF" >/dev/null || die "the CloudWatch agent did not take $CW_CONF"
    say "cloudwatch: agent (re)started with $CW_CONF"
  else
    say "cloudwatch: agent running with $CW_CONF"
  fi
}
cw_render() { # template → stdout, @@NAME@@ replaced
  local s; s="$(cat "$1")" || die "no template $1"
  s="${s//@@CW_NAMESPACE@@/$(cfg .cw.namespace)}"; s="${s//@@CW_LOG_PREFIX@@/$(cfg .cw.log_prefix)}"
  s="${s//@@CW_METRICS_LOG_GROUP@@/$(cfg .cw.metrics_log_group)}"; s="${s//@@REGION_KEY@@/$(cfg .key)}"
  s="${s//@@PROM_CONF@@/$PROM_CONF}"; s="${s//@@MONITOR_PORT@@/$(env_get WARROOM_MONITOR_PORT)}"
  printf '%s\n' "$s"
}

# =====================================================================================================================
phase_imdsguard() {
  local uid; uid="$(env_get WARROOM_RUNTIME_UID)"
  [[ "$uid" =~ ^[0-9]+$ ]] || die "imdsguard: no WARROOM_RUNTIME_UID in $BOX_ENV"
  if write_file 0644 /etc/systemd/system/gkoi-game-imds-guard.service <<EOF
[Unit]
Description=GKOI game: the game runtime uid $uid may not reach the instance metadata service (host networking)
Before=docker.service
After=network-pre.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'iptables -C OUTPUT -d 169.254.169.254/32 -m owner --uid-owner $uid -j REJECT 2>/dev/null || iptables -I OUTPUT 1 -d 169.254.169.254/32 -m owner --uid-owner $uid -j REJECT'
[Install]
WantedBy=multi-user.target
EOF
  then systemctl daemon-reload; fi
  systemctl enable gkoi-game-imds-guard.service >/dev/null 2>&1 || die "imdsguard: cannot enable the unit"
  systemctl restart gkoi-game-imds-guard.service || die "imdsguard: the unit failed"
  iptables -C OUTPUT -d 169.254.169.254/32 -m owner --uid-owner "$uid" -j REJECT 2>/dev/null || die "imdsguard: the rule is not in OUTPUT"
  say "imdsguard: uid $uid → 169.254.169.254 rejected"
}

# =====================================================================================================================
secret_value() { # ARN → the value on stdout (never printed by callers); exit 3 = no value yet, 1 = other error
  local out err rc=0
  err="$(mktemp)"
  # stdout captured (the value), stderr apart: a CLI warning must never end up inside a key
  out="$(aws secretsmanager get-secret-value --region "$(cfg .secrets_region)" --secret-id "$1" --query SecretString --output text 2>"$err")" || rc=$?
  if [ $rc -ne 0 ]; then
    if grep -q ResourceNotFoundException "$err"; then rm -f "$err"; return 3; fi
    printf 'secret read failed: %s\n' "$(head -1 "$err" | cut -c1-160)" >&2; rm -f "$err"; return 1
  fi
  rm -f "$err"
  [ -n "$out" ] && [ "$out" != None ] || return 3
  printf '%s' "$out"
}
install_secret_file() { # SRC NAME → 0 = written, 1 = unchanged (the tool's secrets dir: 0600, the runtime uid)
  local dir uid; dir="$(env_get WARROOM_SECRETS_DIR)"; uid="$(env_get WARROOM_RUNTIME_UID)"
  [ -d "$dir" ] || install -d -m 0700 -o "$uid" -g "$uid" "$dir"
  if [ -e "$dir/$2" ] && cmp -s "$1" "$dir/$2"; then return 1; fi
  install -m 0600 -o "$uid" -g "$uid" "$1" "$dir/.$2.new" || die "secrets: cannot install $2"
  mv -f "$dir/.$2.new" "$dir/$2" || die "secrets: cannot install $2"
  say "secrets: $2 written"; return 0
}
gen_ticket_key() { # FILE — Ed25519, PKCS#8 v2 DER (83 bytes): matchd refuses the v1 form `openssl genpkey` writes
  local d; d="$(mktemp -d)"; chmod 0700 "$d"
  openssl genpkey -algorithm ed25519 -outform DER -out "$d/k1.der" 2>/dev/null || { rm -rf "$d"; die "secrets: openssl genpkey failed"; }
  openssl pkey -inform DER -in "$d/k1.der" -pubout -outform DER -out "$d/pub.der" 2>/dev/null || { rm -rf "$d"; die "secrets: openssl pkey failed"; }
  python3 -I - "$d/k1.der" "$d/pub.der" "$1" <<'PY' || { rm -rf "$d"; die "secrets: cannot assemble the PKCS#8 v2 key"; }
import sys
k = open(sys.argv[1], "rb").read(); p = open(sys.argv[2], "rb").read()
assert len(k) == 48 and k[:16] == bytes.fromhex("302e020100300506032b657004220420"), "not a v1 Ed25519 PKCS#8"
assert len(p) == 44 and p[:12] == bytes.fromhex("302a300506032b6570032100"), "not an Ed25519 SPKI"
v2 = bytes.fromhex("3051020101300506032b657004220420") + k[16:] + bytes.fromhex("812100") + p[12:]
assert len(v2) == 83
open(sys.argv[3], "wb").write(v2)
PY
  # (no parse-back: Ubuntu 24.04's OpenSSL 3.0 cannot read a v2 PKCS#8 — 3.5 can, and matched the public key when the
  # construction was proven; the public half here is OpenSSL's own derivation from the same key, and matchd's loader
  # checks the pair at start)
  check_ticket_der "$1" || { rm -rf "$d"; die "secrets: the assembled key is not an 83-byte PKCS#8 v2"; }
  rm -rf "$d"
}
check_ticket_der() { # FILE → 0 = an 83-byte Ed25519 PKCS#8 v2
  [ "$(stat -c %s "$1")" = 83 ] && [ "$(head -c 16 "$1" | od -An -tx1 | tr -d ' \n')" = 3051020101300506032b657004220420 ]
}

phase_secrets() {
  local tmp rc arn dir missing=() val
  tmp="$(mktemp)"; chmod 0600 "$tmp"   # mktemp creates 0600; the generator below writes into it
  dir="$(env_get WARROOM_SECRETS_DIR)"
  # the match-server key (ours: invites:read + plays:write) — matchd's invites.key_file + plays.key_file
  rc=0; val="$(secret_value "$(cfg .secrets.match_server_key)")" || rc=$?
  case $rc in
    0) case "$val" in *$'\n'*|*' '*) rm -f "$tmp"; die "secrets: the match-server key holds whitespace — refused (the value is not printed)" ;; esac
       printf '%s' "$val" > "$tmp"; install_secret_file "$tmp" match-server-key.txt || true ;;
    3) missing+=("match-server-key (no value in $(cfg .secrets.match_server_key | sed 's/.*:secret://'))") ;;
    *) rm -f "$tmp"; die "secrets: cannot read the match-server key" ;;
  esac
  val=""
  # the gateway-ticket key: from its secret when the region names one, else this box's own (generated once)
  arn="$(cfg_or .secrets.ticket_key '')"
  if [ -n "$arn" ]; then
    rc=0; val="$(secret_value "$arn")" || rc=$?
    case $rc in
      0) printf '%s' "$val" | base64 -d > "$tmp" 2>/dev/null || { rm -f "$tmp"; die "secrets: the ticket key secret is not base64"; }
         check_ticket_der "$tmp" || { rm -f "$tmp"; die "secrets: the ticket key secret is not an 83-byte Ed25519 PKCS#8 v2 DER"; }
         install_secret_file "$tmp" ticket.p8 || true ;;
      3) missing+=("ticket key (no value in its secret)") ;;
      *) rm -f "$tmp"; die "secrets: cannot read the ticket key" ;;
    esac
    val=""
  elif [ ! -s "$dir/ticket.p8" ]; then
    gen_ticket_key "$tmp"; install_secret_file "$tmp" ticket.p8 || true   # into the 0600 temp: never a fresh 0644 file
    say "secrets: ticket.p8 generated on this box (kid $(jq -r .ticket.kid "$(env_get WARROOM_CONFIG_DIR)/matchd.json"))"
  else
    check_ticket_der "$dir/ticket.p8" || die "secrets: $dir/ticket.p8 is not an 83-byte Ed25519 PKCS#8 v2 DER"
  fi
  rm -f "$tmp"
  if [ ${#missing[@]} -gt 0 ]; then
    printf '%s\n' "${missing[@]}" > "$PENDING"
    warn "secrets: waiting for: ${missing[*]} — the stack starts by itself (gkoi-game-start.timer) once they have values"
  else
    rm -f "$PENDING"; say "secrets: in place"
  fi
}

# =====================================================================================================================
phase_image() {
  local ref tag registry pw
  ref="$(cfg .image.ref)"; tag="$(cfg .image.tag)"; registry="$(cfg .image.registry)"
  if ! docker image inspect "$ref" >/dev/null 2>&1; then
    pw="$(aws ecr get-login-password --region "$(own_region)")" || die "image: ECR login token failed"
    printf '%s' "$pw" | docker login --username AWS --password-stdin "$registry" >/dev/null || die "image: docker login $registry failed"
    pw=""
    docker pull -q "$ref" >/dev/null || die "image: pull $ref failed"
    say "image: pulled $ref"
  fi
  docker tag "$ref" "warroom-game:$tag" || die "image: cannot tag warroom-game:$tag"
  [ -n "$(docker image inspect -f '{{ index .Config.Labels "dev.gkoi.warroom.game_version" }}' "warroom-game:$tag")" ] \
    || die "image: warroom-game:$tag carries no game_version label (not a warroom-game.sh build?)"
  say "image: warroom-game:$tag = ${ref##*@}"
}

# =====================================================================================================================
fingerprint() { # the inputs matchd reads at start (TLS excluded: the tool's own cert hook restarts for a renewal)
  local dir; dir="$(env_get WARROOM_SECRETS_DIR)"
  cat "$BOX_ENV" "$(env_get WARROOM_CONFIG_DIR)/matchd.json" "$dir/match-server-key.txt" "$dir/ticket.p8" 2>/dev/null \
    | sha256sum | cut -d' ' -f1
}
start_timer() { # on|off — gkoi-game-start.timer: retry secrets,image,stack every 5 min while secrets are missing
  if [ "$1" = on ]; then
    write_file 0644 /etc/systemd/system/gkoi-game-start.service <<EOF || true
[Unit]
Description=GKOI game: start the stack once its secrets have values
After=docker.service network-online.target
[Service]
Type=oneshot
ExecStart=$BOX/game-bootstrap.sh apply --only secrets,image,stack
EOF
    write_file 0644 /etc/systemd/system/gkoi-game-start.timer <<'EOF' || true
[Unit]
Description=GKOI game: retry the stack start every 5 minutes (secrets pending)
[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload; systemctl enable --now gkoi-game-start.timer >/dev/null 2>&1 || warn "stack: the start timer did not start"
  else
    systemctl disable --now gkoi-game-start.timer >/dev/null 2>&1 || true
  fi
}

phase_stack() {
  local want run fp
  want="$(cfg .image.tag)"
  if [ -e "$(env_get WARROOM_STATE_FILE).retiring" ]; then warn "stack: the box is RETIRING (drain hook): nothing started"; return 0; fi
  if [ -e "$PENDING" ]; then
    start_timer on; warn "stack: NOT started — secrets missing: $(tr '\n' ';' < "$PENDING")"; return 0
  fi
  run="$(running_tag)"
  fp="$(fingerprint)"
  if [ "$run" != "$want" ]; then
    say "stack: ${run:-nothing} running → deploy $want (the tool drains a running stack first)"
    wr deploy "$want" || die "stack: warroom-game.sh deploy $want failed"
  elif [ "$fp" != "$(cat "$FINGERPRINT" 2>/dev/null)" ]; then
    say "stack: $want runs with an older env/config/secret: drain + up"
    wr drain || die "stack: drain failed"
    wr up "$want" || die "stack: up $want failed"
  else
    say "stack: $want running, inputs unchanged"
  fi
  fingerprint > "$FINGERPRINT"
  start_timer off
}

# =====================================================================================================================
phase_lifecycle() {
  write_file 0644 /etc/systemd/system/gkoi-game-lifecycle.service <<EOF || true
[Unit]
Description=GKOI game: the ASG terminate hook (matchd drain-and-exit, live matches finish, let go)
After=docker.service network-online.target
Wants=network-online.target
[Service]
ExecStart=$BOX/lifecycle-watch.sh
Restart=always
RestartSec=15
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now gkoi-game-lifecycle.service >/dev/null 2>&1 || die "lifecycle: the watcher did not start"
  systemctl try-restart gkoi-game-lifecycle.service >/dev/null 2>&1 || true
  say "lifecycle: watcher running"
}

# =====================================================================================================================
do_check() {
  local bad=0 out fails conf want run uid
  [ -f "$CFG" ] || { echo "no $CFG"; exit 1; }
  echo "box $(instance_id 2>/dev/null || echo '?') key $(cfg .key) region $(cfg .region) tag $(cfg .image.tag) serving $(cfg .matchd_host) + $(cfg .gateway_host)"
  if [ "$(cat "$WR/.gkoi-tool" 2>/dev/null)" = "$(cfg .tool.sha256) $(cfg .tool.commit)" ]; then echo "tool: ok ops/warroom-game@$(cfg .tool.commit | cut -c1-12)"; else echo "tool: NOT the config's"; bad=1; fi
  if [ -f "$BOX_ENV" ] && cmp -s <(render_env) "$BOX_ENV"; then echo "env: ok $BOX_ENV"; else echo "env: $BOX_ENV differs from the render"; bad=1; fi
  if [ "$(public_ip)" = "$(cfg .eip_public_ip)" ]; then echo "eip: ok $(cfg .eip_public_ip)"; else echo "eip: NOT on this box"; bad=1; fi
  if grep -qxF "$(cfg .eip_public_ip) $(cfg .matchd_host) $(cfg .gateway_host)" /etc/hosts; then echo "hosts: ok"; else echo "hosts: block missing"; bad=1; fi
  # the tool's own check; its CloudWatch line is ours to own here (phase cloudwatch), so that one FAIL is expected
  out="$("$WR/bootstrap.sh" --env "$BOX_ENV" check 2>&1 || true)"
  fails="$(grep 'FAIL' <<<"$out" | grep -v 'CloudWatch agent' | grep -v '^bootstrap: check: ' || true)"
  if [ -z "$fails" ]; then echo "warroom bootstrap check: ok (its CloudWatch line excepted)"; else printf 'warroom bootstrap check:\n%s\n' "$fails"; bad=1; fi
  for conf in /etc/letsencrypt/renewal/*.conf; do
    [ -e "$conf" ] || continue
    [ "$(basename "$conf" .conf)" = "$(cfg .matchd_host)" ] || { echo "cert: a stale lineage $(basename "$conf" .conf)"; bad=1; }
  done
  if systemctl is-active --quiet amazon-cloudwatch-agent.service && cmp -s <(cw_render "$BOX/cloudwatch-agent.json.tmpl") "$CW_CONF"; then
    echo "cloudwatch: ok"; else echo "cloudwatch: agent / $CW_CONF"; bad=1; fi
  uid="$(env_get WARROOM_RUNTIME_UID)"
  if iptables -C OUTPUT -d 169.254.169.254/32 -m owner --uid-owner "$uid" -j REJECT 2>/dev/null; then echo "imdsguard: ok"; else echo "imdsguard: rule MISSING"; bad=1; fi
  if [ -e "$PENDING" ]; then echo "secrets: PENDING $(tr '\n' ';' < "$PENDING")"; bad=1; else echo "secrets: ok"; fi
  want="$(cfg .image.tag)"; run="$(running_tag)"
  if [ "$run" = "$want" ]; then echo "stack: $want running"; else echo "stack: running '${run:-nothing}', want $want"; bad=1; fi
  printf 'matchd %s: ' "$(env_get WARROOM_MATCHD_PUBLIC_URL)"; curl -fsS --max-time 5 "$(env_get WARROOM_MATCHD_PUBLIC_URL)/v1/version" || { echo "no answer"; bad=1; }; echo
  if systemctl is-active --quiet gkoi-game-lifecycle.service; then echo "lifecycle: watcher active"; else echo "lifecycle: watcher NOT active"; bad=1; fi
  exit $bad
}

# =====================================================================================================================
ORIG_ARGS=("$@")
cmd="${1:-}"; shift || true
case "$cmd" in
  apply)
    need_root
    only=""
    while [ $# -gt 0 ]; do case "$1" in --only) only="${2:-}"; shift 2 ;; *) die "unknown argument $1" ;; esac; done
    if [ -n "$only" ]; then
      for p in ${only//,/ }; do [[ " ${PHASES[*]} " == *" $p "* ]] || die "unknown phase $p (${PHASES[*]})"; done
    fi
    install -d -m 0755 "$BOX" "$STATE" "$ETC"
    say "== apply $(date -u +%FT%TZ) ${only:+(only $only)}"
    for p in "${PHASES[@]}"; do
      if [ -n "$only" ] && [[ ",$only," != *",$p,"* ]]; then continue; fi
      say "-- $p"; "phase_$p"
    done
    say "== done ($WARNINGS warnings)"
    ;;
  check) do_check ;;
  render) render_env; echo "----- matchd.json"; render_matchd ;;
  *) echo "usage: game-bootstrap.sh apply [--only P[,P…]] | check | render   (phases: ${PHASES[*]})" >&2; exit 2 ;;
esac
