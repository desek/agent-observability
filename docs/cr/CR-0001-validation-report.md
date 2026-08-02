# CR-0001 Validation Report

Validated: 2026-08-02. Source commit: 65d9728 (main). Deliverable is configuration and shell scripts, so criteria with observable runtime behaviour were graded by running the stack, not by reading files.

Operational note: this repository's stack runs as compose project `agent-observability` on `EDGE_PORT=24417` (from a gitignored `.env`). The parent stack `observability` on `24317` was never touched. Any container stopped during this audit belonged to `agent-observability` only and was restarted. Both stacks are running and healthy at the end.

## Summary

Requirements: 33/33 | Acceptance Criteria: 18/19 | Tests: 6/6 | Gaps: 0

- FR PASS 27/27, NFR PASS 6/6.
- AC PASS 18/19, PARTIAL 1 (AC-10), FAIL 0, GAP 0.
- Test Strategy entries present and matching spec: 6/6.

## Requirement Verification

| Req # | Description | Status | Evidence (file:line / command) |
|-------|-------------|--------|--------------------------------|
| FR1 | `compose.yaml` at root, `docker compose up -d` with no args | PASS | `compose.yaml:21`; `docker compose ps` shows all 7 up |
| FR2 | Exactly seven services | PASS | `compose.yaml:44,58,72,88,124,161,202`; `docker compose ps` lists loki,mimir,tempo,alloy,grafana,haproxy,mlflow |
| FR3 | Only haproxy publishes a host port, binds 127.0.0.1 | PASS | `compose.yaml:165-166`; `docker port` per container: only haproxy `24317/tcp -> 127.0.0.1:24417` |
| FR4 | `EDGE_PORT` default 24317, starts with no `.env` | PASS | `compose.yaml:166`; `env -u EDGE_PORT docker compose config` parses |
| FR5 | Every image tagged, none `latest` | PASS | `grep -nE '^\s*image:' compose.yaml` (7 pinned); verify check 5 |
| FR6 | Grafana datasources provisioned and healthy, no manual setup | PASS | `stack/grafana/.../datasources.yaml:16,27,34`; verify check 3 live OK |
| FR7 | MLflow builds from `stack/mlflow/Dockerfile` on first up | PASS | `compose.yaml:203-205`; `stack/mlflow/Dockerfile:15-20`; `stack.up.sh` brought it up |
| FR8 | Five readiness endpoints + `/mlflow/health` answer through single port | PASS | verify check 2: all six return 200 on 24417 |
| FR9 | Named volumes persist across `down`/`up` | PASS | `compose.yaml:29-39`; live persistence proof (see AC-6) |
| FR10 | `stack.verify.sh` asserts port/endpoints/datasources, non-zero on fail, `-h` | PASS | `scripts/stack.verify.sh`; live exit 0; AC-8 exit 1 |
| FR11 | `stack.up.sh` starts and blocks until ready or timeout | PASS | `scripts/stack.up.sh`; `./scripts/stack.up.sh 240` blocked then `up: PASS` |
| FR12 | Apache-2.0 `LICENSE` at root | PASS | `head -5 LICENSE` = Apache License 2.0 |
| FR13 | `.gitignore` excludes `.env` and build/data artifacts | PASS | `.gitignore:10-27`; `git check-ignore .env` |
| FR14 | `.env.example` documents every var incl `EDGE_PORT` default | PASS | `.env.example:12-23` (EDGE_PORT=24317, NPM_TOKEN documented) |
| FR15 | No parent-only path/script/commit references | PASS | `git grep -nE 'pi-extensions/\|link-pi.sh\|link-claude.sh\|agent-orchestration' -- :!docs` → NONE |
| FR16 | No `CR-####` governance IDs outside `docs/` | PASS | `git grep -nE 'CR-[0-9]{4}' -- :!docs` → NONE |
| FR17 | Every config file: purpose comment + one `@agents-index` | PASS | `grep -c @agents-index` = 1 on all 9 config files |
| FR18 | README privacy section | PASS | `README.md:196-225` |
| FR19 | README rollback + teardown in own terms | PASS | `README.md:236-288` (`down` vs `down -v`) |
| FR20 | Alloy readable-log transform for `claude_code.*` and `pi.*` | PASS | `stack/alloy/config.alloy:40-94` (both families). Config retained; not exercised with agent data (see AC-10) |
| FR21 | Loki/Mimir/Tempo promote 4 git provenance attrs to labels | PASS | `stack/loki/config.yaml:53-61`; `stack/mimir/config.yaml:71`; Tempo keeps as span resource attrs (`README.md:193`). Config retained; unpopulated (see AC-10) |
| FR22 | HAProxy self-telemetry: exporter to Mimir, syslog to Loki | PASS | `stack/alloy/config.alloy:149-211`; `stack/haproxy/haproxy.cfg:29,165-169`; live: haproxy series in Mimir + haproxy job line in Loki |
| FR23 | Root `Makefile` `ci` runs every check, non-zero on any fail | PASS | `Makefile:34`; `make ci` ran all; self-test at `:100-110` |
| FR24 | `ci` runs compose+haproxy validation, shell lint, verify scripts | PASS | `make ci` output: check-compose, check-haproxy, lint-scripts, verify all ran |
| FR25 | Individual targets composed by `ci` | PASS | `Makefile:24,37,53,70,82` |
| FR26 | `ci` runnable with stack down: skips, names skipped, no false pass | PASS | `make ci` while down: check-haproxy + verify `SKIP (...)`, exit 0 |
| FR27 | README names `make ci` | PASS | `README.md:118-124` |
| NFR1 | Entirely local, no hosted account/remote db/object store | PASS | loki/mimir/tempo configs filesystem; volumes local |
| NFR2 | No telemetry off-machine | PASS | `compose.yaml:166` loopback bind; internal `otel` network only |
| NFR3 | Manual path = two commands | PASS | `README.md:83-116` (up + verify), both are the shared scripts |
| NFR4 | Docker only prereq; README states min Compose version | PASS | `README.md:54-60` (Compose v2) |
| NFR5 | Reproducible; versions pinned | PASS | 7 image tags pinned; `stack/mlflow/Dockerfile:20` pins pkg |
| NFR6 | Scripts executable, single-purpose, docstring, usage w/o args | PASS | `ls -l scripts/*.sh` both `-rwxr-xr-x`; `-h` prints usage; top docstrings present |

## Acceptance Criteria Verification

| AC # | Description | Status | Evidence / command |
|------|-------------|--------|--------------------|
| AC-1 | One command starts whole stack from fresh clone | PASS | `docker compose ps` = 7 running; mlflow built by `stack.up.sh` with no separate build cmd |
| AC-2 | Exactly one host port, loopback-bound | PASS | `docker port` loop: only `agent-observability-haproxy-1` → `127.0.0.1:24417` |
| AC-3 | Published port changed by one edit | PASS | Stack live on 24417 from a one-line `.env` (`EDGE_PORT=24417`); `EDGE_PORT=34317 docker compose config` → `published: "34317"`, no other file changed |
| AC-4 | Every readiness endpoint answers through single port | PASS | verify check 2: `/loki/ready`,`/prometheus/ready`,`/tempo/ready`,`/alloy/-/healthy`,`/api/health`,`/mlflow/health` all 200 |
| AC-5 | Grafana healthy datasources, no manual setup | PASS | verify check 3; `GET /api/datasources` = [Loki,Mimir,Tempo], mimir health `status:OK` |
| AC-6 | Telemetry persists across stop and start | PASS | Recorded `haproxy_process_start_time_seconds`=1785617737 at t=1785650335; `docker compose down` then `docker compose up -d`; same instant query returned the identical sample; datasources retained |
| AC-7 | Repository is self-contained | PASS | both `git grep` scans (parent paths, governance IDs) outside docs → NONE |
| AC-8 | Verify proves stack and fails usefully | PASS | `docker compose stop loki` then verify → exit 1, `FAIL endpoint '/loki/ready' returned '000'`, names fix `docker compose up -d loki`; loki restarted |
| AC-9 | Images pinned | PASS | 7 `image:` lines all tagged; verify check 5 PASS |
| AC-10 | Log lines readable and provenance queryable | PARTIAL | Transform + label promotion are configured (`config.alloy:40-94`, `loki:53-61`, `mimir:71`) but the running stack has ingested NO agent telemetry: Loki `service_name` values = `["haproxy-edge"]` only; Loki labels = `[job,service,service_name]` (no `git_*`). Behaviour not observable without agent data |
| AC-11 | Edge proxy is itself observable | PASS | Mimir query `haproxy_process_start_time_seconds` returns a series; Loki `{job="haproxy"}` returns a formatted access line |
| AC-12 | Privacy and teardown documented | PASS | `README.md:196-225` (plaintext, no data leaves, per-flag redaction), `:236-254` (`down` vs `down -v`) |
| AC-13 | Apache-2.0 licensed | PASS | `LICENSE:1-2` |
| AC-14 | One command checks the repository | PASS | `make ci` running: validates compose+haproxy, lints, runs verify, exit 0; `check-selftest: PASS` proves a failing check exits non-zero; `make ci` while down: skips named, exit 0, no false pass; README names it (`:118-124`) |
| AC-15 | Configuration stays self-describing | PASS | Each of 9 config files has exactly one `@agents-index` and a purpose comment |
| AC-16 | Start script blocks until ready | PASS | `stack.up.sh 240` returned only after all six endpoints answered, `up: PASS`, exit 0. Timeout-failure branch (`stack.up.sh:134-139`) code-verified, not runtime-exercised |
| AC-17 | Environment files correct | PASS | `git check-ignore .env` matches, `.env.example` not ignored; `.env.example:16` lists `EDGE_PORT=24317` |
| AC-18 | No hosted dependency | PASS | All storage backends write to local named volumes (`loki/mimir/tempo` configs; `compose.yaml:29-39`); no remote endpoints |
| AC-19 | Local prerequisites documented | PASS | `README.md:54-60`: Docker only, minimum Docker Compose v2 stated |

## Test Strategy Verification

| Test File | Test Name | Specified | Exists | Matches Spec |
|-----------|-----------|-----------|--------|--------------|
| `scripts/stack.verify.sh` | `assert_single_published_port` | yes | yes (`check_single_published_port`, :105) | yes — counts published ports, asserts 127.0.0.1 |
| `scripts/stack.verify.sh` | `assert_backend_readiness` | yes | yes (`check_endpoints`, :134) | yes — six HTTP GETs on EDGE_PORT |
| `scripts/stack.verify.sh` | `assert_datasources_healthy` | yes | yes (`check_datasources`, :158) | yes — three datasource health APIs |
| `scripts/stack.verify.sh` | `assert_no_parent_references` | yes | yes (`check_no_parent_references`, :191) | yes — parent paths + governance IDs |
| `scripts/stack.verify.sh` | `assert_pinned_images` | yes | yes (`check_pinned_images`, :212) | yes — greps compose for `:latest` |
| `scripts/stack.up.sh` | `wait_for_ready` | yes | yes (poll loop, :116-142) | yes — blocks to readiness or names failing endpoint on timeout |

## Diff Coverage

Diff computed against the pre-CR tree (`git diff a85d4c5^...HEAD --stat`; no `origin/main` on this local repo). All 20 changed files map to the CR's Affected Components.

| File | +/- | Mapped Requirements |
|------|-----|---------------------|
| `compose.yaml` | +241 | FR1-FR9, FR22, NFR1,NFR2,NFR5 |
| `Makefile` | +110 | FR23-FR27, AC-14 |
| `README.md` | +288 | FR18,FR19,FR27, NFR3,NFR4, AC-12,AC-19 |
| `LICENSE` | +201 | FR12, AC-13 |
| `.gitignore` | +6 | FR13, AC-17 |
| `.env.example` | +23 | FR14, AC-17 |
| `scripts/stack.up.sh` | +142 | FR11, NFR6, AC-16 |
| `scripts/stack.verify.sh` | +231 | FR10, NFR6, AC-8, Test Strategy |
| `stack/alloy/config.alloy` | +211 | FR20,FR22, AC-10 |
| `stack/grafana/.../datasources.yaml` | +38 | FR6, AC-5 |
| `stack/haproxy/haproxy.cfg` | +169 | FR3,FR8,FR22 |
| `stack/loki/config.yaml` | +73 | FR21, AC-10 |
| `stack/mimir/config.yaml` | +76 | FR21, AC-10 |
| `stack/tempo/config.yaml` | +39 | FR21 |
| `stack/mlflow/Dockerfile` | +20 | FR7, NFR5 |
| `agents/pi-otel.env` | +54 | FR18 (redaction flags) |
| `agents/direnvrc` | +62 | FR21 (provenance stamp) |
| `scripts/.gitkeep`, `stack/.gitkeep` | 0 | scaffolding (Phase 1) |
| `docs/cr/CR-0001-...md` | +132/-24 | governance record (frontmatter → completed, reviewer summary) |

### Unmapped changed files

None. Every changed file falls within the CR's declared Affected Components (`compose.yaml`, `stack/`, `agents/`, `scripts/`, root scaffolding, `docs/cr/`).

## Gaps

None blocking. One PARTIAL and one advisory note:

- **AC-10 (PARTIAL, not a scope gap):** the readable-log-line transform and the git-provenance label promotion are fully present and correct in configuration, but the running stack has ingested no `claude_code.*` / `pi.*` telemetry, so the readable line and the `git_org`/`git_repo`/`git_branch`/`git_path` selectors cannot be observed end to end. Producing agent telemetry is the domain of CR-0003 (pi extension) and normal agent use, not of CR-0001's deliverable. No source fix is warranted; the configuration deliverable is met. If PASS is required, exercise it by driving one agent run through the stack and re-querying Loki.

- **Advisory — orchestrator note mismatch on AC-18/AC-19:** the tasking note characterised AC-18 as "a 5 second dashboard load budget" and AC-19 as "a plugin constraint" belonging to a later dashboard CR. Those criteria do not exist in CR-0001. This CR's AC-18 is "no hosted dependency" and AC-19 is "local prerequisites documented" — both satisfiable and satisfied (PASS above). There is no dashboard-budget or plugin criterion in this CR to record as a GAP.
