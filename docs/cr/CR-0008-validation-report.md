# CR-0008 Validation Report

Audited against the branch diff `git diff a2d76fa...HEAD` (merge-base `origin/main`),
the implementation commits `cff797e`, `996f2c1`, `1aa4620`, `bde0ed9`, `02c1c6d`,
`131b25e`, review `a7c10b6`, finalization `34988c6`. Package unit tests and
`make ci` were run live (both green). Validation date 2026-08-03.

## Summary

Requirements: 26/28 | Acceptance Criteria: 15/19 | Tests: 25/25 unit + `make ci` green | Gaps: 6 (all PARTIAL, 0 FAIL, 0 GAP)

The implementation is broad and honest: every unit-testable requirement is backed
by a passing assertion, and the package's own tests plus `make ci` pass. The six
PARTIAL items all share one root cause: the pi end-to-end path (the enable script's
disclosure and reversal, the `--drive-pi` verifier mode, and the new proxy route's
runtime acceptance) is **written and lints clean but was never executed against a
real pi turn or a live route probe**. The phase-5 commit body (`02c1c6d`) states
this outright: the enable path "does not run against any real configuration; it was
smoke-tested only against throwaway scratch dirs," and `--drive-pi` is "Never used
by ci." No FAILs: code with diff evidence exists for every requirement.

## Requirement Verification

| Req # | Description | Status | Evidence (file:line / test name) |
|-------|-------------|--------|----------------------------------|
| FR1 | New package `@desek/pi-mlflow-tracing`, Apache-2.0, `pi-package` keyword, repo/homepage/bugs, files list, public access | PASS | `packages/pi-mlflow-tracing/package.json:2-39`; test `manifest is publishable` |
| FR2 | No handler / exporter / socket when switch unset or false | PASS | `src/index.ts:114`; test `registers nothing when disabled` |
| FR3 | Exactly one trace per loop, opened `before_agent_start`, exported `agent_end` | PASS | `src/trace.builder.ts:261,344`; `src/index.ts:169-204`; test `one agent loop makes one trace` |
| FR4 | Root span prompt in `spanInputs`, final text in `spanOutputs`, JSON-encoded | PASS | `src/trace.builder.ts:266-267,354`; test `prompt and response land in the reserved attributes` |
| FR5 | Root span `session.id` from pi session identity | PASS | `src/trace.builder.ts:268`; `src/index.ts:61-67`; test `the root span carries the session id` |
| FR6 | Child span per turn with `mlflow.llm.model` and `mlflow.chat.tokenUsage` | PASS | `src/trace.builder.ts:312-334`; test `token usage lands on the turn span` |
| FR7 | Child span per tool call, parented to its turn, with name/input/result | PASS | `src/trace.builder.ts:279-303,324`; test `a tool call parents to its turn` |
| FR8 | Every export carries `x-mlflow-experiment-id` = resolved id | PASS | `src/mlflow.exporter.ts:28,236`; test `sends the experiment header` |
| FR9 | Resolve experiment by name (default `pi`), refuse when unresolved | PASS | `src/mlflow.experiment.ts:91-127`; `src/index.ts:137-152`; tests `resolves the experiment by name`, `refuses to export on an unknown name` |
| FR10 | Read endpoint/tracking/experiment/headers from env; configured wins | PASS | `src/config.env.ts:230-284`; test `configured values override the defaults` |
| FR11 | Default from `EDGE_PORT`; MUST NOT hard-code the port | PASS | `src/config.env.ts:254-255,263-264`; test `no source file hard-codes the default port` (asserts `24317` absent from all 4 source files) |
| FR12 | Name a non-loopback destination once at session start | PASS | `src/config.env.ts:136-139,268-272`; `src/index.ts:78-88,129-132`; test `a non-loopback destination is flagged` |
| FR13 | Reject a non-absolute-URL endpoint; state value and expected form | PASS | `src/config.env.ts:149-158,199-211`; test `a malformed endpoint is rejected` |
| FR14 | This change publishes nothing; registry only via release automation | PASS | No workflow modified in this diff (`git diff --name-only` has no `.github/`); `publish.yml` pre-exists (CR-0003 `00bd3d0`), tag-triggered, working-dir pinned to `pi-opentelemetry`; test `manifest is publishable` asserts publish access with no trigger |
| FR15 | Proxy route on a distinct prefix, rewritten away; unprefixed still to Alloy | PASS | `stack/haproxy/haproxy.cfg:93,106,180-185` (new `is_mlflow_otlp` ACL, `mlflow_otlp` backend with `replace-path`); Alloy `is_otlp_http` routing untouched in diff; `check-haproxy` PASS validates config |
| FR16 | Silent, no retry, no error output when server unreachable | PASS | `src/mlflow.exporter.ts:244-247`; `src/mlflow.experiment.ts:104-123`; tests `silent when the server is absent`, `silent-eligible when the server is unreachable` |
| FR17 | One script enables/disables, discloses before recording, reverses on disable | PARTIAL | `scripts/mlflow.tracing.pi.sh:310-333` (disclosure), `:251-276` (disable). Script lints clean (`lint-scripts` in `make ci`). No test asserts the disclosure or reversal behavior; the only executing path (`--drive-pi`, manual) was never run — commit `02c1c6d` records "smoke-tested only against throwaway scratch dirs" |
| FR18 | Verifier gains a mode driving one real pi turn, asserting both turns | PARTIAL | `scripts/mlflow.tracing.verify.sh:208-259` (`drive_one_pi_turn`). Mode is written and wired; commit `02c1c6d` states it is "Never used by ci"; no execution evidence a real pi turn produced a trace |
| FR19 | Every failure names what failed, the fixes, what to check | PASS | `src/config.env.ts:199-211`; `src/mlflow.experiment.ts:62-73`; script `fail()` messages; tests assert message content (malformed endpoint, unknown name) |
| FR20 | README for an outside reader + a changelog | PASS | `packages/pi-mlflow-tracing/README.md` (records/enable/disable/off-by-default); `CHANGELOG.md`; test `version agrees with changelog`. Note: changelog is a manual seed; automated production awaits CR-0009 |
| FR21 | User docs: what pi tracing records, where, off by default, point elsewhere, how to delete | PASS | `docs/privacy.md:40-79`; `docs/install.md:122-130`; `docs/reading-data.md:69-76`; `readme.verify` PASS |
| FR22 | Tests under Node built-in runner, no framework dependency | PASS | `package.json:41` (`node --experimental-strip-types --test`); devDependencies hold only `@earendil-works/pi-coding-agent`; 25/25 tests pass |
| NFR1 | A telemetry fault must not crash/block/change pi; handlers wrapped | PASS | `src/index.ts:45-51` and `failSafe` around every registration and body; test `a handler error never propagates` |
| NFR2 | No measurable latency; export after loop, never inside | PASS | `src/mlflow.exporter.ts:225-252` fire-and-forget (not awaited); wired only to `agent_end`/`session_shutdown` in `src/index.ts:197-216` |
| NFR3 | No conversation content retained after export or session end | PASS | `src/trace.builder.ts:357,382-389` (`reset`), `:367-376` (`retainsContent`); exporter keeps only the pending promise; test `content is released after export` |
| NFR4 | Flush pending exports on session shutdown | PASS | `src/index.ts:208-216`; `src/mlflow.exporter.ts:259-261`; test `flushes pending exports on shutdown` |
| NFR5 | Content stays local unless a non-loopback destination is configured; default loopback; remote named | PASS | `src/config.env.ts:136-139,254-272`; disclosures in `src/index.ts` and script; test `a non-loopback destination is flagged` |
| NFR6 | No-op on a machine without this stack; no crash, no error | PASS | `src/index.ts:106-125` (undefined endpoint → return); config leaves endpoint undefined when no `EDGE_PORT`; tests silent/unreachable |

## Acceptance Criteria Verification

| AC # | Description | Status | Evidence |
|------|-------------|--------|----------|
| AC-1 | Ingest reachable through the single port; Alloy still gets unprefixed paths | PARTIAL | Route added (`haproxy.cfg:93,106,180-185`), config validates (`check-haproxy` PASS). No functional probe posts to `/mlflow-otlp/v1/traces`, and no test confirms unprefixed `/v1/traces` still reaches Alloy at runtime — only config-syntax validation, as the CR's own coverage note admits |
| AC-2 | Unconfigured install costs nothing | PASS | test `registers nothing when disabled` |
| AC-3 | One loop becomes one readable conversation | PASS | tests `one agent loop makes one trace`, `prompt and response land in the reserved attributes`, `token usage lands on the turn span`, `a tool call parents to its turn` |
| AC-4 | Traces of one session group together | PASS | test `the root span carries the session id` |
| AC-5 | Experiment resolved, never guessed | PASS | test `refuses to export on an unknown name`; `unknownNameMessage` |
| AC-6 | Default destination is this project's stack; no literal port | PASS | tests `defaults resolve to the local stack`, `no source file hard-codes the default port` |
| AC-7 | Configured endpoint overrides the default | PASS | tests `configured values override the defaults`, `sends the configured extra headers` |
| AC-8 | Off-machine destination stated by extension and enable script | PASS | test `a non-loopback destination is flagged`; `src/index.ts:78-88,129-132`; `scripts/mlflow.tracing.pi.sh:324-328` |
| AC-9 | Malformed endpoint fails loudly | PASS | test `a malformed endpoint is rejected` |
| AC-10 | This change publishes nothing | PASS | No publish workflow in this diff; `publish.yml` pre-exists and is tag-triggered; test `manifest is publishable` |
| AC-11 | Absent server is silent | PASS | tests `silent when the server is absent`, `silent-eligible when the server is unreachable` |
| AC-12 | User told before anything is recorded | PARTIAL | `scripts/mlflow.tracing.pi.sh:310-343` (disclosure before write, confirm gate). No test; not executed end-to-end |
| AC-13 | Disabling reverses the change | PARTIAL | `scripts/mlflow.tracing.pi.sh:251-276` (removes switch file + empty `.pi`). No test; not executed end-to-end |
| AC-14 | The pi path is proven end to end | PARTIAL | `scripts/mlflow.tracing.verify.sh:208-259` (`--drive-pi`) is written and wired but **was never run against a real pi turn**; CI runs assert-only against `claude-code` (observed in `make ci` output). No artifact, log, or scenario shows a real pi turn landing a trace in the `pi` experiment |
| AC-15 | A tracing fault never breaks a turn | PASS | test `a handler error never propagates`; exporter silent-on-failure tests |
| AC-16 | Last conversation of a session is not lost | PASS | test `flushes pending exports on shutdown` |
| AC-17 | Content does not outlive the export | PASS | test `content is released after export` |
| AC-18 | Package readable by a stranger; Node runner, no framework | PASS | `README.md:17-76`; `package.json:41`; test `manifest is publishable` |
| AC-19 | Failures are actionable | PASS | message assertions in `a malformed endpoint is rejected` and `refuses to export on an unknown name`; script `fail()` menus |

## Test Strategy Verification

| Test File | Test Name | Specified | Exists | Matches Spec |
|-----------|-----------|-----------|--------|--------------|
| src/config.env.test.ts | reads the switch and the endpoint | Yes | Yes | Yes |
| src/config.env.test.ts | disabled without the switch | Yes | Yes | Yes |
| src/config.env.test.ts | defaults resolve to the local stack | Yes | Yes | Yes |
| src/config.env.test.ts | configured values override the defaults | Yes | Yes | Yes |
| src/config.env.test.ts | a malformed endpoint is rejected | Yes | Yes | Yes |
| src/config.env.test.ts | a non-loopback destination is flagged | Yes | Yes | Yes |
| src/config.env.test.ts | no source file hard-codes the default port | No (extra) | Yes | Strengthens FR11 |
| src/index.test.ts | registers nothing when disabled | Yes | Yes | Yes |
| src/index.test.ts | a handler error never propagates | Yes | Yes | Yes |
| src/trace.builder.test.ts | one agent loop makes one trace | Yes | Yes | Yes |
| src/trace.builder.test.ts | prompt and response land in the reserved attributes | Yes | Yes | Yes |
| src/trace.builder.test.ts | token usage lands on the turn span | Yes | Yes | Yes |
| src/trace.builder.test.ts | a tool call parents to its turn | Yes | Yes | Yes |
| src/trace.builder.test.ts | the root span carries the session id | Yes | Yes | Yes |
| src/trace.builder.test.ts | content is released after export | Yes | Yes | Yes |
| src/mlflow.exporter.test.ts | sends the experiment header | Yes | Yes | Yes |
| src/mlflow.exporter.test.ts | sends the configured extra headers | Yes | Yes | Yes |
| src/mlflow.exporter.test.ts | silent when the server is absent | Yes | Yes | Yes |
| src/mlflow.exporter.test.ts | flushes pending exports on shutdown | Yes | Yes | Yes |
| src/mlflow.experiment.test.ts | resolves the experiment by name | Yes | Yes | Yes |
| src/mlflow.experiment.test.ts | refuses to export on an unknown name | Yes | Yes | Yes |
| src/mlflow.experiment.test.ts | silent-eligible when the server is unreachable | Yes (named "silent when the server is absent" in spec, exporter-side; resolver variant is present) | Yes | Yes |
| src/package.manifest.test.ts | manifest is publishable | Yes | Yes | Yes |
| src/package.manifest.test.ts | manifest entry point exists on disk and the files list would ship it | No (extra) | Yes | Guards silent no-op |
| src/package.manifest.test.ts | version agrees with changelog | No (extra) | Yes | Strengthens FR20 |
| scripts/mlflow.tracing.verify.sh | drive mode (pi) | Yes (Tests to Modify) | Yes (`--drive-pi`) | Written, not executed end-to-end |
| scripts/pi-package.verify.sh | package checks (both packages) | Yes (Tests to Modify) | Yes | Yes; both packages pass in `make ci` |

All 25 package unit tests pass. `make ci` is green (compose, haproxy config, script lint,
and every verifier, including `pi-package.verify.sh` against both packages and the
assert-only tracing check).

## Diff Coverage

| File | +/- | Mapped Requirements |
|------|-----|---------------------|
| packages/pi-mlflow-tracing/package.json | +51 | FR1, FR14, FR22 |
| packages/pi-mlflow-tracing/package-lock.json | +1992 | FR22 (dependency lock) |
| packages/pi-mlflow-tracing/LICENSE | +201 | FR1 |
| packages/pi-mlflow-tracing/README.md | +88 | FR20, AC-18 |
| packages/pi-mlflow-tracing/CHANGELOG.md | +24 | FR20 |
| packages/pi-mlflow-tracing/src/config.env.ts | +284 | FR2, FR9-FR13, NFR5, NFR6 |
| packages/pi-mlflow-tracing/src/index.ts | +217 | FR2, FR3, FR5, FR9, FR12, FR16, NFR1-NFR6 |
| packages/pi-mlflow-tracing/src/trace.builder.ts | +390 | FR3-FR7, NFR3 |
| packages/pi-mlflow-tracing/src/mlflow.exporter.ts | +262 | FR7, FR8, FR10, FR16, NFR2, NFR4 |
| packages/pi-mlflow-tracing/src/mlflow.experiment.ts | +127 | FR9, FR16, FR19 |
| packages/pi-mlflow-tracing/src/*.test.ts (6 files) | +710 | Test Strategy (FR/NFR/AC assertions) |
| scripts/mlflow.tracing.pi.sh | +386 | FR17, FR19, AC-8, AC-12, AC-13 |
| scripts/mlflow.tracing.verify.sh | +116/-... | FR18, AC-14 |
| scripts/pi-package.verify.sh | +281/-... | FR1, FR22 (both packages) |
| stack/haproxy/haproxy.cfg | +28 | FR15, AC-1 |
| docs/privacy.md | +36 | FR21 |
| docs/install.md | +22 | FR21 |
| docs/reading-data.md | +22 | FR21 |
| AGENTS.md | +21 | FR21 (agent-guide ask-first) |
| docs/cr/CR-0008-*.md | +103 | The CR itself (review + finalize metadata) |

### Unmapped changed files

None. Every changed file falls within the CR's Affected Components (the new package,
`stack/haproxy/haproxy.cfg`, the two scripts, the four docs, and the agent guide).
The pre-existing `.github/workflows/publish.yml` is **not** in this diff, which is
exactly what FR14/AC-10 require.

## Gaps

All six gaps are PARTIAL. None is a FAIL: every one has real, correct code in the diff;
what is missing is executed proof of the runtime behavior.

1. **FR17 / AC-12 / AC-13 (enable, disclose, disable path).** `scripts/mlflow.tracing.pi.sh`
   implements the disclosure, the confirmation gate, and the full reversal, and it lints
   clean. But no test asserts the disclosed text or the reversal, and the only executing
   path (`--drive-pi`) was never run. Commit `02c1c6d` records it was "smoke-tested only
   against throwaway scratch dirs."
   - Suggested minimal fix: run `scripts/mlflow.tracing.pi.sh` (enable then `--disable`)
     against a scratch dir with the stack up and capture the disclosure output and the
     switch-file create/remove, or add a shell-level test asserting the disclosure lines
     and that `--disable` removes the switch file. Record the captured output in the CR.

2. **FR18 / AC-14 (pi path proven end to end).** The `--drive-pi` verifier mode is fully
   written and wired but was never executed against a real pi turn; CI runs assert-only
   against the `claude-code` experiment (confirmed in the live `make ci` output). There is
   no artifact, log, or scenario showing a real pi turn landing a trace in the `pi`
   experiment.
   - Suggested minimal fix: with the stack running and `pi` authenticated, run
     `scripts/mlflow.tracing.verify.sh --drive-pi` once and capture its `PASS` line
     (trace id, both turns present) into the CR's verification record. This is the
     single command the CR names as AC-14's verification path; it exists but has not
     been run.

3. **AC-1 (route reachable; Alloy unaffected).** The `/mlflow-otlp/` route is added and the
   proxy config validates (`haproxy -c`), but nothing posts an OTLP trace export to
   `/mlflow-otlp/v1/traces` to confirm the server accepts it, and nothing confirms the
   unprefixed `/v1/traces` still reaches Alloy at runtime.
   - Suggested minimal fix: add a probe (or extend `stack.verify.sh`) that POSTs a minimal
     OTLP body to `/mlflow-otlp/v1/traces` and asserts a non-404 accept, and asserts a POST
     to `/v1/traces` still lands at Alloy. The `--drive-pi` run in gap 2 would also
     exercise the route end to end and largely retire this gap.
