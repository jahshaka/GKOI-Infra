# tools/: releases and Terraform runs from the dev box (PLAN-AWS-MIGRATION-PROD2-V1 §C14)

| Tool | What |
|---|---|
| `gkoi-tag <repo> (--gate-log F \| --yes) [--push]` | cut `gkoi-YYYY.MM.DD-N` (UTC, next free N) on the repo's current commit after its gate passed |
| `gkoi-release <repo> <tag> [--dry-run] …` | zip the tag from the local checkout → S3 → CodeBuild gate + build + push → `envs/prod2/releases/<repo>.json` |
| `gkoi-infra-run <stack> plan\|apply …` | zip this repo → S3 → the `gkoi-infra-runner` CodeBuild project → stream its log |
| `gkoi-lint-buildspecs` | check `buildspecs/*.yml` (YAML, the shared block identical, bash -n, shellcheck) |
| `lib/gkoi-tools.sh` | shared by the above |

Each tool prints its full usage with `-h`. AWS access is `~/.local/bin/gkoi-aws` (IAM Roles Anywhere → role
`/gkoi/gkoi-orchestrator`, fresh 1-hour credentials per call, the AWS CLI in Docker with only the current directory
mounted). The tools run every AWS call from their own temp work directory for that reason. Needs on the box: git, jq,
python3, zip/unzip, curl, Docker.

## A release, end to end

```
# 1. the repo's gate is green on the commit to release (its own recipe), main is pushed
gkoi-tag mikaido --gate-log /path/to/gate.log          # → gkoi-2026.11.11-1 (annotated, local); add --push to publish it
git -C ../mikaido push origin refs/tags/gkoi-2026.11.11-1

# 2. rehearse, then release
gkoi-release mikaido gkoi-2026.11.11-1 --dry-run        # tag → commit on main, zip, sha256, the StartBuild request
gkoi-release mikaido gkoi-2026.11.11-1                   # upload, start gkoi-build-mikaido, wait, record the digests

# 3. commit envs/prod2/releases/mikaido.json (the pinned digests); the ECS deploy uses those digests
```

What `gkoi-release` checks before anything leaves the box: the tag exists LOCALLY and its commit is reachable from
`main`, `origin/main` or a `hotfix/*` branch; the zip carries that commit; `<repo>/<tag>/images.json` does not exist
yet (a tag is released once). Then, in CodeBuild (buildspecs/README.md): the sha256 + commit again, no ECR tag exists,
the FULL gate, the images, the push, `images.json`. A red gate pushes nothing; the tool prints the failing phases and
the last 120 log lines and records nothing.

S3 layout (`s3://gkoi-build-sources-127214190346/`): `<repo>/<tag>/source.zip`, `<repo>/<tag>/images.json`,
`warroom-game/<tag>/inputs.tar`, `gkoi-infra/source.zip`, and `<repo>/ci/minio-<release>.tar.gz` (mikaido,
filemanager). That last one is the gate's MinIO image: no public registry serves it any more. On the first release of
each repo, gkoi-release `docker save`s the dev box's copy, checks it against the buildspec's `MINIO_CONFIG_DIGEST` and
uploads it (`--ci-upload-url-file` in presigned mode).

**Hotfix:** branch `hotfix/gkoi-…` from the release tag, fix, gate, `gkoi-tag` on the hotfix commit (it is on a
`hotfix/` branch, so it qualifies), release, merge back to `main`.

**Through the AWS MCP instead of gkoi-aws:** have the MCP make a presigned PUT URL for `<repo>/<tag>/source.zip`, save it
to a file, then `gkoi-release <repo> <tag> --upload-url-file url.txt --no-start`. It uploads with curl and leaves
`start-build.json` (the exact StartBuild parameters) in its work directory for the MCP to start; download
`images.json` the same way and copy it to `envs/prod2/releases/<repo>.json`.

## The War Room image

`gkoi-release warroom-game <war room tag> [--ref <GKOIBuilder_AI commit, default main>] [--inbox DIR]`

- The source is `git archive` of `ops/warroom-game` at that commit. `pins/<tag>.sha256` must be COMMITTED there, so the
  tag was built + pinned on the dev box first (`warroom-game.sh build`).
- The game server tarball + licences + `matchd.dev.json` (inbox `<game version>/`) and the helpers (inbox
  `<tag>/` for a `-hN` tag) are checked against that pin ON THE BOX, then packed with their `.sha256` sidecars into a
  deterministic `inputs.tar` (`server/…`, `helpers/…`, the pin's own paths), uploaded as
  `warroom-game/<tag>/inputs.tar`, its sha256 passed as `INPUTS_SHA256`.
- CodeBuild re-checks the tar's sha256, that it holds EXACTLY the pinned files, and every pin; then it runs the repo's
  own `warroom-game.sh build <tag> --from inputs/server --helpers inputs/helpers` (prod's env file for the runtime uid)
  and pushes `gkoi/warroom-game:<tag>`.

## Terraform: gkoi-infra-run

```
tools/gkoi-infra-run registry plan                       # HEAD of this repo
tools/gkoi-infra-run registry plan --worktree            # the working tree, before committing (plan only)
tools/gkoi-infra-run registry apply                      # clean tree only; asks for the stack name (or --yes)
tools/gkoi-infra-run data apply --allow-destroy --yes    # ALLOW_DESTROY=yes: the runner refuses deletes without it
```

It zips the repo (`git archive HEAD`, or `--worktree`: tracked + untracked minus `.gitignore`, so `.terraform/` and
state never go), uploads it to `gkoi-infra/source.zip`, starts `gkoi-infra-runner` with `TF_STACK`, `TF_ACTION`
(+ `ALLOW_DESTROY`, `SOURCE_SHA256`, `SOURCE_COMMIT`) and streams the build's log until it ends. The runner uses the
repo's own root `buildspec.yml` from the zip (no override). One run at a time: the source key is shared.
`--dry-run`, `--no-start` and `--upload-url-file` work as in gkoi-release.
