# Private service calls — runbook (prod2)

Spec: GKOIBuilder `docs/specs/SPEC-INFRA-PRIVATE-SERVICE-CALLS-V1.md` (DRAFT for the operator's review, 2026-11-18).
State of this branch: the Terraform is written with EVERY flag default `false`; NOTHING is applied. With the defaults
no resource is created and no task environment changes (each new resource hangs on `local.private_listeners`; the
site's URLs and the engine's `TRUSTED_PROXIES` change only behind their flags).

What it does when switched on: the site (CMS task) reaches the engine and the file manager through the INTERNAL ALB
that already serves the media boxes — two new listeners, `:3100` → engine api (`/api/*`, `/ws/*`) and `:3200` → a new
file-manager target group (`/api/*`) — instead of going out through the NAT to the public names. Plain HTTP inside the
VPC, as every ALB → task hop is today. What apps and browsers are told (the public names) does not change.

## Order — one flag at a time, `plan` first, apply only if the plan shows exactly what is listed

1. **network** — no flag. Plan must show ONLY the new output `home_private_cidrs` (no resource change). Apply.
2. **edge-alb** — `create_private_service_listeners = true`. Plan must show ONLY: two security-group ingress rules on
   the internal ALB's group (from the ECS tasks' group, ports 3100 and 3200), the tasks' egress rules to it, one target
   group `fm-internal`, two listeners with their rules, the output `private_services`. No change to any existing
   listener, to the public ALB or to the media boxes' listener. Apply.
3. **compute** — `engine_trust_private_callers = true` (alone). Plan must show ONLY the engine api / worker / migrator
   task definitions with `TRUSTED_PROXIES` gaining the private subnets, and fm-api registered in the new target group
   (this appears as soon as step 2 is applied). Apply; the engine rolls once. Verify: engine `healthz` 200, the site's
   streaming pages load, the engine still logs real viewer addresses.
4. **compute** — `private_files_calls = true`. Plan must show ONLY the cms task definition's `FILES_SERVICE_URL`.
   Apply; the site rolls once. Verify (below). Leave it a day.
5. **compute** — `private_engine_calls = true` (refused by a precondition unless step 3 is applied). Plan must show
   ONLY the cms task definition's `MIKAIDO_ENGINE_URL`. Apply; verify.

## Verify after steps 4 and 5

- Site `/health` 200; `/files` (store) lists; an Apps-tab read works; `/channels` and the Studio load.
- The file manager's / engine's log shows the site's calls arriving with the internal ALB as the peer; the public
  ALB's access pattern from the NAT address drops to the apps' and browsers' traffic only.
- NAT gateway `ActiveConnectionCount` / bytes fall (CloudWatch); no `ECONNRESET` / `fetch failed` in the cms-server log.
- Per-viewer limits at the engine still key on real viewer addresses (step 3 is what guarantees it).

## Rollback

Set the flag back to `false`, plan, apply (one roll of the affected service). Steps are independent in reverse order.

## Open questions for the operator (the spec's Q1–Q4, with the recommendation)

1. File manager first, the engine a day later — yes.
2. The file manager will see the viewer's address instead of the NAT's on calls the site proxies — accept (as the engine).
3. Internal ALB idle timeout 60 → 300 s (the engine's chat WebSocket sends no pings) — yes; NOT in this branch yet
   (the default must not change silently): a one-line variable when approved.
4. Deletion protection on the internal ALB — yes, separately.

## Not done in this branch / known

- `envs/prod2/compute/tests/plan.tftest.hcl` has 2 failing runs on `main` already (`default_all_parked_live_bucket`,
  `default_values` — they assert every service is parked, which stopped being true when prod2 went live). Unrelated to
  this change; the same 2 fail before and after. Worth fixing on its own.
- No compute test pins the task environments with the new flags off; the evidence that "flags off = today" is the
  code shape (see above) plus `terraform validate` on network / edge-alb / compute and edge-alb's tests (15 pass,
  incl. the new `private-service-listeners.tftest.hcl`). A real `plan` against prod at step 1 is the proof.
