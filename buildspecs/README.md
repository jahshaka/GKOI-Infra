# buildspecs/: the release builds (PLAN-AWS-MIGRATION-PROD2-V1 §C14)

One CodeBuild buildspec (v0.2) per repo, sent as `buildspecOverride` at StartBuild by `tools/gkoi-release`. The app
repos carry no buildspec and no CI config: the source is a `git archive` zip of a release tag from the dev box's own
checkout, uploaded to S3. GitHub is never in the path.

| File | Project | Source | Gate | Images pushed (ECR `127214190346.dkr.ecr.us-west-2.amazonaws.com/gkoi/<name>`) |
|---|---|---|---|---|
| `aisolver-www.yml` | `gkoi-build-aisolver-www` | aisolver-www @ `gkoi-YYYY.MM.DD-N` | `apps/server/Dockerfile --target test` (VITEST_MAX_FORKS=4) | `cms-server` (target runtime), `cms-nginx` (`infra/nginx/container/Dockerfile`) |
| `mikaido.yml` | `gkoi-build-mikaido` | mikaido @ `gkoi-…` | `npm ci` + `npm run typecheck` + `npx vitest run` against throwaway Postgres 16 / Redis 7 / MinIO | `engine-api`, `engine-worker`, `engine-web`, `media-agent`, `mediamtx` (= the mk-relay pool image) |
| `filemanager.yml` | `gkoi-build-filemanager` | filemanager @ `gkoi-…` | the same shape, apps/api/README's recipe | `fm-api`, `fm-worker`, `fm-web` |
| `warroom-game.yml` | `gkoi-build-warroom-game` | GKOIBuilder_AI `ops/warroom-game` @ a main commit, + `inputs.tar` | the inputs are exactly the committed `pins/<tag>.sha256` set, every sha matches | `warroom-game` (tag = the War Room tag, e.g. `1.0.15.3.3-h6`) |

Not built (no Dockerfile in the engine): `gkoi/media-origin` (compose runs stock `nginx:1.27-alpine` with the config
bind-mounted) and the engine's `api-gw` / the FM's `fm-gw` (the same). The server ffmpeg is built from source inside the
engine build (`infra/docker/ffmpeg.Dockerfile`, local name `gkoi-build/ffmpeg:<version>`) and never pushed.

## What every build does (stages, in order; `GKOI_STAGES`)

1. **install**: writes the shared library `gkoi-common.sh` (the block between the `gkoi-common` markers, IDENTICAL in
   all four files), installs buildx v0.19.3 (sha256-pinned), waits for the Docker daemon, refuses non-amd64.
2. **verify**: downloads `SOURCE_S3_URI` itself, checks it against `SOURCE_SHA256`, checks the zip comment (git
   archive writes the commit id there) equals `SOURCE_COMMIT`, unpacks it. Everything after builds from THAT copy, not
   CodeBuild's own unpacked source. War Room: the same for `inputs.tar` against `INPUTS_SHA256`.
3. **preflight**: `RESULT_S3_URI` (images.json) must not exist and no `gkoi/<name>:<tag>` may exist in ECR (tags are
   immutable; a re-release needs a new tag); then the ECR login. Fails before the expensive gate.
4. **gate**: the repo's own gate (table above). The engine/FM gate runs in `NODE_IMAGE` on a COPY of the source, so the
   image builds see exactly the verified tree; its services are throwaway containers on a private network (nothing
   published), torn down on any exit. Only a green gate sets the flag the next stages require.
5. **build**: each runtime image, `--platform linux/amd64`, tagged `<registry>/gkoi/<name>:<tag>`, `BUILD_SHA` =
   the commit, `BUILD_TIME` = now (mk-relay deliberately unlabelled, as in compose). Layer cache: inline cache +
   `--cache-from <registry>/gkoi/<name>:<CACHE_FROM_TAG>` (the previous release, from `envs/prod2/releases/<repo>.json`).
   The CMS runtime build passes the gate's exact build args, so its `test` stage is a cache hit (the gate runs once).
6. **push**: refuses unless verify, preflight, gate, build all ran in this build and the gate passed. Pushes each
   image, checks the pushed digest against ECR's, writes `images.json` and uploads it to `RESULT_S3_URI`.

`images.json`:
```json
{ "repo": "mikaido", "tag": "gkoi-2026.11.11-1", "commit": "<sha>", "source_sha256": "<sha256>",
  "codebuild_build_id": "gkoi-build-mikaido:<uuid>", "built_at": "2026-11-11T10:00:00Z",
  "images": { "engine-api": { "digest": "sha256:…", "image": "127214190346.dkr.ecr.us-west-2.amazonaws.com/gkoi/engine-api@sha256:…" }, … } }
```

## Environment

| Variable | Set by | Meaning |
|---|---|---|
| `RELEASE_TAG`, `SOURCE_SHA256`, `SOURCE_COMMIT`, `SOURCE_S3_URI`, `RESULT_S3_URI`, `CACHE_FROM_TAG` | gkoi-release (StartBuild override) | see stages |
| `INPUTS_S3_URI`, `INPUTS_SHA256` | gkoi-release, warroom-game only | the game server + helpers |
| `ECR_REGISTRY` (+ `AWS_ACCOUNT_ID`, `ECR_REPOSITORIES`, `BUILD_CACHE_S3`) | the CodeBuild project (registry stack) | only `ECR_REGISTRY` is read |
| `GKOI_REPO`, `GKOI_IMAGES`, `GKOI_WORK`, `GKOI_STAGES`, the pins | the buildspec | |

Pinned: buildx v0.19.3, jq 1.7.1 (War Room), `node:22.23.2-bookworm-slim`, `postgres:16.15-alpine`,
`redis:7.4.11-alpine`, `minio/minio:RELEASE.2025-09-07T16-13-09Z`.

**MinIO is not pulled.** The `minio/minio` repository is gone from Docker Hub, and quay.io refuses it too (pull access
denied, measured 2026-11-10). The gate therefore LOADS the exact image the dev stacks run: `gkoi-release` stages a
`docker save | gzip` of the dev box's copy once per repo at `s3://…/<repo>/ci/minio-RELEASE.2025-09-07T16-13-09Z.tar.gz`,
and the buildspec checks it before `docker load`. The pin `MINIO_CONFIG_DIGEST` is the image's config digest, so the
checker verifies the config blob, amd64, and every layer against the config's `diff_ids` (gzip layers are hashed
uncompressed). The same checker (the `PYCHECK` heredoc) runs on the box before the upload. Node, Postgres and Redis are
pulled with 3 retries. The images' own base images are whatever the repos'
Dockerfiles pin.

## Editing

Change the common block in all four files at once, then run `tools/gkoi-lint-buildspecs` (YAML, the block identical
everywhere, `bash -n` + shellcheck v0.10.0 on every command block and on the library itself).

To run a buildspec's blocks off-AWS (what was done to prove them, 2026-11-10): extract `phases.*.commands[0]` and run
them with `HOME` and `GKOI_WORK` in a scratch dir, `GKOI_STAGES="verify gate build"`, `GKOI_LOCAL_ZIP=<the zip>`, the
`RELEASE_TAG/SOURCE_*` values and `ECR_REGISTRY=gkoi-local.invalid`. `GKOI_LOCAL_ZIP` (and `GKOI_LOCAL_INPUTS`) skip
the S3 download only; the sha256 and commit checks still run, and preflight/push refuse a local source.
