# CR-0005 Validation Report

Validated 2026-08-02 against the running `agent-observability` stack on host port **24417** (EDGE_PORT from the gitignored `.env`; container frontend 24317). The separate private `observability` stack on 24317 was never queried or disturbed. Both stacks were left running.

## Summary

Requirements: 33/33 PASS (27 FR + 6 NFR) | Acceptance Criteria: 15/15 PASS | Test Strategy: 14/14 add-tests PASS, 1/2 modify-tests PASS (1 GAP) | Gaps: 1

- `make ci` exit 0. `mcp.verify.sh`, `deeplink.sh --self-check`, `agents-md.verify.sh`, `stack.verify.sh` all exit 0.
- Own MCP handshake through port 24417: **22 tools, 0 write tools**.
- Single-published-port invariant holds after the MCP service was added: only `agent-observability-haproxy-1` publishes a host port (`127.0.0.1:24417`); `mcp-grafana` and `grafana` expose ports but publish none.
- Known accepted divergence recorded (trace tool category); see Gaps.

## Requirement Verification

Port used for every runtime check below: **24417**.

| Req # | Description | Status | Evidence (file:line / command) |
|-------|-------------|--------|--------------------------------|
| FR1 | AGENTS.md at root, CLAUDE.md symlink to it | PASS | `AGENTS.md:1`; `ls -l CLAUDE.md` → `CLAUDE.md -> AGENTS.md`; `readlink` = AGENTS.md |
| FR2 | States it is a copyable example and what to change | PASS | `AGENTS.md:7-16` (three change items) |
| FR3 | One command to tell if stack is running | PASS | `AGENTS.md:33-38` (curl `$B/api/health`); `agents-md.verify.sh` every_command_runs PASS |
| FR4 | Backend addresses via port variable, not literal | PASS | `AGENTS.md:44-51`; `agents-md.verify.sh` no_literal_port PASS |
| FR5 | Real metric names + `type` label + which labels per agent | PASS | `AGENTS.md:53-70`; `agents-md.verify.sh` every_metric_name_exists PASS (7 names) |
| FR6 | Worked query each for Mimir/Loki/Tempo/MLflow; MLflow v3 `locations` body | PASS | `AGENTS.md:82-137` (MLflow uses `/mlflow/api/3.0/.../traces/search` + `locations`, states empty is expected); every_command_runs PASS |
| FR7 | Instruct building links via deeplink.sh | PASS | `AGENTS.md:139-150` |
| FR8 | States telemetry content + Loki line reveals `user_email` + never public | PASS | `AGENTS.md:163-173` |
| FR9 | Prefer link over quoting conversation | PASS | `AGENTS.md:174-176` |
| FR10 | Ask-first: start/stop, dashboard, tracing | PASS | `AGENTS.md:180-188` |
| FR11 | Compose includes MCP service, pinned tag | PASS | `compose.yaml:191-192` `grafana/mcp-grafana:1.0.0` |
| FR12 | MCP publishes no host port | PASS | `docker compose ps` mcp-grafana no publisher; mcp.verify PASS |
| FR13 | MCP reaches Grafana by service name | PASS | `compose.yaml:207` `GRAFANA_URL: http://grafana:3000` |
| FR14 | Credentials only in compose env, not in .mcp.json/docs | PASS | `compose.yaml:207-209`; `grep` .mcp.json → none |
| FR15 | HAProxy routes one prefix + health-checks backend | PASS | `haproxy.cfg:85,99,168-171` (backend mcp, `option httpchk GET /healthz`) |
| FR16 | Writing tools disabled by default | PASS | `compose.yaml:203` `-disable-write`; own handshake 0 write tools |
| FR17 | Enabled categories restricted to running products | PASS | `compose.yaml:204-205`; handshake shows only search/datasource/dashboard/prometheus/loki/navigation, no admin/alerting/etc |
| FR18 | README documents enabling writes + consequence | PASS | `README.md:452-465` (single change + administrator consequence) |
| FR19 | .mcp.json wires agent through single port | PASS | `.mcp.json:4-9` (`http://localhost:24317/grafana-mcp/mcp`) |
| FR20 | .mcp.json no token/secret/absolute path | PASS | `grep -nEi 'token\|secret\|password\|/Users/\|/home/' .mcp.json` → exit 1 |
| FR21 | README placement (project + machine) + stdio alternative | PASS | `README.md:414-450` |
| FR22 | deeplink.sh generates 4 link kinds | PASS | `deeplink.sh`; generated all four, self-check PASS |
| FR23 | deeplink.sh derives host+port from variable | PASS | `EDGE_PORT=39999 deeplink.sh metrics up` → carries `localhost:39999` |
| FR24 | Link format verified vs pinned Grafana + version recorded | PASS | `deeplink.sh:22-37` records Grafana 13.1.0 and per-kind format |
| FR25 | self-check asserts links resolve | PASS | `deeplink.sh --self-check` exit 0 (all four) |
| FR26 | mcp.verify.sh asserts reachable/list/categories/no-write | PASS | `mcp.verify.sh` exit 0, 5 assertions |
| FR27 | Every script `-h`, non-zero on failure, actionable errors | PASS | `-h` all exit 0; `fail()` three-part; dead-port run exits 1 with fix |
| NFR1 | Single-published-port preserved after MCP added | PASS | `docker ps` only haproxy publishes; stack.verify assert_single_published_port PASS |
| NFR2 | MCP not reachable from outside the machine | PASS | published mapping is `127.0.0.1:24417->24317` (loopback bind); off-machine test not possible but binding is the control |
| NFR3 | AGENTS.md short, facts before explanation | PASS | 188 lines; `AGENTS.md:18-19` states facts-first; ordering confirmed |
| NFR4 | Every fact verifiable by a command in the file | PASS | agents-md.verify every_command_runs + every_metric_name_exists PASS |
| NFR5 | MCP not required; shell fallback documented | PASS | `AGENTS.md:156-161`; every MCP capability has a shell recipe |
| NFR6 | Adding MCP does not change existing routes | PASS | grafana/mimir/loki/tempo/mlflow readiness all 200 through 24417 |

## Acceptance Criteria Verification

| AC # | Description | Status | Evidence / command (port 24417) |
|------|-------------|--------|--------------------------------|
| AC-1 | Instruction file teaches stack accurately | PASS | `agents-md.verify.sh` exit 0 (commands run, metrics exist, port-variable addresses) |
| AC-2 | Reusable elsewhere; CLAUDE.md same content; facts first | PASS | `AGENTS.md:7-16`; symlink; `AGENTS.md:18-19` |
| AC-3 | Privacy + ask-first stated as rules | PASS | `AGENTS.md:163-188` |
| AC-4 | MCP internal, no new port, Grafana by service name | PASS | `docker ps`; `compose.yaml:207`; loopback bind |
| AC-5 | MCP answers through single port, backend healthy | PASS | own handshake session id + tools; `haproxy.cfg:168-171` health check; mcp.verify PASS |
| AC-6 | Tool set restricted and read-only | PASS | 22 tools, 0 write, only 6 running-product categories (own handshake) |
| AC-7 | No secret needed anywhere | PASS | `.mcp.json` grep exit 1; MCP connects with nothing pasted (handshake succeeded) |
| AC-8 | Deep links open intended view; self-check; AGENTS.md points to script | PASS | self-check exit 0; dashboard uid resolves to "Coding Agent Observability"; datasources typed prometheus/loki/tempo; `AGENTS.md:139-150`. Note: view fidelity asserted structurally (uid + datasource type + embedded query + HTTP 200), not by browser render |
| AC-9 | Links follow configured port | PASS | `EDGE_PORT=39999` → link carries `localhost:39999` |
| AC-10 | Link format recorded with verified version | PASS | `deeplink.sh:22-37` records Grafana 13.1.0 |
| AC-11 | Writing tools opt-in + consequence stated | PASS | `README.md:452-465` (remove `-disable-write`; administrator consequence) |
| AC-12 | MCP an improvement, not a requirement | PASS | `AGENTS.md:156-161`; NFR5 |
| AC-13 | No existing route regresses | PASS | 5 existing readiness endpoints all 200 |
| AC-14 | Verification executable, incl. negative path | PASS | mcp.verify exit 0 on live stack; `EDGE_PORT=45999` run exits 1 naming failure + fix |
| AC-15 | Config placement + stdio alternative documented | PASS | `README.md:414-450` |

## Test Strategy Verification

| Test File | Test Name | Specified | Exists | Matches Spec |
|-----------|-----------|-----------|--------|--------------|
| scripts/mcp.verify.sh | server_reachable_through_single_port | yes | yes | PASS |
| scripts/mcp.verify.sh | no_additional_published_port | yes | yes | PASS |
| scripts/mcp.verify.sh | tools_listed | yes | yes | PASS (22) |
| scripts/mcp.verify.sh | expected_categories_present | yes | yes | PASS (6 categories; trace category absent by design — see Gaps) |
| scripts/mcp.verify.sh | no_write_tools_by_default | yes | yes | PASS (0) |
| scripts/deeplink.sh | dashboard_link_resolves | yes | yes | PASS |
| scripts/deeplink.sh | metrics_link_resolves | yes | yes | PASS |
| scripts/deeplink.sh | logs_link_resolves | yes | yes | PASS |
| scripts/deeplink.sh | trace_link_resolves | yes | yes | PASS |
| scripts/deeplink.sh | uses_configured_port | yes | yes | PASS |
| scripts/agents-md.verify.sh | every_command_runs | yes | yes | PASS (6 blocks) |
| scripts/agents-md.verify.sh | every_metric_name_exists | yes | yes | PASS (7 names) |
| scripts/agents-md.verify.sh | no_literal_port | yes | yes | PASS |
| scripts/agents-md.verify.sh | no_secret_in_mcp_config | yes | yes | PASS |
| scripts/stack.verify.sh (modify) | assert_single_published_port also covers MCP | yes | yes | PASS (counts publishers across all services incl. mcp-grafana) |
| scripts/stack.verify.sh (modify) | assert_backend_readiness also checks MCP backend through proxy | yes | **no** | **GAP** — see below |

## Diff Coverage

Branch diff computed from `git merge-base origin/main HEAD` = `00bd3d0`. CR-0005 implementation commits: `426aa17` (review) → `fd9289d` (finalize). Files changed by CR-0005 (`git diff 426aa17..fd9289d --name-only`):

| File | Mapped Requirements |
|------|---------------------|
| AGENTS.md | FR1-FR10, NFR3, NFR4, NFR5 |
| CLAUDE.md (symlink) | FR1 |
| .mcp.json | FR19, FR20 |
| compose.yaml | FR11, FR12, FR13, FR14, FR16, FR17, NFR1, NFR2 |
| stack/haproxy/haproxy.cfg | FR15, NFR6 |
| scripts/deeplink.sh | FR7, FR22, FR23, FR24, FR25 |
| scripts/mcp.verify.sh | FR26, FR27 |
| scripts/agents-md.verify.sh | NFR4 (Test Strategy add-test file) |
| README.md | FR18, FR21 |
| docs/cr/CR-0005-agent-interface-mcp-grafana.md | self (CR + review summary) |

### Unmapped changed files

- `docs/cr/CR-0006-agent-driven-install-path.md`, `docs/cr/CR-0007-readme-screenshots-onboarding.md`: each a one-line frontmatter fix replacing the stale `source-commit: none (repository has no commits yet)` placeholder with `7db5fe3`. Documentation maintenance, not source; justified, no scope leak.
- Note: `scripts/stack.verify.sh` appears in the full merge-base diff but was **not** touched by any CR-0005 commit (last change `e232d37`, CR-0004). This is the substance of the GAP below.

## Gaps

1. **GAP — Test Strategy "Tests to Modify": `scripts/stack.verify.sh` / `assert_backend_readiness` was not modified to check the MCP backend through the proxy.** The CR Test Strategy specifies that `stack.verify.sh` gains an MCP-backend readiness check "through the proxy". The script's endpoint list (`stack.verify.sh:137-144`) still covers only loki, mimir, tempo, alloy, grafana, mlflow — no `/grafana-mcp/` entry — and `grep -ni mcp scripts/stack.verify.sh` returns nothing. `git log 426aa17..fd9289d -- scripts/stack.verify.sh` is empty, confirming zero CR-0005 changes.
   - Impact: low. The MCP backend readiness through the single port is fully proven by `scripts/mcp.verify.sh` (handshake + HAProxy `/healthz` health check), which `make ci` runs; and `make ci` also runs `stack.verify.sh`. The capability is covered; only the specific test-modification named in the strategy is absent.
   - Suggested minimal fix: add `"/grafana-mcp/mcp|mcp-grafana"` (or a `/healthz`-equivalent probe) to the `check_endpoints` pairs array in `scripts/stack.verify.sh`, or add a short note to the CR Test Strategy that MCP readiness is delegated to `mcp.verify.sh` (also invoked by `make ci`).

## Recorded Divergence (accepted, not a failure)

- The CR's `expected_categories_present` wording implies a trace tool category. `grafana/mcp-grafana:1.0.0` exposes no dedicated trace category; traces are reached via the datasource tools and the Tempo datasource. `mcp.verify.sh` and its docstring (`mcp.verify.sh:13-15,145-146`) assert the six categories that exist (search, datasource, dashboard, prometheus, loki, navigation) and explicitly do not assert a trace tool. The CR wording is stale; the implementation and verification are correct. Recorded as an accepted divergence, not a gap.

## Operational Confirmation

Both stacks left running and untouched: `agent-observability-haproxy-1` (127.0.0.1:24417) and `observability-haproxy-1` (127.0.0.1:24317). Only port 24417 was queried; 24317 was never contacted.
