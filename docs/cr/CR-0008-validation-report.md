# CR-0008 Validation Report

Audited against the branch diff `git diff a2d76fa...HEAD` (merge-base `origin/main`),
the implementation commits `cff797e`, `996f2c1`, `1aa4620`, `bde0ed9`, `02c1c6d`,
`131b25e`, review `a7c10b6`, finalization `34988c6`. Package unit tests and
`make ci` were run live (both green). Validation date 2026-08-03.

## Summary

Requirements: 28/28 | Acceptance Criteria: 19/19 | Tests: 25/25 unit + `make ci` green | Gaps: 0 (all six former PARTIALs closed with executed evidence on 2026-08-03)

The implementation is broad and honest: every unit-testable requirement is backed
by a passing assertion, and the package's own tests plus `make ci` pass. The six
PARTIAL items shared one root cause: the pi end-to-end path (the enable script's
disclosure and reversal, the `--drive-pi` verifier mode, and the new proxy route's
runtime acceptance) was written and lint-clean but had never been executed against a
real pi turn or a live route probe.

**Gap-fixer update (2026-08-03).** All six were executed against the live stack and
a real pi turn and are now closed; the captured evidence lives under
`docs/cr/CR-0008-evidence/`. Closing FR18/AC-14 additionally surfaced and fixed a
real defect in the verifier: `--drive-pi` installed the extension project-locally
but drove the turn without trusting the project-local files, so headless `pi -p`
silently skipped the untrusted extension and no trace was ever produced (the factory
never ran). The verifier now passes `--approve` on both the install and the run.
Root cause verified by isolation: the same extension loaded directly with `pi -p -e
src/index.ts` produced a correct trace, and a standalone Node harness exercising
config -> experiment-resolve -> OTLP export landed a readable trace, so the export
code was already correct against the pinned `pi@^0.80.3`; only the verifier's trust
handling was wrong. See "Execution Evidence" below. No FAILs at any point: code with
diff evidence existed for every requirement.

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
| FR17 | One script enables/disables, discloses before recording, reverses on disable | FIXED | `scripts/mlflow.tracing.pi.sh:310-333` (disclosure), `:251-276` (disable). Executed 2026-08-03 against an isolated scratch dir (never the user's real pi config): the disclosure prints before any write; declining leaves the switch file absent; confirming writes `PI_MLFLOW_ENABLE=1`; `--disable` prints the reversal and removes the switch file. Evidence: `docs/cr/CR-0008-evidence/fr17-ac12-ac13-enable-disable.txt` |
| FR18 | Verifier gains a mode driving one real pi turn, asserting both turns | FIXED | `scripts/mlflow.tracing.verify.sh:208-263` (`drive_one_pi_turn`). Gap-fixer executed `scripts/mlflow.tracing.verify.sh --drive-pi` against the live stack and a real `pi@0.80.3` turn: `PASS trace 'tr-2389e27e…' in experiment 'pi' carries the user turn and the assistant turn`, exit 0. This required a fix to the verifier (it drove the headless turn without `--approve`, so pi silently skipped the untrusted project-local extension and produced no trace); the run and turn now pass `--approve`. Evidence: `docs/cr/CR-0008-evidence/fr18-ac14-drive-pi.txt` |
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
| AC-1 | Ingest reachable through the single port; Alloy still gets unprefixed paths | FIXED | Route added (`haproxy.cfg:93,106,180-185`), config validates (`check-haproxy` PASS). Live route probe run 2026-08-03: POST of a real OTLP trace export to `/mlflow-otlp/v1/traces` with the experiment header returned **200** (MLflow accepted it); the same POST without the header returned **422** naming the missing `x-mlflow-experiment-id` (proves it reached MLflow, not a 404 and not Alloy); a POST under the `/mlflow` static prefix returned **404** (endpoint served outside the prefix, as the CR states); and a POST to the unprefixed `/v1/traces` returned **200 `{"partialSuccess":{}}`** — Alloy's OTLP-HTTP signature, which MLflow would have 422'd, so Alloy still owns that path. Additionally the FR18/AC-14 `--drive-pi` run exercised the route end to end. Evidence: `docs/cr/CR-0008-evidence/ac-1-route-probe.txt` |
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
| AC-12 | User told before anything is recorded | FIXED | `scripts/mlflow.tracing.pi.sh:310-343` (disclosure before write, confirm gate). Executed 2026-08-03 in an isolated scratch dir: the disclosure names the directory, the file, the switch, the experiment, both addresses, and states it stores every prompt, response, tool input, and tool result; answering anything but "yes" prints "cancelled; no change was made" and leaves the switch file absent (no change until confirmation). Evidence: `docs/cr/CR-0008-evidence/fr17-ac12-ac13-enable-disable.txt` |
| AC-13 | Disabling reverses the change | FIXED | `scripts/mlflow.tracing.pi.sh:251-276`. Executed 2026-08-03: `--disable` removed the switch file (absent afterwards), and a following real pi turn in the now-disabled scratch (extension installed and loaded via `--approve`, but no switch set) produced **no new trace** (experiment count unchanged) while the turn completed normally. Evidence: `docs/cr/CR-0008-evidence/fr17-ac12-ac13-enable-disable.txt` |
| AC-14 | The pi path is proven end to end | FIXED | `scripts/mlflow.tracing.verify.sh --drive-pi` run against the live stack and a real `pi@0.80.3` turn: `PASS trace 'tr-2389e27e…' in experiment 'pi' carries the user turn and the assistant turn`, exit 0. Reaching this required the verifier `--approve` fix described under FR18. Evidence: `docs/cr/CR-0008-evidence/fr18-ac14-drive-pi.txt` |
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
| scripts/mlflow.tracing.verify.sh | drive mode (pi) | Yes (Tests to Modify) | Yes (`--drive-pi`) | Executed end-to-end 2026-08-03: PASS against a real pi turn after the `--approve` fix |
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

All six former PARTIAL gaps are closed as of 2026-08-03. None was ever a FAIL: every one
had real, correct code in the diff; what was missing was executed proof of the runtime
behavior. That proof now exists (see "Execution Evidence"), and closing the pi drive
gap also fixed one real verifier defect.

1. **FR17 / AC-12 / AC-13 (enable, disclose, disable path).** CLOSED. `scripts/mlflow.tracing.pi.sh`
   was executed against an isolated scratch dir (not the user's real pi config, which the
   agent guide reserves for the user's own consent). The disclosure prints before any write
   and names the directory, file, switch, experiment, and both addresses; declining leaves
   no switch file; confirming writes it; `--disable` removes it; and a real pi turn after
   `--disable` produced no new trace. Evidence:
   `docs/cr/CR-0008-evidence/fr17-ac12-ac13-enable-disable.txt`.

2. **FR18 / AC-14 (pi path proven end to end).** CLOSED, with a fix. Executing
   `scripts/mlflow.tracing.verify.sh --drive-pi` first revealed a real defect: the verifier
   installed the extension project-locally and drove the turn without `--approve`, so
   headless `pi -p` silently skipped the untrusted project-local extension and the factory
   never ran (no trace). The extension itself was proven correct by isolation (direct
   `pi -p -e src/index.ts` load produced a trace; a standalone Node harness exercising
   config -> resolve -> OTLP export landed a readable trace). The verifier now passes
   `--approve` on both the install and the run, and the drive mode PASSes end to end against
   a real `pi@0.80.3` turn. Evidence: `docs/cr/CR-0008-evidence/fr18-ac14-drive-pi.txt`;
   fix in `scripts/mlflow.tracing.verify.sh` (`drive_one_pi_turn`).

3. **AC-1 (route reachable; Alloy unaffected).** CLOSED. A live route probe posted a real
   OTLP export to `/mlflow-otlp/v1/traces` (200 accept with the experiment header; 422
   naming the missing header without it, proving MLflow was reached; 404 under the `/mlflow`
   static prefix), and a POST to the unprefixed `/v1/traces` returned Alloy's OTLP-HTTP
   `{"partialSuccess":{}}` 200, proving Alloy still owns that path. The `--drive-pi` run
   also exercised the route end to end. Evidence:
   `docs/cr/CR-0008-evidence/ac-1-route-probe.txt`.

## Execution Evidence (gap fixer, 2026-08-03)

Environment: stack up on the resolved edge port (`EDGE_PORT=24417` from `.env`), runtime
`pi 0.80.3` (extension dev-dependency pinned `^0.80.3`, so no version drift). All commands
were run against the live local stack. Full logs are under `docs/cr/CR-0008-evidence/`.

| What was run | Result | Log |
|--------------|--------|-----|
| Live OTLP route probe (`/mlflow-otlp/v1/traces` with/without header, `/mlflow/v1/traces`, unprefixed `/v1/traces`) | 200 / 422 / 404 / 200 as expected | `ac-1-route-probe.txt` |
| `scripts/mlflow.tracing.verify.sh --drive-pi` (after `--approve` fix) | PASS, `tr-2389e27e…`, exit 0 | `fr18-ac14-drive-pi.txt` |
| `scripts/mlflow.tracing.pi.sh` enable (decline / confirm) and `--disable`, plus a disabled real pi turn | disclosure shown, decline made no change, confirm wrote the switch, disable removed it, disabled turn produced no trace | `fr17-ac12-ac13-enable-disable.txt` |
| `make ci` (full pipeline) after the verifier edit | exit 0, all checks pass | `make-ci.txt` |

Constraint honoured: conversation tracing was never enabled against the user's real pi
configuration. Every enable/disable and every driven pi turn used a throwaway scratch
directory under the system temp area; the `--drive-pi` mode creates and removes its own
scratch dir and never touches this repository or the user's config. Synthetic probe and
harness traces created during isolation were deleted from the `pi` experiment afterwards;
only genuine pi-turn traces remain.

### The one code change made to close a gap

`scripts/mlflow.tracing.verify.sh`, function `drive_one_pi_turn`: added `--approve` to
both the `pi install … -l` and the `pi -p` invocations, with comments explaining that a
project-local extension is untrusted by default and headless pi skips it without the flag.
No change to the extension package, the proxy config, the enable script, or any test — the
extension code was already correct. `make ci` remains green.
