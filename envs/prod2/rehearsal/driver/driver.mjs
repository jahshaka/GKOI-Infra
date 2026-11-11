// GKOI prod2 private go-live rehearsal driver (envs/prod2/rehearsal/README.md). Runs INSIDE AWS as the one-off ECS task
// gkoi-prod2-rehearsal-driver (entrypoint.sh installs ffmpeg, then runs this file with node 22). No dependencies.
//
// Per media region it walks the GKOI Live app's own path against the ECS engine (site link mode: a brokered device
// whose short-lived token the "site" — this driver, signing gateway identities with GATEWAY_SHARED_SECRET — mints):
//   engine health → registered regions/boxes → device + token → POST /api/v1/app/sessions {mode: relay, region} →
//   ~60 s of synthetic 1080p60 H.264 + AAC (a pre-encoded 6 Mb/s CBR clip, looped with -c copy) over RTMPS to the
//   region's box → the engine says live + publishing → LL-HLS through the region's origin (X-Origin-Verify) and through
//   the engine's watch proxy → end → recording available → thumbnails (the box's vod job) → the Download MP4 (the ECS
//   worker's vod job) → the objects in the scratch bucket (S3 ListObjectsV2, SigV4 with the task role).
// Prints a PASS/FAIL table; exit 0 = every region passed, 1 = a region failed, 2 = bad configuration, 3 = the engine or
// the regions never came up. NEVER prints a secret: tokens, the publish key and the origin secret are redacted.
//
// Environment (the task definition sets it; containerOverrides may change the plain ones):
//   GATEWAY_SHARED_SECRET     (ECS secret) the engine's gateway secret — signs the x-mikaido-identity assertions
//   ORIGIN_VERIFY_<KEY>       (ECS secrets) each region's gkoi/media/<key>/origin-verify
//   ENGINE_URL                https://engine.gkoi.com
//   ENGINE_CONNECT_HOST       connect to this host instead of ENGINE_URL's (the prod2 ALB: engine.gkoi.com's public DNS
//                             still names Lightsail); TLS SNI + Host stay ENGINE_URL's. Empty = normal DNS.
//   REGIONS                   JSON [{key, region, streamHost, originHost}]
//   ONLY                      comma list of region keys to run (default: all of REGIONS)
//   CMS_USER_ID               the test identity's cmsUserId (default rehearsal-p2-driver — README "The test user")
//   PUBLISH_SECONDS (60) VIDEO_KBPS (6000) FPS (60) SIZE (1920x1080) PARALLEL (0)
//   SCRATCH_BUCKET, SCRATCH_BUCKET_REGION   where the recording must land (ListObjectsV2 with the task role)
//   WAIT_ENGINE_SEC (600) WAIT_REGIONS_SEC (900)
//   SKIP_ORIGIN, SKIP_WATCH, SKIP_BUCKET, SKIP_MP4, SKIP_THUMBS = 1   (local runs against the dev stack only)
import http from "node:http";
import https from "node:https";
import dns from "node:dns";
import { createHash, createHmac, randomBytes } from "node:crypto";
import { spawn } from "node:child_process";
import { setTimeout as sleep } from "node:timers/promises";

const env = process.env;
const T0 = Date.now();
const CLIP = "/tmp/rehearsal-clip.mp4";

// --- redaction: nothing secret reaches stdout ----------------------------------------------------------------------
const SECRETS = new Set();
const remember = (v) => {
  if (typeof v === "string" && v.length >= 8) SECRETS.add(v);
  return v;
};
function redact(s) {
  let out = String(s);
  for (const v of SECRETS) out = out.split(v).join("[REDACTED]");
  return out
    .replace(/([?&]key=)[^&\s"'<>]+/gi, "$1[REDACTED]")
    .replace(/(bearer\s+)[A-Za-z0-9._~+/=-]+/gi, "$1[REDACTED]")
    .replace(/(x-mikaido-identity["':\s]+)[A-Za-z0-9._-]+/gi, "$1[REDACTED]");
}
const stamp = () => `[${((Date.now() - T0) / 1000).toFixed(1).padStart(7)}s]`;
const log = (...a) => console.log(redact(`${stamp()} ${a.join(" ")}`));

// --- configuration -------------------------------------------------------------------------------------------------
function configError(msg) {
  console.log(`REHEARSAL_CONFIG_ERROR ${msg}`);
  process.exit(2);
}
const num = (name, dflt, min, max) => {
  const raw = env[name];
  if (raw === undefined || raw === "") return dflt;
  const v = Number(raw);
  if (!Number.isFinite(v) || v < min || v > max) configError(`${name} must be a number in ${min}..${max}`);
  return v;
};
const flag = (name) => env[name] === "1" || env[name] === "true";

const GATEWAY_SECRET = remember(env.GATEWAY_SHARED_SECRET ?? "");
if (GATEWAY_SECRET.length < 16) configError("GATEWAY_SHARED_SECRET is missing or short (the ECS secret did not resolve)");
const ENGINE_URL = (env.ENGINE_URL ?? "https://engine.gkoi.com").replace(/\/+$/, "");
const ENGINE_CONNECT_HOST = env.ENGINE_CONNECT_HOST ?? "";
const CMS_USER_ID = env.CMS_USER_ID || "rehearsal-p2-driver";
if (!/^[A-Za-z0-9_-]{8,64}$/.test(CMS_USER_ID)) configError("CMS_USER_ID must be 8-64 of [A-Za-z0-9_-]");
const PUBLISH_SECONDS = num("PUBLISH_SECONDS", 60, 20, 600);
const VIDEO_KBPS = num("VIDEO_KBPS", 6000, 500, 20000);
const FPS = num("FPS", 60, 24, 60);
const SIZE = env.SIZE || "1920x1080";
if (!/^\d{3,4}x\d{3,4}$/.test(SIZE)) configError("SIZE must look like 1920x1080");
const PARALLEL = flag("PARALLEL");
const WAIT_ENGINE_SEC = num("WAIT_ENGINE_SEC", 600, 0, 3600);
const WAIT_REGIONS_SEC = num("WAIT_REGIONS_SEC", 900, 0, 3600);
const SCRATCH_BUCKET = env.SCRATCH_BUCKET ?? "";
const SCRATCH_BUCKET_REGION = env.SCRATCH_BUCKET_REGION || "us-west-2";
const SKIP = { origin: flag("SKIP_ORIGIN"), watch: flag("SKIP_WATCH"), bucket: flag("SKIP_BUCKET"), mp4: flag("SKIP_MP4"), thumbs: flag("SKIP_THUMBS") };
if (!SKIP.bucket && !/^[a-z0-9][a-z0-9.-]{2,62}$/.test(SCRATCH_BUCKET)) configError("SCRATCH_BUCKET is not a bucket name (or SKIP_BUCKET=1)");

let REGIONS;
try {
  REGIONS = JSON.parse(env.REGIONS ?? "[]");
} catch {
  configError("REGIONS is not JSON");
}
if (!Array.isArray(REGIONS) || REGIONS.length === 0) configError("REGIONS is empty");
for (const r of REGIONS) {
  if (!/^[a-z0-9]{3,8}$/.test(r.key ?? "") || !/^[a-z]{2}-[a-z]+-\d$/.test(r.region ?? "") || !r.streamHost || !r.originHost) {
    configError(`a REGIONS entry lacks key/region/streamHost/originHost: ${JSON.stringify(r)}`);
  }
  r.verify = remember(env[`ORIGIN_VERIFY_${r.key.toUpperCase()}`] ?? "");
  if (!SKIP.origin && r.verify.length < 32) configError(`ORIGIN_VERIFY_${r.key.toUpperCase()} is missing (the ECS secret gkoi/media/${r.key}/origin-verify)`);
}
if (env.ONLY) {
  const only = env.ONLY.split(",").map((s) => s.trim()).filter(Boolean);
  const unknown = only.filter((k) => !REGIONS.some((r) => r.key === k));
  if (unknown.length > 0) configError(`ONLY names unknown regions: ${unknown.join(", ")}`);
  REGIONS = REGIONS.filter((r) => only.includes(r.key));
}

// --- HTTP ----------------------------------------------------------------------------------------------------------
function request(url, { method = "GET", headers = {}, body, timeoutMs = 20_000, connectHost = "" } = {}) {
  const u = new URL(url);
  const mod = u.protocol === "https:" ? https : http;
  const payload = body === undefined ? undefined : Buffer.from(typeof body === "string" ? body : JSON.stringify(body));
  const h = { ...headers };
  if (payload !== undefined) {
    h["content-type"] ??= "application/json";
    h["content-length"] = String(payload.length);
  }
  const opts = { method, hostname: u.hostname, port: u.port || (u.protocol === "https:" ? 443 : 80), path: u.pathname + u.search, headers: h, agent: false };
  if (u.protocol === "https:") opts.servername = u.hostname;
  if (connectHost) opts.lookup = (_host, o, cb) => dns.lookup(connectHost, o, cb);
  return new Promise((resolve, reject) => {
    const req = mod.request(opts, (res) => {
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => {
        const buf = Buffer.concat(chunks);
        resolve({
          status: res.statusCode ?? 0,
          headers: res.headers,
          bytes: buf.length,
          text: () => buf.toString("utf8"),
          json: () => {
            try {
              return JSON.parse(buf.toString("utf8"));
            } catch {
              return null;
            }
          },
        });
      });
      res.on("error", reject);
    });
    req.setTimeout(timeoutMs, () => req.destroy(new Error(`timeout after ${timeoutMs} ms`)));
    req.on("error", reject);
    if (payload !== undefined) req.write(payload);
    req.end();
  });
}

/** An x-mikaido-identity assertion (the @mikaido/shared gateway contract: HS256, ≤ 120 s, single-use jti). */
function identity(roles = []) {
  const now = Math.floor(Date.now() / 1000);
  const claims = { cmsUserId: CMS_USER_ID, roles, canStream: true, iat: now, exp: now + 60, jti: randomBytes(12).toString("base64url") };
  const h = Buffer.from(JSON.stringify({ alg: "HS256", typ: "JWT" })).toString("base64url");
  const p = Buffer.from(JSON.stringify(claims)).toString("base64url");
  const s = createHmac("sha256", GATEWAY_SECRET).update(`${h}.${p}`).digest("base64url");
  return `${h}.${p}.${s}`;
}

/** auth: "gw" | "admin" | {bearer} | null */
async function engine(path, { method = "GET", body, auth = "gw", timeoutMs } = {}) {
  const headers = { accept: "application/json" };
  if (auth === "gw") headers["x-mikaido-identity"] = identity();
  else if (auth === "admin") headers["x-mikaido-identity"] = identity(["admin"]);
  else if (auth && auth.bearer) headers.authorization = `Bearer ${auth.bearer}`;
  return request(`${ENGINE_URL}${path}`, { method, headers, body, timeoutMs, connectHost: ENGINE_CONNECT_HOST });
}
const brief = (r) => `HTTP ${r.status} ${redact(r.text().slice(0, 300)).replace(/\s+/g, " ")}`;

async function until(what, timeoutMs, intervalMs, fn) {
  const end = Date.now() + timeoutMs;
  let last = "";
  for (;;) {
    try {
      const v = await fn();
      if (v !== undefined && v !== null && v !== false) return v;
    } catch (err) {
      if (err?.fatal) throw err;
      last = String(err?.message ?? err);
    }
    if (Date.now() >= end) throw new Error(`${what}: not within ${Math.round(timeoutMs / 1000)} s${last ? ` (last error: ${last})` : ""}`);
    await sleep(intervalMs);
  }
}

// --- HLS -----------------------------------------------------------------------------------------------------------
/** Fetch <base>index.m3u8 → the first variant's media playlist → its init (EXT-X-MAP) + its newest segment (or part).
 *  Returns a short description; throws on any non-200 or empty body. */
async function hlsProbe(base, headers, connectHost = "") {
  const get = async (url) => {
    const r = await request(url, { headers, connectHost, timeoutMs: 15_000 });
    if (r.status !== 200) throw new Error(`${new URL(url).pathname.split("/").pop()}: HTTP ${r.status}`);
    if (r.bytes === 0) throw new Error(`${new URL(url).pathname.split("/").pop()}: empty`);
    return r;
  };
  const indexUrl = `${base}index.m3u8`;
  const idx = await get(indexUrl);
  let mediaUrl = indexUrl;
  let text = idx.text();
  if (text.includes("#EXT-X-STREAM-INF")) {
    const lines = text.split("\n").map((l) => l.trim());
    const i = lines.findIndex((l) => l.startsWith("#EXT-X-STREAM-INF"));
    const uri = lines.slice(i + 1).find((l) => l && !l.startsWith("#"));
    if (!uri) throw new Error("index.m3u8 names no variant");
    mediaUrl = new URL(uri, indexUrl).href;
    text = (await get(mediaUrl)).text();
  }
  const map = /#EXT-X-MAP:URI="([^"]+)"/.exec(text)?.[1];
  const segs = text.split("\n").map((l) => l.trim()).filter((l) => l && !l.startsWith("#"));
  const parts = [...text.matchAll(/#EXT-X-PART:[^\n]*URI="([^"]+)"/g)].map((m) => m[1]);
  const pick = segs.at(-1) ?? parts.at(-1);
  if (!pick) throw new Error("the media playlist lists no segment or part yet");
  let bytes = 0;
  if (map) bytes += (await get(new URL(map, mediaUrl).href)).bytes;
  bytes += (await get(new URL(pick, mediaUrl).href)).bytes;
  return `${segs.length} segments, ${parts.length} parts, init+newest ${bytes} B`;
}

// --- S3 ListObjectsV2 with the task role (SigV4, no SDK) -------------------------------------------------------------
let credsCache = null;
async function awsCreds() {
  if (credsCache && credsCache.expires - Date.now() > 120_000) return credsCache;
  if (env.AWS_CONTAINER_CREDENTIALS_RELATIVE_URI) {
    const r = await request(`http://169.254.170.2${env.AWS_CONTAINER_CREDENTIALS_RELATIVE_URI}`, { timeoutMs: 5_000 });
    const j = r.json();
    if (r.status !== 200 || !j?.AccessKeyId) throw new Error(`task role credentials: HTTP ${r.status}`);
    credsCache = { ak: j.AccessKeyId, sk: remember(j.SecretAccessKey), token: remember(j.Token), expires: Date.parse(j.Expiration) || Date.now() + 600_000 };
    return credsCache;
  }
  if (env.AWS_ACCESS_KEY_ID && env.AWS_SECRET_ACCESS_KEY) {
    return { ak: env.AWS_ACCESS_KEY_ID, sk: remember(env.AWS_SECRET_ACCESS_KEY), token: remember(env.AWS_SESSION_TOKEN ?? "") || undefined, expires: Date.now() + 600_000 };
  }
  throw new Error("no AWS credentials (not in ECS, no AWS_ACCESS_KEY_ID)");
}
const sha256hex = (s) => createHash("sha256").update(s).digest("hex");
const hmac = (k, s) => createHmac("sha256", k).update(s).digest();
const awsEnc = (s) => encodeURIComponent(s).replace(/[!'()*]/g, (c) => `%${c.charCodeAt(0).toString(16).toUpperCase()}`);
const xmlText = (s) => s.replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&");

async function s3List(bucket, region, prefix) {
  const out = [];
  let token;
  do {
    const c = await awsCreds();
    const host = `${bucket}.s3.${region}.amazonaws.com`;
    const q = { "list-type": "2", prefix, ...(token ? { "continuation-token": token } : {}) };
    const cq = Object.keys(q).sort().map((k) => `${awsEnc(k)}=${awsEnc(q[k])}`).join("&");
    const amzDate = new Date().toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");
    const day = amzDate.slice(0, 8);
    const payloadHash = sha256hex("");
    const hdrs = { host, "x-amz-content-sha256": payloadHash, "x-amz-date": amzDate, ...(c.token ? { "x-amz-security-token": c.token } : {}) };
    const names = Object.keys(hdrs).sort();
    const canonical = ["GET", "/", cq, names.map((k) => `${k}:${hdrs[k]}`).join("\n") + "\n", names.join(";"), payloadHash].join("\n");
    const scope = `${day}/${region}/s3/aws4_request`;
    const toSign = ["AWS4-HMAC-SHA256", amzDate, scope, sha256hex(canonical)].join("\n");
    const key = hmac(hmac(hmac(hmac(`AWS4${c.sk}`, day), region), "s3"), "aws4_request");
    const sig = createHmac("sha256", key).update(toSign).digest("hex");
    const authz = `AWS4-HMAC-SHA256 Credential=${c.ak}/${scope}, SignedHeaders=${names.join(";")}, Signature=${sig}`;
    const r = await request(`https://${host}/?${cq}`, { headers: { ...hdrs, authorization: authz } });
    const xml = r.text();
    if (r.status !== 200) throw new Error(`ListObjectsV2 s3://${bucket}/${prefix}: HTTP ${r.status} ${/<Code>([^<]+)/.exec(xml)?.[1] ?? ""}`);
    for (const m of xml.matchAll(/<Contents>([\s\S]*?)<\/Contents>/g)) {
      out.push({ key: xmlText(/<Key>([^<]*)<\/Key>/.exec(m[1])?.[1] ?? ""), size: Number(/<Size>(\d+)<\/Size>/.exec(m[1])?.[1] ?? 0) });
    }
    token = /<IsTruncated>true<\/IsTruncated>/.test(xml) ? xmlText(/<NextContinuationToken>([^<]+)/.exec(xml)?.[1] ?? "") || undefined : undefined;
  } while (token);
  return out;
}

/** A recording URL (scratch bucket: https://<bucket>.s3.<r>.amazonaws.com/<key>, or path style, or a CDN base) →
 *  {bucket (null when the URL does not name one), key}. */
function objectOfUrl(url) {
  const u = new URL(url);
  const path = decodeURIComponent(u.pathname).replace(/^\/+/, "");
  const vhost = /^(.+)\.s3[.-]/.exec(u.hostname);
  if (vhost) return { bucket: vhost[1], key: path };
  if (/^s3[.-]/.test(u.hostname)) {
    const [b, ...rest] = path.split("/");
    return { bucket: b, key: rest.join("/") };
  }
  return { bucket: null, key: path };
}

// --- ffmpeg ----------------------------------------------------------------------------------------------------------
function run(cmd, args, label, { quietLines = 40 } = {}) {
  return new Promise((resolve) => {
    const p = spawn(cmd, args, { stdio: ["ignore", "ignore", "pipe"] });
    let shown = 0;
    let buf = "";
    p.stderr.on("data", (c) => {
      buf += c.toString();
      let i;
      while ((i = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, i).trim();
        buf = buf.slice(i + 1);
        if (line && shown < quietLines) {
          shown++;
          log(`  [${label}] ${line}`);
        }
      }
    });
    p.on("error", (err) => resolve({ code: -1, error: String(err.message) }));
    p.on("close", (code) => resolve({ code: code ?? -1 }));
  });
}

async function makeClip() {
  // 10 s = 5 GOPs of 2 s (keyframe every 2 s, no B-frames, CBR) so the loop seam is a keyframe; AAC 128k 48 kHz stereo.
  const [w, h] = SIZE.split("x");
  const args = [
    "-hide_banner", "-nostdin", "-loglevel", "error", "-y",
    "-f", "lavfi", "-i", `testsrc2=size=${w}x${h}:rate=${FPS}`,
    "-f", "lavfi", "-i", "sine=frequency=1000:sample_rate=48000",
    "-t", "10", "-c:v", "libx264", "-preset", "veryfast", "-profile:v", "high", "-level:v", "4.2", "-pix_fmt", "yuv420p", "-bf", "0",
    "-b:v", `${VIDEO_KBPS}k`, "-maxrate", `${VIDEO_KBPS}k`, "-bufsize", `${VIDEO_KBPS}k`, "-g", String(FPS * 2), "-keyint_min", String(FPS * 2),
    "-sc_threshold", "0", "-x264-params", "nal-hrd=cbr:force-cfr=1",
    "-c:a", "aac", "-b:a", "128k", "-ar", "48000", "-ac", "2", "-movflags", "+faststart", CLIP,
  ];
  const t = Date.now();
  const r = await run("ffmpeg", args, "clip");
  if (r.code !== 0) throw new Error(`clip encode failed (ffmpeg exit ${r.code}${r.error ? `: ${r.error}` : ""})`);
  log(`clip: ${SIZE}@${FPS} ${VIDEO_KBPS} kb/s H.264 + AAC, 10 s, encoded in ${((Date.now() - t) / 1000).toFixed(1)} s`);
}

function publish(url, label) {
  remember(url);
  const args = ["-hide_banner", "-nostdin", "-loglevel", "warning", "-re", "-stream_loop", "-1", "-i", CLIP, "-t", String(PUBLISH_SECONDS), "-c", "copy", "-f", "flv", url];
  const child = { done: null, proc: null };
  child.done = new Promise((resolve) => {
    const p = spawn("ffmpeg", args, { stdio: ["ignore", "ignore", "pipe"] });
    child.proc = p;
    let shown = 0;
    p.stderr.on("data", (c) => {
      for (const line of c.toString().split("\n")) {
        // flv over a socket cannot be rewritten at the end — ffmpeg's two "Failed to update header" lines are noise
        if (line.trim() && !/Failed to update header/.test(line) && shown++ < 30) log(`  [${label} ffmpeg] ${line.trim()}`);
      }
    });
    p.on("error", (err) => resolve({ code: -1, error: String(err.message) }));
    p.on("close", (code, signal) => resolve({ code: code ?? -1, signal }));
  });
  return child;
}

// --- one region ----------------------------------------------------------------------------------------------------
const ms = (t) => `${((Date.now() - t) / 1000).toFixed(1)}s`;

async function mintDevice(ref, name) {
  const c = await engine("/api/v1/broker/devices", { method: "POST", body: { name, os: "linux", appVersion: "rehearsal-driver", ref } });
  if (c.status !== 200 && c.status !== 201) throw new Error(`broker device: ${brief(c)}`);
  const deviceId = c.json()?.deviceId;
  const t = await engine(`/api/v1/broker/devices/${deviceId}/token`, { method: "POST", body: {} });
  if (t.status !== 200) throw new Error(`broker token: ${brief(t)}`);
  return { deviceId, token: remember(t.json()?.accessToken ?? "") };
}

async function runRegion(reg) {
  const res = { key: reg.key, region: reg.region, ok: true, cols: {}, notes: [] };
  const fail = (what) => {
    res.ok = false;
    res.notes.push(what);
    log(`${reg.key}: FAIL ${what}`);
  };
  const L = (...a) => log(`${reg.key}:`, ...a);
  let device = null;
  let sessionId = null;
  let pub = null;
  try {
    device = await mintDevice(`rehearsal-${reg.key}-${randomBytes(4).toString("hex")}`, `GKOI rehearsal ${reg.key}`);
    L(`device ${device.deviceId} (brokered)`);

    // (c) create the relay session placed in this region — the app's POST /api/v1/app/sessions
    const tCreate = Date.now();
    const c = await engine("/api/v1/app/sessions", { method: "POST", auth: { bearer: device.token }, body: { mode: "relay", destinations: [], region: reg.region, title: `rehearsal ${reg.key}` } });
    if (c.status !== 201) throw new Error(`create: ${brief(c)}`);
    const created = c.json();
    sessionId = created.sessionId;
    res.cols.create = `${Date.now() - tCreate}ms`;
    const ingestUrl = remember(created.ingest?.rtmpsUrl ?? "");
    L(`session ${sessionId}: region ${created.region}, phase ${created.phase}, ingest ${ingestUrl ? new URL(ingestUrl).host : "(no rtmpsUrl)"}`);
    if (created.region !== reg.region) throw new Error(`placed in ${created.region}, asked ${reg.region} (the region is unhealthy or not registered)`);
    if (!ingestUrl) throw new Error("the 201 carries no ingest.rtmpsUrl");
    if (new URL(ingestUrl).hostname !== reg.streamHost) throw new Error(`ingest host ${new URL(ingestUrl).hostname} ≠ ${reg.streamHost}`);

    // (d) publish
    const tPub = Date.now();
    pub = publish(ingestUrl, reg.key);
    let ffEnded = null;
    void pub.done.then((r) => {
      ffEnded = r;
    });

    // (e) while live: the engine says publishing + live
    const publishing = await until("the engine reports publishing", 45_000, 1_000, async () => {
      if (ffEnded) {
        throw Object.assign(new Error(`ffmpeg ended before the engine saw it publish (exit ${ffEnded.code}${ffEnded.error ? `: ${ffEnded.error}` : ""})`), { fatal: true });
      }
      const r = await engine(`/api/v1/app/sessions/${sessionId}/ingest`, { auth: { bearer: device.token } });
      if (r.status !== 200) throw new Error(brief(r));
      const j = r.json();
      return j.publishing === true ? j : undefined;
    });
    res.cols.publishing = ms(tPub);
    L(`publishing after ${res.cols.publishing} (region ${publishing.region})`);

    const tLive = Date.now();
    const live = await until("GET /api/v1/sessions/:id live", 20_000, 1_000, async () => {
      const r = await engine(`/api/v1/sessions/${sessionId}`);
      if (r.status !== 200) throw new Error(brief(r));
      const s = r.json()?.session;
      return s?.status === "live" ? s : undefined;
    });
    L(`engine: status live (${ms(tLive)}), ingestKbps ${live.ingestKbps ?? "null"}`);

    if (!SKIP.origin) {
      const base = `https://${reg.originHost}/r/${reg.key}/live/${sessionId}/hls/`;
      const tO = Date.now();
      try {
        const d = await until("origin LL-HLS", 45_000, 1_500, () => hlsProbe(base, { "x-origin-verify": reg.verify }));
        res.cols.origin = ms(tO);
        L(`origin ${reg.originHost}: ${d} (${res.cols.origin})`);
        const bare = await request(`${base}index.m3u8`);
        if (bare.status !== 403) fail(`origin without X-Origin-Verify answered ${bare.status}, expected 403`);
      } catch (err) {
        res.cols.origin = "FAIL";
        fail(`origin: ${err.message}`);
      }
    }
    if (!SKIP.watch) {
      const tW = Date.now();
      try {
        const d = await until("engine watch HLS", 45_000, 1_500, () => hlsProbe(`${ENGINE_URL}/api/v1/watch/${sessionId}/hls/`, {}, ENGINE_CONNECT_HOST));
        res.cols.watch = ms(tW);
        L(`engine watch proxy: ${d} (${res.cols.watch})`);
      } catch (err) {
        res.cols.watch = "FAIL";
        fail(`watch: ${err.message}`);
      }
    }
    // the bitrate the engine measured (H1: the agent's 10 s average — known ~10-20 s into the publish)
    const kbps = await until("ingestKbps", Math.max(5_000, tPub + (PUBLISH_SECONDS - 3) * 1000 - Date.now()), 2_000, async () => {
      const r = await engine(`/api/v1/app/sessions/${sessionId}/ingest`, { auth: { bearer: device.token } });
      return typeof r.json()?.ingestKbps === "number" ? r.json().ingestKbps : undefined;
    }).catch(() => null);
    res.cols.kbps = kbps === null ? "-" : String(Math.round(kbps));
    if (kbps === null) res.notes.push("ingestKbps never reported (advisory)");
    else L(`engine measured ${Math.round(kbps)} kb/s ingest`);

    const done = await pub.done;
    if (done.code !== 0) fail(`ffmpeg exit ${done.code}${done.signal ? ` (${done.signal})` : ""}${done.error ? `: ${done.error}` : ""}`);
    else L(`published ${PUBLISH_SECONDS} s (${ms(tPub)} wall)`);
    pub = null;

    // (f) stop
    const tEnd = Date.now();
    const e = await engine(`/api/v1/app/sessions/${sessionId}/end`, { method: "POST", auth: { bearer: device.token }, body: {} });
    if (e.status !== 200) throw new Error(`end: ${brief(e)}`);
    const ended = await until("session ended", 30_000, 1_000, async () => {
      const r = await engine(`/api/v1/sessions/${sessionId}`);
      const s = r.json()?.session;
      return s?.status === "ended" ? s : undefined;
    });
    L(`ended (${ended.endedReason}) after ${ms(tEnd)}`);
    const endedId = sessionId;
    sessionId = null; // nothing left to end

    const tVod = Date.now();
    const vodRef = await until("recording available", 240_000, 3_000, async () => {
      const r = await engine("/api/v1/sessions");
      const s = r.json()?.sessions?.find((x) => x.id === endedId);
      if (s?.vod?.status === "failed") throw Object.assign(new Error("the recording FAILED"), { fatal: true });
      return s?.vod?.status === "available" ? s.vod : undefined;
    });
    res.cols.vod = ms(tVod);
    const vod = (await engine(`/api/v1/vods/${vodRef.id}`)).json();
    L(`recording ${vodRef.id}: available after ${res.cols.vod}, ${vod.durationSec} s, ${vod.segmentCount} pieces, ${vod.bytes} B, audio ${vod.audioCodec}`);
    if (!(vod.bytes > 0 && vod.segmentCount > 0)) fail("the recording is empty");
    if (Math.abs((vod.durationSec ?? 0) - PUBLISH_SECONDS) > 15) fail(`recording duration ${vod.durationSec} s, published ${PUBLISH_SECONDS} s`);

    let thumbUrl = null;
    if (!SKIP.thumbs) {
      const tT = Date.now();
      try {
        thumbUrl = await until("thumbnails (the box's vod.thumbs job)", 240_000, 5_000, async () => (await engine(`/api/v1/vods/${vodRef.id}`)).json()?.thumbUrl);
        res.cols.thumbs = ms(tT);
        L(`thumbnail after ${res.cols.thumbs}`);
      } catch (err) {
        res.cols.thumbs = "FAIL";
        fail(err.message);
      }
    }
    let mp4Url = null;
    if (!SKIP.mp4) {
      const tM = Date.now();
      try {
        mp4Url = await until("the Download MP4 (the worker's vod.mp4 job)", 420_000, 5_000, async () => {
          const r = await engine(`/api/v1/vods/${vodRef.id}/download`, { method: "POST", body: {} });
          if (r.status === 200 && r.json()?.status === "ready") return r.json().url;
          if (r.status === 202) return undefined;
          throw Object.assign(new Error(`download: ${brief(r)}`), { fatal: r.status === 422 });
        });
        res.cols.mp4 = ms(tM);
        L(`MP4 built after ${res.cols.mp4}`);
      } catch (err) {
        res.cols.mp4 = "FAIL";
        fail(err.message);
      }
    }

    if (!SKIP.bucket) {
      const anyUrl = mp4Url ?? thumbUrl;
      if (!anyUrl) fail("no recording URL to locate the objects by (thumbnail + MP4 both missing)");
      else {
        const o = objectOfUrl(anyUrl);
        if (o.bucket !== null && o.bucket !== SCRATCH_BUCKET) fail(`the recording URL names bucket ${o.bucket}, not the scratch bucket ${SCRATCH_BUCKET}`);
        const prefix = `${o.key.split("/")[0]}/`;
        try {
          const objs = await s3List(SCRATCH_BUCKET, SCRATCH_BUCKET_REGION, prefix);
          const n = (re) => objs.filter((x) => re.test(x.key)).length;
          const playlists = n(/\.m3u8$/);
          const pieces = objs.filter((x) => /\.(m4s|ts|mp4)$/.test(x.key) && !x.key.endsWith("/vod.mp4") && x.key !== o.key).length;
          res.cols.bucket = `${objs.length} obj`;
          L(`s3://${SCRATCH_BUCKET}/${prefix}: ${objs.length} objects (${playlists} playlists, ${pieces} pieces, ${n(/\.webp$/)} webp, ${n(/\.mp4$/)} mp4), ${objs.reduce((a, x) => a + x.size, 0)} B`);
          if (playlists === 0 || pieces === 0) fail(`the scratch bucket lacks the recording (playlists ${playlists}, pieces ${pieces})`);
          if (mp4Url && !objs.some((x) => x.key === objectOfUrl(mp4Url).key)) fail("the MP4 is not in the scratch bucket");
        } catch (err) {
          res.cols.bucket = "FAIL";
          fail(err.message);
        }
      }
    }
  } catch (err) {
    fail(err.message ?? String(err));
  } finally {
    if (pub?.proc) pub.proc.kill("SIGINT");
    if (sessionId) {
      const e = await engine(`/api/v1/app/sessions/${sessionId}/end`, { method: "POST", auth: device ? { bearer: device.token } : null, body: {} }).catch(() => null);
      L(`cleanup: session end → ${e ? e.status : "error"}`);
    }
    if (device) {
      const d = await engine(`/api/v1/devices/${device.deviceId}`, { method: "DELETE" }).catch(() => null);
      L(`cleanup: device revoked → ${d ? d.status : "error"}`);
    }
  }
  return res;
}

// --- main ----------------------------------------------------------------------------------------------------------
function table(results) {
  const cols = ["create", "publishing", "origin", "watch", "kbps", "vod", "thumbs", "mp4", "bucket"];
  const head = ["region", "", ...cols, "result"];
  const rows = results.map((r) => [r.key, r.region, ...cols.map((c) => r.cols[c] ?? "-"), r.ok ? "PASS" : "FAIL"]);
  const w = head.map((h, i) => Math.max(h.length, ...rows.map((r) => String(r[i]).length)));
  const line = (cells) => cells.map((c, i) => String(c).padEnd(w[i])).join("  ");
  console.log("");
  console.log(line(head));
  console.log(line(w.map((n) => "-".repeat(n))));
  for (const r of rows) console.log(line(r));
  for (const r of results) for (const n of r.notes) console.log(redact(`  ${r.key}: ${n}`));
  console.log("");
}

async function main() {
  log(`rehearsal driver: engine ${ENGINE_URL}${ENGINE_CONNECT_HOST ? ` via ${ENGINE_CONNECT_HOST}` : ""}, regions ${REGIONS.map((r) => r.key).join(",")}, ${PUBLISH_SECONDS} s each${PARALLEL ? " in parallel" : ""}, identity ${CMS_USER_ID}`);

  // (a) the engine
  const tH = Date.now();
  await until("engine /api/v1/healthz", WAIT_ENGINE_SEC * 1000, 5_000, async () => (await engine("/api/v1/healthz", { auth: null })).status === 200).catch((err) => {
    log(`ENGINE NOT HEALTHY: ${err.message}`);
    process.exit(3);
  });
  const ready = await engine("/api/v1/readyz", { auth: null }).catch(() => null);
  log(`engine healthy (${ms(tH)}); readyz ${ready ? brief(ready) : "unreachable"}`);
  const me = await engine("/api/v1/me");
  if (me.status !== 200) {
    log(`IDENTITY REFUSED: GET /api/v1/me ${brief(me)} (the gateway secret, the edge allow-list, or the clock)`);
    process.exit(3);
  }

  await makeClip();

  // (b) the registered boxes + the regions the app is offered
  const boxes = await engine("/api/v1/admin/media/boxes", { auth: "admin" });
  if (boxes.status === 200) {
    for (const b of boxes.json()?.boxes ?? []) {
      log(`box ${b.box}: ${b.region} ${b.state} (${b.source}) pools ${b.pools.join(",")}; report ${b.report ? `sessions ${b.report.sessions ?? "-"} idle ${b.report.idle ?? "-"}` : "none"}`);
    }
  } else log(`(admin box list: ${brief(boxes)})`);
  const lister = await mintDevice(`rehearsal-list-${randomBytes(4).toString("hex")}`, "GKOI rehearsal (regions)");
  const tR = Date.now();
  let lastSeen = "";
  try {
    await until("every rehearsal region offered by GET /api/v1/app/regions", WAIT_REGIONS_SEC * 1000, 10_000, async () => {
      const r = await engine("/api/v1/app/regions", { auth: { bearer: lister.token } });
      if (r.status !== 200) throw new Error(brief(r));
      const list = r.json() ?? [];
      const seen = list.map((x) => `${x.region}=${x.probeHost}:${x.probePort}`).join(" ");
      if (seen !== lastSeen) log(`regions offered: ${seen || "(none)"}`);
      lastSeen = seen;
      const missing = REGIONS.filter((g) => !list.some((x) => x.region === g.region && x.probeHost === g.streamHost));
      return missing.length === 0 ? list : undefined;
    });
    log(`all ${REGIONS.length} regions offered (${ms(tR)})`);
  } catch (err) {
    log(`REGIONS MISSING: ${err.message}`);
    await engine(`/api/v1/devices/${lister.deviceId}`, { method: "DELETE" }).catch(() => null);
    table(REGIONS.map((r) => ({ key: r.key, region: r.region, ok: false, cols: {}, notes: ["not offered by /api/v1/app/regions"] })));
    process.exit(3);
  }
  await engine(`/api/v1/devices/${lister.deviceId}`, { method: "DELETE" }).catch(() => null);

  // (c)–(f) per region
  const results = PARALLEL ? await Promise.all(REGIONS.map(runRegion)) : [];
  if (!PARALLEL) for (const r of REGIONS) results.push(await runRegion(r));

  // (g)
  table(results);
  const ok = results.every((r) => r.ok);
  console.log(ok ? `REHEARSAL_PASS ${results.length} regions` : `REHEARSAL_FAIL ${results.filter((r) => !r.ok).map((r) => r.key).join(",")}`);
  process.exit(ok ? 0 : 1);
}

main().catch((err) => {
  log(`DRIVER ERROR: ${err?.stack ?? err}`);
  process.exit(1);
});
