#!/bin/bash
# media-lib.sh — shared by media-bootstrap.sh, roll.sh, cert-hook.sh and lifecycle-watch.sh on a GKOI media box.
# Sourced, never run. Reads the box config (/etc/gkoi-media/config.json, written from the SSM parameter) and talks
# to IMDSv2, the media agent (its loopback /drain + /healthz, through `docker exec`) and the compose project.
# shellcheck shell=bash

# shellcheck disable=SC2034  # the constants are used by the scripts that source this file
TOOL=/opt/gkoi-media
ETC=/etc/gkoi-media
RUN="$TOOL/run"
CFG="$ETC/config.json"
STATE=/var/lib/gkoi-media
PROJECT=gkoi-media
COMPOSE_FILE="$RUN/compose.yml"
PATH="/snap/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

WARNINGS=0
say()  { printf '%s: %s\n' "${GKOI_MEDIA_WHO:-gkoi-media}" "$*"; }
warn() { printf '%s: WARNING: %s\n' "${GKOI_MEDIA_WHO:-gkoi-media}" "$*" >&2; WARNINGS=$((WARNINGS + 1)); }
die()  { printf '%s: FAILED: %s\n' "${GKOI_MEDIA_WHO:-gkoi-media}" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---- tools without the snap store (2026-11-11: api.snapcraft.io unreachable from a new ap-northeast-1 box for 15+ min;
# flaky for two game boxes the same day). Snap first with three short tries, then a fallback that needs no snap.
# Pinned AWS CLI v2 zip: version + sha256 (the sha256 of the file whose PGP signature was verified against the AWS CLI
# Team key FB5D B77F D5C1 18B8 0511 ADA8 A631 0ACC 4672 475C on 2026-11-11). Bump both together.
AWSCLI_VERSION=2.39.7
AWSCLI_SHA256=707a900fde102f486d92e79f979493c747f475b9e2b94f2a42687d5d95129fb7

SNAP_STORE_DOWN=0
snap_try() { # snap ARGS… → 0 when one of three short attempts succeeds (each capped at 90 s). After three failures the
  # store counts as down for the rest of this run: later snap_try calls fail at once (no 5 minutes per tool).
  have snap || return 1
  [ "$SNAP_STORE_DOWN" -eq 0 ] || return 1
  local i
  for i in 1 2 3; do
    timeout 90 snap "$@" && return 0
    warn "snap $* failed (attempt $i/3)"
    [ "$i" -lt 3 ] && sleep $((i * 5))
  done
  SNAP_STORE_DOWN=1
  return 1
}

ensure_aws_cli() { # an `aws` that runs: as it is, else the snap, else the pinned zip into /usr/local (needs curl + unzip)
  if have aws && aws --version >/dev/null 2>&1; then return 0; fi
  if snap_try install aws-cli --classic; then hash -r; if have aws && aws --version >/dev/null 2>&1; then return 0; fi; fi
  say "aws cli: no snap — installing $AWSCLI_VERSION from awscli.amazonaws.com (sha256 pinned)"
  have unzip || die "aws cli fallback: unzip is not installed"
  local d; d="$(mktemp -d)"
  curl -fsSL --retry 3 --max-time 600 -o "$d/awscli.zip" "https://awscli.amazonaws.com/awscli-exe-linux-x86_64-$AWSCLI_VERSION.zip" \
    || { rm -rf "$d"; die "cannot download the AWS CLI $AWSCLI_VERSION"; }
  echo "$AWSCLI_SHA256  $d/awscli.zip" | sha256sum -c --quiet - || { rm -rf "$d"; die "the AWS CLI zip does not match its pinned sha256"; }
  unzip -q "$d/awscli.zip" -d "$d" || { rm -rf "$d"; die "cannot unzip the AWS CLI"; }
  "$d/aws/install" --install-dir /usr/local/aws-cli --bin-dir /usr/local/bin --update >/dev/null || { rm -rf "$d"; die "the AWS CLI installer failed"; }
  rm -rf "$d"; hash -r
  aws --version >/dev/null 2>&1 || die "the AWS CLI does not run after its install"
  say "aws cli: $(aws --version 2>&1)"
}

ssm_agent_active() { # the SSM agent of Canonical's AMI (snap) or a deb/rpm install
  systemctl is-active --quiet snap.amazon-ssm-agent.amazon-ssm-agent.service 2>/dev/null \
    || systemctl is-active --quiet amazon-ssm-agent.service 2>/dev/null
}

# certbot + the Route 53 plugin: the snap, else Ubuntu's own packages (noble universe: certbot + python3-certbot-dns-route53
# 2.9.0, renewal by certbot.timer), else a venv in /opt/certbot (renewal by gkoi-certbot-renew.timer, written here). Every
# variant reads /etc/letsencrypt and runs /etc/letsencrypt/renewal-hooks/deploy/* on a renewal (cert-hook.sh).
CERTBOT_PIP_VERSION=5.10.0 # the venv variant only (PyPI, 2026-11-11); the snap and the package bring their own
certbot_ok() { have certbot && certbot plugins --text 2>/dev/null | grep -q '^\* dns-route53'; }

certbot_kind() { # snap | apt | venv | none (what /usr/bin/certbot or the PATH's certbot is)
  if [ -x /snap/bin/certbot ] && snap list certbot >/dev/null 2>&1; then echo snap
  elif dpkg -s certbot >/dev/null 2>&1; then echo apt
  elif [ -x /opt/certbot/bin/certbot ]; then echo venv
  else echo none; fi
}

certbot_renew_timer() { # the timer that renews this box's certificates
  case "$(certbot_kind)" in
    snap) echo snap.certbot.renew.timer ;; apt) echo certbot.timer ;; venv) echo gkoi-certbot-renew.timer ;; *) echo none ;;
  esac
}

ensure_certbot() {
  certbot_ok && return 0
  if snap_try install certbot --classic; then
    [ -e /usr/bin/certbot ] || ln -s /snap/bin/certbot /usr/bin/certbot
    [ "$(snap get certbot trust-plugin-with-root 2>/dev/null)" = ok ] || snap set certbot trust-plugin-with-root=ok
    snap list certbot-dns-route53 >/dev/null 2>&1 || snap_try install certbot-dns-route53 || true
    snap connect certbot:plugin certbot-dns-route53 2>/dev/null || true
    hash -r; certbot_ok && return 0
  fi
  # A half-installed snap (certbot without its plugin) would shadow the packages below (/snap/bin is first on PATH).
  if snap list certbot >/dev/null 2>&1; then
    warn "certbot: the snap has no dns-route53 plugin — removing it for the packaged certbot"
    snap remove certbot >/dev/null 2>&1 || warn "snap remove certbot failed"
    [ -L /usr/bin/certbot ] && [ "$(readlink /usr/bin/certbot)" = /snap/bin/certbot ] && rm -f /usr/bin/certbot
  fi
  say "certbot: no snap — Ubuntu's certbot + python3-certbot-dns-route53"
  if DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 update -q \
    && DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install -yq --no-install-recommends certbot python3-certbot-dns-route53; then
    systemctl enable --now certbot.timer >/dev/null 2>&1 || warn "certbot.timer not enabled"
    hash -r; certbot_ok && return 0
  fi
  say "certbot: no package — a venv in /opt/certbot (PyPI)"
  DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install -yq --no-install-recommends python3-venv \
    || die "certbot: apt-get install python3-venv failed"
  [ -x /opt/certbot/bin/python ] || python3 -m venv /opt/certbot || die "certbot: python3 -m venv failed"
  /opt/certbot/bin/pip install -q "certbot==$CERTBOT_PIP_VERSION" "certbot-dns-route53==$CERTBOT_PIP_VERSION" || die "certbot: pip install failed"
  ln -sfn /opt/certbot/bin/certbot /usr/local/bin/certbot
  write_certbot_venv_timer
  hash -r; certbot_ok || die "certbot: no variant with the dns-route53 plugin works"
}

write_certbot_venv_timer() { # the snap / the package bring their own timer; the venv gets this one (twice a day, as theirs)
  local u=/etc/systemd/system/gkoi-certbot-renew
  printf '%s\n' '[Unit]' 'Description=certbot renew (the /opt/certbot venv; GKOI box)' '[Service]' 'Type=oneshot' \
    'ExecStart=/opt/certbot/bin/certbot -q renew' > "$u.service.new"
  printf '%s\n' '[Unit]' 'Description=certbot renew twice a day (the /opt/certbot venv; GKOI box)' '[Timer]' \
    'OnCalendar=*-*-* 00,12:00:00' 'RandomizedDelaySec=43200' 'Persistent=true' '[Install]' 'WantedBy=timers.target' > "$u.timer.new"
  mv "$u.service.new" "$u.service"; mv "$u.timer.new" "$u.timer"
  systemctl daemon-reload || warn "systemctl daemon-reload failed"
  systemctl enable --now gkoi-certbot-renew.timer >/dev/null 2>&1 || warn "gkoi-certbot-renew.timer not enabled"
}

# ---- the config ----------------------------------------------------------------------------------------------
cfg() { jq -er "$1" "$CFG"; }            # a required value (fails on null / missing)
cfg_or() { jq -r "($1) // \"$2\"" "$CFG"; } # with a default

# ---- IMDSv2 ----------------------------------------------------------------------------------------------------
IMDS=http://169.254.169.254/latest
imds_token() { curl -fsS --max-time 2 -X PUT "$IMDS/api/token" -H 'X-aws-ec2-metadata-token-ttl-seconds: 120' 2>/dev/null; }
imds() { local t; t="$(imds_token)" || return 1; curl -fsS --max-time 2 -H "X-aws-ec2-metadata-token: $t" "$IMDS/$1" 2>/dev/null; }
instance_id() { imds meta-data/instance-id; }
private_ip() { imds meta-data/local-ipv4; }
public_ip() { imds meta-data/public-ipv4 || true; }
own_region() { imds meta-data/placement/region; }

# The box id in the engine's pool registry (MEDIA_BOX_ID, ≤ 48 of [A-Za-z0-9._-]): <slug>-<instance id without "i-">.
# One per INSTANCE on purpose: a replacement box never inherits a departed box's pool ids (the engine re-claims or ends
# that box's sessions — SPEC-PLATFORM-AWS-READY-V1 A2/A4), and the relay queue relay-box-<id> is the box's own.
box_id() { local iid; iid="$(instance_id)" || return 1; printf '%s-%s' "$(cfg .key)" "${iid#i-}"; }

# ---- the compose project ----------------------------------------------------------------------------------------
compose() { docker compose -p "$PROJECT" -f "$COMPOSE_FILE" "$@"; }
container_of() { docker ps -q --filter "label=com.docker.compose.project=$PROJECT" --filter "label=com.docker.compose.service=$1" | head -1; }

# The agent's loopback endpoint (media-agent/src/health.ts): GET|POST|DELETE /drain → {box,draining,idle,sessions,recordings,builds}
agent_call() { # METHOD PATH → body on stdout; non-zero when the agent is not running or answers non-2xx
  local c; c="$(container_of media-agent)"; [ -n "$c" ] || return 1
  docker exec "$c" node -e "fetch('http://127.0.0.1:3002'+process.argv[2],{method:process.argv[1]}).then(async r=>{process.stdout.write(await r.text());process.exit(r.ok?0:1)}).catch(()=>process.exit(1))" "$1" "$2"
}

# 0 = the box holds nothing (no agent running, or the agent reports idle); 1 = busy (sessions / recordings / builds).
box_idle() {
  local c body; c="$(container_of media-agent)"
  [ -n "$c" ] || return 0
  body="$(agent_call GET /drain)" || { warn "the media agent does not answer /drain: treating the box as BUSY"; return 1; }
  [ "$(printf '%s' "$body" | jq -r '.idle')" = true ]
}

box_report() { agent_call GET /drain 2>/dev/null || printf '{"agent":"not running"}'; }
