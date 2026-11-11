#!/bin/bash
# media-bootstrap.sh — make an Ubuntu 24.04 EC2 instance a GKOI media box (envs/prod2/media; PLAN-AWS-MIGRATION-PROD2-V1
# P5), modelled on ops/warroom-game/bootstrap.sh. Idempotent: every phase looks first and changes only what differs, so
# the same command serves a fresh ASG instance (user-data), an existing box (by hand over SSM) and roll.sh.
#
#   media-bootstrap.sh apply [--only P[,P…]]   as root: run the phases in order (default: all)
#   media-bootstrap.sh check                   read-only: is this box set up and serving? exit 0 = yes, 1 = something is not
#   media-bootstrap.sh render                  print the compose file it would run (secrets are in env files, never printed)
#
# The phases, in order:
#   packages   apt basics, Docker CE + compose (key fingerprint pinned), the AWS CLI (snap), certbot + dns-route53 (snap),
#              UTC, chrony on the Amazon Time Sync Service; the SSM agent (snap, preinstalled on Canonical's AMI) running
#   config     the SSM parameter → /etc/gkoi-media/config.json; the box bundle (every file sha256-checked; a changed
#              media-bootstrap.sh re-executes itself); the engine release's own config files (pool.yml, the pool and
#              media-origin entrypoints, the origin template) out of its source.zip, checked against releases/mikaido.json
#   eip        the region's Elastic IP onto THIS instance (refused while another instance holds it, unless
#              GKOI_MEDIA_TAKE_EIP=1) — before anything registers: the stream host resolves to it
#   sysctl     /etc/sysctl.d/90-gkoi-media.conf: the live box's tuning (conntrack, neighbour table, swappiness,
#              max_map_count) + the UDP socket buffer ceilings for WebRTC ICE
#   docker     /etc/docker/daemon.json (json-file logs, rotated; live-restore so a dockerd restart keeps the streams)
#   cloudwatch the CloudWatch agent (package signature checked against the pinned key): container logs, syslog, this log,
#              certbot → /gkoi/prod2/media/<key>/*; cpu / mem / disk / net → GKOI/Media by AutoScalingGroupName
#   certs      Let's Encrypt by DNS-01 through Route 53 with the INSTANCE ROLE, one lineage per name in cert_hosts
#              (/etc/letsencrypt/live/<host>/ — the pools' RTMPS and the media origin read exactly that path); the
#              deploy hook (cert-hook.sh) + the hourly retry timer for a pool restart deferred by live sessions
#   env        the secrets (Secrets Manager, us-west-2) → /etc/gkoi-media/{agent,pool,origin}.env (0600, root); the
#              box-local resolver secret (generated once); MEDIA_BOX_ID + MEDIA_BOX_INSTANCES from IMDS
#   compose    the compose file → /opt/gkoi-media/run/compose.yml; ECR login; pull by digest; up -d; wait healthy.
#              REFUSED while the box holds sessions / recordings / builds unless GKOI_MEDIA_FORCE=1 (roll.sh drains first)
#   lifecycle  gkoi-media-lifecycle.service (lifecycle-watch.sh: the ASG terminate hook → drain → complete)
#
# Nothing here prints a secret. Logs: /var/log/gkoi-media-bootstrap.log (user-data) → CloudWatch …/bootstrap.
set -euo pipefail
GKOI_MEDIA_WHO=media-bootstrap
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=media-lib.sh
. "$HERE/media-lib.sh"

PHASES=(packages config eip sysctl docker cloudwatch certs env compose lifecycle)
DOCKER_KEY_FPR=9DC858229FC7DD38854AE2D88D81803C0EBFCD88
CWAGENT_KEY_FPR=937616F3450B7D806CBD9725D58167303B789C72
CW_CTL=/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl
CW_CONF=/opt/aws/amazon-cloudwatch-agent/etc/gkoi-media.json
SYSCTL_CONF=/etc/sysctl.d/90-gkoi-media.conf
# (every apt-get waits up to 10 min for the dpkg lock: unattended-upgrades also runs at first boot)
APT_PKGS=(ca-certificates curl gnupg jq unzip chrony rsync openssl unattended-upgrades)
ENGINE_FILES=(infra/mediamtx/pool.yml infra/mediamtx/pool-entrypoint.sh infra/nginx/media-live-origin-entrypoint.sh infra/nginx/media-live-origin.conf.template)

install_if_changed() { # src dst mode → 0 = written, 1 = unchanged
  if [ -e "$2" ] && cmp -s "$1" "$2"; then return 1; fi
  install -D -m "$3" -o root -g root "$1" "$2" || die "cannot install $2"
  say "wrote $2"; return 0
}

need_root() { [ "$(id -u)" -eq 0 ] || die "run as root (sudo / SSM)"; }
write_file() { # MODE DST < content → 0 = written, 1 = unchanged
  local tmp rc=1; tmp="$(mktemp)"; cat > "$tmp"
  install_if_changed "$tmp" "$2" "$1" && rc=0
  rm -f "$tmp"; return $rc
}

# =====================================================================================================================
phase_packages() {
  local missing=() p
  for p in "${APT_PKGS[@]}"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
  if [ ${#missing[@]} -gt 0 ]; then
    say "apt: installing ${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 update -q || die "apt-get update failed"
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install -yq --no-install-recommends "${missing[@]}" || die "apt-get install failed"
  fi

  if ! docker compose version >/dev/null 2>&1; then
    local k=/etc/apt/keyrings/docker.asc tmp fpr codename
    tmp="$(mktemp)"; curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$tmp" || die "cannot fetch Docker's apt key"
    fpr="$(gpg --show-keys --with-colons "$tmp" 2>/dev/null | awk -F: '$1=="fpr"{print $10; exit}')"
    [ "$fpr" = "$DOCKER_KEY_FPR" ] || { rm -f "$tmp"; die "Docker's apt key fingerprint is '$fpr', not the pinned $DOCKER_KEY_FPR"; }
    install -D -m 0644 "$tmp" "$k" && rm -f "$tmp"
    # shellcheck disable=SC1091
    codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
    printf 'deb [arch=%s signed-by=%s] https://download.docker.com/linux/ubuntu %s stable\n' \
      "$(dpkg --print-architecture)" "$k" "$codename" > /etc/apt/sources.list.d/docker.list
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 update -q || die "apt-get update (docker) failed"
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install -yq docker-ce docker-ce-cli containerd.io docker-compose-plugin \
      || die "Docker install failed"
    systemctl enable --now docker.service || die "cannot start docker"
  fi
  say "docker: $(docker --version) + compose $(docker compose version --short)"

  have snap || die "no snapd (the AWS CLI, certbot and the SSM agent come from snaps)"
  have aws || { snap install aws-cli --classic || die "snap install aws-cli failed"; }
  snap list certbot >/dev/null 2>&1 || { snap install certbot --classic || die "snap install certbot failed"; }
  [ -e /usr/bin/certbot ] || ln -s /snap/bin/certbot /usr/bin/certbot
  [ "$(snap get certbot trust-plugin-with-root 2>/dev/null)" = ok ] || snap set certbot trust-plugin-with-root=ok
  snap list certbot-dns-route53 >/dev/null 2>&1 || { snap install certbot-dns-route53 || die "snap install certbot-dns-route53 failed"; }
  snap connect certbot:plugin certbot-dns-route53 2>/dev/null || true
  snap list amazon-ssm-agent >/dev/null 2>&1 || { snap install amazon-ssm-agent --classic || die "snap install amazon-ssm-agent failed"; }
  systemctl is-active --quiet snap.amazon-ssm-agent.amazon-ssm-agent.service \
    || { snap start --enable amazon-ssm-agent || die "cannot start the SSM agent"; }

  [ "$(timedatectl show -p Timezone --value 2>/dev/null)" = UTC ] || timedatectl set-timezone UTC
  local tmp; tmp="$(mktemp)"
  printf '# Written by media-bootstrap.sh: the Amazon Time Sync Service (link-local, every EC2 instance)\nserver 169.254.169.123 prefer iburst minpoll 4 maxpoll 4\n' > "$tmp"
  if install_if_changed "$tmp" /etc/chrony/sources.d/amazon-time-sync.sources 0644; then
    systemctl restart chrony.service || warn "chrony did not restart"
  fi
  rm -f "$tmp"
  systemctl enable --now unattended-upgrades.service >/dev/null 2>&1 || warn "unattended-upgrades not enabled"
}

# =====================================================================================================================
phase_config() {
  local region key param tmp
  region="$(own_region)" || die "no region from IMDS"
  key="$(cfg .key)" || die "no key in $CFG (the user-data writes the first copy)"
  param="/gkoi/prod2/media/$key/config"
  tmp="$(mktemp)"
  aws ssm get-parameter --region "$region" --name "$param" --query Parameter.Value --output text > "$tmp" \
    || { rm -f "$tmp"; die "cannot read $param"; }
  jq -e '.v == 1 and (.key | type == "string")' "$tmp" >/dev/null || { rm -f "$tmp"; die "$param is not a v1 media box config"; }
  install_if_changed "$tmp" "$CFG" 0644 || say "config: $param unchanged"
  rm -f "$tmp"

  # The box bundle: download what differs, check, install. A changed media-bootstrap.sh re-executes the run.
  local bucket bregion prefix f sha self_changed=0 have_sha
  bucket="$(cfg .bundle.bucket)"; bregion="$(cfg .bundle.region)"; prefix="$(cfg .bundle.prefix)"
  while read -r f sha; do
    [[ "$f" =~ ^[A-Za-z0-9._-]+$ ]] || die "bundle file name '$f' is not plain"
    have_sha="$( [ -f "$TOOL/$f" ] && sha256sum "$TOOL/$f" | cut -d' ' -f1 || true)"
    [ "$have_sha" = "$sha" ] && continue
    aws s3 cp --only-show-errors --region "$bregion" "s3://$bucket/$prefix$f" "$TOOL/$f.new" || die "cannot download $prefix$f"
    echo "$sha  $TOOL/$f.new" | sha256sum -c --quiet - || { rm -f "$TOOL/$f.new"; die "$f: sha256 mismatch"; }
    case "$f" in *.sh) chmod 0755 "$TOOL/$f.new" ;; *) chmod 0644 "$TOOL/$f.new" ;; esac
    mv "$TOOL/$f.new" "$TOOL/$f"
    say "bundle: $f updated"
    [ "$f" = media-bootstrap.sh ] && self_changed=1
  done < <(jq -r '.bundle.files | to_entries[] | "\(.key) \(.value)"' "$CFG")
  if [ $self_changed -eq 1 ] && [ -z "${GKOI_MEDIA_REEXEC:-}" ]; then
    say "bundle: media-bootstrap.sh changed — re-executing"
    GKOI_MEDIA_REEXEC=1 exec "$TOOL/media-bootstrap.sh" "${ORIG_ARGS[@]}"
  fi

  # The engine release's config files (compose.engine.yml bind-mounts them from the repo; here: from its source.zip).
  local tag uri want dir zip got p
  tag="$(cfg .engine_source.tag)"; uri="$(cfg .engine_source.s3_uri)"; want="$(cfg .engine_source.sha256)"
  [[ "$tag" =~ ^[A-Za-z0-9._-]+$ ]] || die "engine tag '$tag' is not plain"
  dir="$TOOL/engine/$tag"
  if [ ! -f "$dir/.ok" ]; then
    zip="$(mktemp --suffix .zip)"
    aws s3 cp --only-show-errors --region us-west-2 "$uri" "$zip" || { rm -f "$zip"; die "cannot download $uri"; }
    got="$(sha256sum "$zip" | cut -d' ' -f1)"
    [ "$got" = "$want" ] || { rm -f "$zip"; die "engine source.zip sha256 is $got, releases/mikaido.json says $want"; }
    rm -rf "$dir.tmp"; mkdir -p "$dir.tmp"
    unzip -q "$zip" "${ENGINE_FILES[@]}" -d "$dir.tmp" || { rm -f "$zip"; die "source.zip lacks one of: ${ENGINE_FILES[*]}"; }
    rm -f "$zip"
    for p in "${ENGINE_FILES[@]}"; do [ -s "$dir.tmp/$p" ] || die "engine file $p is empty"; done
    chmod -R a+rX "$dir.tmp"; touch "$dir.tmp/.ok"
    rm -rf "$dir"; mv "$dir.tmp" "$dir"
    say "engine: $tag config files from $uri (sha256 ok)"
  fi
  ln -sfn "$dir" "$TOOL/engine/current"
}

# =====================================================================================================================
phase_eip() {
  local alloc want iid region assoc_iid
  alloc="$(cfg .eip_allocation_id)"; want="$(cfg .eip_public_ip)"
  iid="$(instance_id)" || die "no instance id from IMDS"; region="$(own_region)"
  if [ "$(public_ip)" = "$want" ]; then say "eip: $want is this box's"; return 0; fi
  assoc_iid="$(aws ec2 describe-addresses --region "$region" --allocation-ids "$alloc" --query 'Addresses[0].InstanceId' --output text 2>/dev/null || true)"
  if [ -n "$assoc_iid" ] && [ "$assoc_iid" != None ] && [ "$assoc_iid" != "$iid" ] && [ "${GKOI_MEDIA_TAKE_EIP:-}" != 1 ]; then
    die "eip: $want is held by $assoc_iid (a live box?). Drain + stop that box, or re-run with GKOI_MEDIA_TAKE_EIP=1"
  fi
  aws ec2 associate-address --region "$region" --allocation-id "$alloc" --instance-id "$iid" --allow-reassociation >/dev/null \
    || die "eip: associate-address failed"
  local i; for i in $(seq 1 30); do [ "$(public_ip)" = "$want" ] && break; sleep 2; done
  [ "$(public_ip)" = "$want" ] || warn "eip: associated, but IMDS still shows $(public_ip)"
  say "eip: $want → $iid"
}

# =====================================================================================================================
sysctl_render() {
  local udp; udp="$(cfg_or .udp_buffer_bytes 4194304)"
  [[ "$udp" =~ ^[1-9][0-9]*$ ]] || die "udp_buffer_bytes '$udp' is not a positive integer"
  cat <<EOF
# Written by media-bootstrap.sh (phase sysctl). Do not edit: change the stack, re-apply.
# The live Lightsail media box's tuning (2026-11-11) + the UDP ceilings for WebRTC ICE.
net.netfilter.nf_conntrack_max = 1048576
net.ipv4.neigh.default.gc_thresh2 = 15360
net.ipv4.neigh.default.gc_thresh3 = 16384
vm.swappiness = 10
vm.max_map_count = 1048576
net.core.somaxconn = 4096
net.core.rmem_max = $udp
net.core.wmem_max = $udp
EOF
}

phase_sysctl() {
  local tmp kv k v got drift=""
  modprobe nf_conntrack 2>/dev/null || warn "nf_conntrack not loaded (Docker loads it; the conntrack line applies then)"
  printf 'nf_conntrack\n' > /etc/modules-load.d/gkoi-media.conf
  tmp="$(mktemp)"; sysctl_render > "$tmp"
  install_if_changed "$tmp" "$SYSCTL_CONF" 0644 || true
  rm -f "$tmp"
  sysctl --system >/dev/null 2>&1 || warn "sysctl --system reported an error"
  while IFS= read -r kv; do
    case "$kv" in ''|'#'*) continue ;; esac
    k="${kv%% =*}"; v="${kv##*= }"
    got="$(sysctl -n "$k" 2>/dev/null || echo '?')"
    [ "$got" = "$v" ] || drift+=" $k=$got(want $v)"
  done < "$SYSCTL_CONF"
  if [ -z "$drift" ]; then say "sysctl: live"; else warn "sysctl: not live:$drift"; fi
}

# =====================================================================================================================
phase_docker() {
  local tmp; tmp="$(mktemp)"
  cat > "$tmp" <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "50m", "max-file": "5" },
  "live-restore": true
}
EOF
  if install_if_changed "$tmp" /etc/docker/daemon.json 0644; then
    if [ -z "$(docker ps -q)" ]; then
      systemctl restart docker.service || die "docker did not restart with daemon.json"
    else # live containers: a reload (SIGHUP) takes live-restore + the log defaults for NEW containers, drops nothing
      systemctl reload docker.service || die "docker did not reload daemon.json"
    fi
  fi
  rm -f "$tmp"
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
  local tmp ns prefix changed=1 s
  ns="$(cfg .cw.namespace)"; prefix="$(cfg .cw.log_prefix)"
  tmp="$(mktemp)"
  s="$(cat "$TOOL/cloudwatch-agent.json.tmpl")"; s="${s//@@CW_NAMESPACE@@/$ns}"; s="${s//@@CW_LOG_PREFIX@@/$prefix}"
  printf '%s\n' "$s" > "$tmp"
  jq -e . "$tmp" >/dev/null || { rm -f "$tmp"; die "the rendered CloudWatch config is not JSON"; }
  install_if_changed "$tmp" "$CW_CONF" 0644 && changed=0; rm -f "$tmp"
  if [ $changed -eq 0 ] || ! systemctl is-active --quiet amazon-cloudwatch-agent.service; then
    "$CW_CTL" -a fetch-config -m ec2 -s -c "file:$CW_CONF" >/dev/null || die "the CloudWatch agent did not take $CW_CONF"
    say "cloudwatch: agent (re)started"
  fi
}

# =====================================================================================================================
phase_certs() {
  local h email staging args=()
  [ ! -e /root/.aws/credentials ] || die "certs: /root/.aws/credentials exists — the DNS-01 must use the instance role, never static keys"
  email="$(cfg_or .acme.email '')"; staging="$(cfg_or .acme.staging false)"
  if [ -n "$email" ]; then args+=(--email "$email"); else args+=(--register-unsafely-without-email); fi
  [ "$staging" = true ] && args+=(--staging)
  while read -r h; do
    [[ "$h" =~ ^[a-z0-9-]+(\.[a-z0-9-]+)+$ ]] || die "cert host '$h' is not a DNS name"
    if [ -s "/etc/letsencrypt/live/$h/fullchain.pem" ]; then continue; fi
    say "certs: issuing $h (DNS-01, Route 53, the instance role)"
    certbot certonly --non-interactive --agree-tos --dns-route53 --key-type ecdsa \
      --cert-name "$h" -d "$h" "${args[@]}" >/dev/null || die "certbot could not issue $h (see /var/log/letsencrypt/letsencrypt.log)"
  done < <(jq -r '.cert_hosts[]' "$CFG")
  write_file 0755 /etc/letsencrypt/renewal-hooks/deploy/gkoi-media <<EOF || true
#!/bin/sh
# Written by media-bootstrap.sh (phase certs): reload / restart what reads the renewed lineage.
exec $TOOL/cert-hook.sh
EOF
  write_file 0644 /etc/systemd/system/gkoi-media-cert-retry.service <<EOF || true
[Unit]
Description=GKOI media: finish a pool restart a cert renewal deferred (live sessions)
ConditionPathExists=$STATE/pool-cert.pending
[Service]
Type=oneshot
ExecStart=$TOOL/cert-hook.sh --pending
EOF
  write_file 0644 /etc/systemd/system/gkoi-media-cert-retry.timer <<'EOF' || true
[Unit]
Description=GKOI media: hourly retry of a deferred pool cert restart
[Timer]
OnCalendar=hourly
RandomizedDelaySec=300
Persistent=true
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now gkoi-media-cert-retry.timer >/dev/null 2>&1 || warn "cert retry timer not enabled"
  systemctl is-enabled --quiet snap.certbot.renew.timer 2>/dev/null || warn "certbot's renew timer is not enabled"
  say "certs: $(jq -r '.cert_hosts | join(", ")' "$CFG")"
}

# =====================================================================================================================
# A value written into an env file: single-quoted (compose takes it literally), so it may not hold ' or a newline.
env_line() { # NAME VALUE
  case "$2" in *"'"*|*$'\n'*|*$'\r'*) die "env: $1 holds a quote or a newline — refused (the value is not printed)" ;; esac
  [ -n "$2" ] || die "env: $1 is empty"
  printf "%s='%s'\n" "$1" "$2"
}

secret() { # ENV_NAME → the value (never printed by the caller)
  local arn region v jkey
  arn="$(cfg ".secrets.\"$1\"")" || die "env: no secret ARN for $1 in the config"
  region="$(cfg .secrets_region)"
  v="$(aws secretsmanager get-secret-value --region "$region" --secret-id "$arn" --query SecretString --output text 2>/dev/null)" \
    || die "env: cannot read the secret for $1 (does it have a value? the role's grant?)"
  if [ "$1" = MEDIA_ORIGIN_VERIFY_SECRET ]; then
    jkey="$(cfg_or .origin_verify_json_key '')"
    if [ -n "$jkey" ]; then v="$(printf '%s' "$v" | jq -er --arg k "$jkey" '.[$k]')" || die "env: $1 has no JSON key '$jkey'"; fi
  fi
  printf '%s' "$v"
}

box_instances_json() { # → MEDIA_BOX_INSTANCES (the pools THIS box runs; the engine reads every field from the registry)
  local box ip
  box="$(box_id)" || die "no instance id"; ip="$(private_ip)" || die "no private ip"
  jq -c --arg box "$box" --arg ip "$ip" '
    [ range(0; .pool_count) as $i
      | (($i + 1) * 10000) as $b
      | { id: "\($box)-p\($i)", region: .region, label: .label,
          controlBaseUrl: "http://mk-pool-\($i):9997", internalHost: "mk-pool-\($i)",
          publicHost: .stream_host, publicRtmpPort: ($b + 1935), publicRtmpsPort: ($b + 1936),
          apiHost: $ip, apiHlsPort: ($b + 8888), apiWhipPort: ($b + 8889),
          apiControlBaseUrl: "http://\($ip):\($b + 9997)", liveOriginBase: .live_origin_base } ]' "$CFG"
}

phase_env() {
  install -d -m 0700 "$ETC" "$STATE"
  [ -s "$ETC/resolver.secret" ] || { umask 077; openssl rand -hex 32 > "$ETC/resolver.secret"; }
  chmod 0600 "$ETC/resolver.secret"
  local resolver redis relay apipass readsec preview verify user tmp
  resolver="$(cat "$ETC/resolver.secret")"
  redis="$(secret REDIS_URL)"; relay="$(secret RELAY_SHARED_SECRET)"; apipass="$(secret MK_POOL_API_PASS)"
  readsec="$(secret MK_POOL_READ_SECRET)"; preview="$(secret PREVIEW_TOKEN_KEY)"; verify="$(secret MEDIA_ORIGIN_VERIFY_SECRET)"
  user="$(cfg .agent_env.MK_POOL_API_USER)"
  case "$redis" in rediss://*) ;; *) die "env: REDIS_URL is not a rediss:// URL (Valkey is TLS-only)" ;; esac

  umask 077
  tmp="$(mktemp)"
  {
    echo "# Written by media-bootstrap.sh (phase env). Secrets: do not copy, do not print."
    jq -r '.agent_env | to_entries[] | "\(.key)\t\(.value)"' "$CFG" | while IFS=$'\t' read -r k v; do env_line "$k" "$v"; done
    env_line RELAYD_REGION "$(cfg .region)"
    env_line MEDIA_BOX_ID "$(box_id)"
    env_line MEDIA_BOX_INSTANCES "$(box_instances_json)"
    env_line PORTAL_INTERNAL_URL "$(cfg .portal_internal_url)"
    env_line REDIS_URL "$redis"
    env_line RELAY_SHARED_SECRET "$relay"
    env_line MK_POOL_API_PASS "$apipass"
    env_line MK_POOL_READ_SECRET "$readsec"
    env_line PREVIEW_TOKEN_KEY "$preview"
    env_line RELAYD_RESOLVER_SECRET "$resolver"
  } > "$tmp"
  install_if_changed "$tmp" "$ETC/agent.env" 0600 || true
  {
    echo "# Written by media-bootstrap.sh (phase env): the pools' own env (never the agent's — media-pool audit #3)."
    env_line RELAY_SHARED_SECRET "$relay"
    env_line MK_POOL_API_USER "$user"
    env_line MK_POOL_API_PASS "$apipass"
    env_line MK_POOL_READ_SECRET "$readsec"
    env_line MK_POOL_REQUIRE_AUTH 1
  } > "$tmp"
  install_if_changed "$tmp" "$ETC/pool.env" 0600 || true
  {
    echo "# Written by media-bootstrap.sh (phase env): the media origin's three secrets."
    env_line MEDIA_ORIGIN_VERIFY_SECRET "$verify"
    env_line RELAYD_RESOLVER_SECRET "$resolver"
    env_line MK_POOL_READ_SECRET "$readsec"
  } > "$tmp"
  install_if_changed "$tmp" "$ETC/origin.env" 0600 || true
  rm -f "$tmp"; umask 022
  unset redis relay apipass readsec preview verify resolver
  say "env: agent.env, pool.env, origin.env (box $(box_id), $(cfg .pool_count) pools, api $(cfg .portal_internal_url))"
}

# =====================================================================================================================
compose_render() {
  local agent mtx origin stream origin_host slug ip url n i b pools="" eng
  agent="$(cfg '.images["media-agent"]')"; mtx="$(cfg .images.mediamtx)"; origin="$(cfg '.images["media-origin"]')"
  stream="$(cfg .stream_host)"; origin_host="$(cfg .origin_host)"; slug="$(cfg .key)"
  ip="$(private_ip)" || die "no private ip"; url="$(cfg .portal_internal_url)"; n="$(cfg .pool_count)"
  eng="$TOOL/engine/current"
  for ((i = 0; i < n; i++)); do pools+="mk-pool-$i "; done
  cat <<EOF
# Written by media-bootstrap.sh (phase compose) — do not edit: change the stack, then roll.sh.
# The live box's compose.media.yml + compose.pool-rtmps.yml + the media-origin profile, flattened, images by digest.
name: $PROJECT
services:
  media-agent:
    image: $agent
    restart: unless-stopped
    env_file: [$ETC/agent.env]
    environment:
      MEDIA_AGENT_IMAGE: "$agent"
    volumes:
      - mk-pool-recordings:/recordings
    healthcheck:
      test: ["CMD", "node", "-e", "fetch('http://127.0.0.1:3002/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]
      interval: 10s
      timeout: 5s
      retries: 6
      start_period: 30s
    stop_grace_period: 45s
EOF
  for ((i = 0; i < n; i++)); do
    b=$(((i + 1) * 10000))
    cat <<EOF
  mk-pool-$i:
    image: $mtx
    restart: unless-stopped
    env_file: [$ETC/pool.env]
    entrypoint: ["/bin/sh", "/etc/mediamtx/pool-entrypoint.sh"]
    environment:
      MTX_WEBRTCLOCALUDPADDRESS: ":$((8189 + 100 * i))"
      MTX_WEBRTCADDITIONALHOSTS: "$stream"
      POOL_ID: "$(box_id)-p$i"
      PORTAL_INTERNAL_URL: "$url"
      MK_POOL_REQUIRE_AUTH: "1"
      MTX_RTMPENCRYPTION: "optional"
      MTX_RTMPSADDRESS: ":1936"
      MTX_RTMPSERVERCERT: "/etc/letsencrypt/live/$stream/fullchain.pem"
      MTX_RTMPSERVERKEY: "/etc/letsencrypt/live/$stream/privkey.pem"
    ports:
      - "$((b + 1935)):1935"
      - "$((b + 1936)):1936"
      - "$((8189 + 100 * i)):$((8189 + 100 * i))/udp"
      - "$ip:$((b + 8889)):8889"
      - "$ip:$((b + 8888)):8888"
      - "$ip:$((b + 9997)):9997"
    volumes:
      - $eng/infra/mediamtx/pool.yml:/etc/mediamtx/pool.yml:ro
      - $eng/infra/mediamtx/pool-entrypoint.sh:/etc/mediamtx/pool-entrypoint.sh:ro
      - mk-pool-recordings:/recordings
      - /etc/letsencrypt:/etc/letsencrypt:ro
    healthcheck:
      test: ["CMD", "curl", "-sf", "-o", "/dev/null", "http://127.0.0.1:9997/v3/paths/list"]
      interval: 10s
      timeout: 5s
      retries: 6
      start_period: 10s
EOF
  done
  cat <<EOF
  media-origin:
    image: $origin
    restart: unless-stopped
    entrypoint: ["/bin/sh", "/media-origin/entrypoint.sh"]
    env_file: [$ETC/origin.env]
    environment:
      MEDIA_ORIGIN_SLUG: "$slug"
      MEDIA_ORIGIN_TLS: "on"
      MEDIA_ORIGIN_HOST: "$origin_host"
      MEDIA_ORIGIN_VERIFY: "on"
      MEDIA_ORIGIN_POOLS: "${pools% }"
      MEDIA_ORIGIN_RESOLVER: "media-agent:3003"
      MEDIA_ORIGIN_MAX_CONNS_PER_VIEWER: "$(cfg_or .origin_max_conns_per_viewer 100)"
      MEDIA_ORIGIN_CORS_ORIGINS: ""
    ports:
      - "443:8443"
    volumes:
      - $eng/infra/nginx/media-live-origin-entrypoint.sh:/media-origin/entrypoint.sh:ro
      - $eng/infra/nginx/media-live-origin.conf.template:/media-origin/media-live-origin.conf.template:ro
      - /etc/letsencrypt:/etc/letsencrypt:ro
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
    stop_grace_period: 35s
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:8081/healthz"]
      interval: 10s
      timeout: 5s
      retries: 6
volumes:
  mk-pool-recordings:
EOF
}

phase_compose() {
  install -d -m 0755 "$RUN"
  local tmp registry region
  tmp="$(mktemp)"; compose_render > "$tmp"
  docker compose -p "$PROJECT" -f "$tmp" config -q || { rm -f "$tmp"; die "compose: the rendered file does not validate"; }
  if ! box_idle && [ "${GKOI_MEDIA_FORCE:-}" != 1 ]; then
    rm -f "$tmp"
    die "compose: the box holds live work ($(box_report)) — roll.sh drains first (or GKOI_MEDIA_FORCE=1 cuts every stream)"
  fi
  install_if_changed "$tmp" "$COMPOSE_FILE" 0644 || true
  rm -f "$tmp"
  registry="$(cfg .ecr_registry)"; region="$(own_region)"
  aws ecr get-login-password --region "$region" | docker login --username AWS --password-stdin "$registry" >/dev/null \
    || die "compose: ECR login to $registry failed"
  compose pull --quiet || die "compose: pull failed"
  compose up -d --remove-orphans || die "compose: up failed"
  local i unhealthy s c
  for i in $(seq 1 36); do
    unhealthy=""
    for s in $(compose config --services); do
      c="$(container_of "$s")"
      [ -n "$c" ] || { unhealthy+=" $s(missing)"; continue; }
      [ "$(docker inspect -f '{{.State.Health.Status}}' "$c" 2>/dev/null)" = healthy ] || unhealthy+=" $s"
    done
    [ -z "$unhealthy" ] && break
    sleep 5
  done
  [ -z "$unhealthy" ] || die "compose: not healthy after 3 minutes:$unhealthy (docker logs <container>)"
  say "compose: up and healthy — $(box_report)"
}

# =====================================================================================================================
phase_lifecycle() {
  write_file 0644 /etc/systemd/system/gkoi-media-lifecycle.service <<EOF || true
[Unit]
Description=GKOI media: the ASG terminate hook (drain, wait for idle, let go)
After=docker.service network-online.target
Wants=network-online.target
[Service]
ExecStart=$TOOL/lifecycle-watch.sh
Restart=always
RestartSec=15
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now gkoi-media-lifecycle.service >/dev/null 2>&1 || die "lifecycle: the watcher did not start"
  systemctl try-restart gkoi-media-lifecycle.service >/dev/null 2>&1 || true
  say "lifecycle: watcher running"
}

# =====================================================================================================================
do_check() {
  local bad=0 h s c end
  [ -f "$CFG" ] || { echo "no $CFG"; exit 1; }
  echo "box $(box_id 2>/dev/null || echo '?') key $(cfg .key) region $(cfg .region) engine $(cfg .engine_source.tag)"
  if [ "$(public_ip)" = "$(cfg .eip_public_ip)" ]; then echo "eip: ok $(cfg .eip_public_ip)"; else echo "eip: NOT on this box"; bad=1; fi
  while read -r h; do
    if end="$(openssl x509 -enddate -noout -in "/etc/letsencrypt/live/$h/fullchain.pem" 2>/dev/null)"; then
      echo "cert: $h until ${end#*=}"
    else echo "cert: $h MISSING"; bad=1; fi
  done < <(jq -r '.cert_hosts[]' "$CFG")
  for f in agent.env pool.env origin.env; do
    if [ -s "$ETC/$f" ]; then echo "env: $f present"; else echo "env: $f MISSING"; bad=1; fi
  done
  if [ -f "$COMPOSE_FILE" ]; then
    for s in $(compose config --services 2>/dev/null); do
      c="$(container_of "$s")"
      if [ -z "$c" ]; then echo "container: $s NOT running"; bad=1; continue; fi
      echo "container: $s $(docker inspect -f '{{.State.Health.Status}} {{.Config.Image}}' "$c")"
      [ "$(docker inspect -f '{{.State.Health.Status}}' "$c")" = healthy ] || bad=1
    done
  else echo "compose: not rendered yet"; bad=1; fi
  echo "agent: $(box_report)"
  if systemctl is-active --quiet gkoi-media-lifecycle.service; then echo "lifecycle: watcher active"; else echo "lifecycle: watcher NOT active"; bad=1; fi
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
    install -d -m 0755 "$TOOL" "$STATE"
    say "== apply $(date -u +%FT%TZ) ${only:+(only $only)}"
    for p in "${PHASES[@]}"; do
      if [ -n "$only" ] && [[ ",$only," != *",$p,"* ]]; then continue; fi
      say "-- $p"; "phase_$p"
    done
    say "== done ($WARNINGS warnings)"
    ;;
  check) do_check ;;
  render) compose_render ;;
  *) echo "usage: media-bootstrap.sh apply [--only P[,P…]] | check | render   (phases: ${PHASES[*]})" >&2; exit 2 ;;
esac
