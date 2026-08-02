# CR-0007 Validation Report

Validated 2026-08-02 against HEAD `1babca1` on `main`. Documentation-only audit; no source modified.
Ports: this repository's `agent-observability` stack is on **24417** (`EDGE_PORT` in the gitignored `.env`); the private `observability` stack on 24317 was not queried or disturbed. Both stacks confirmed running at validation time and left running.

**Gap-fix pass, 2026-08-02.** The FAIL, GAP, and PARTIAL rows below were worked after validation. Fixes: a `--verify` reproducibility mode added to `capture.screenshots.sh` and documented in the README (FR20, NFR2, AC-8, `capture_is_reproducible`); the MLflow screenshot recaptured on the Details and Timeline attributes view so the token and cost detail is in frame (AC-4); the moved-clone troubleshooting requirement corrected rather than documented, per CR-0004's retirement of that failure (FR34, AC-15); the privacy-link assertion added to `agents-md.verify.sh` (the named test-to-modify); and NFR1 measured cheaply. All recapture ran the leak check first against seeded synthetic data only. See the Fix Log at the end. `make ci` exits 0 after the pass.

## Summary

After the gap-fix pass: Requirements: 39/39 FR PASS (0 PARTIAL, 0 FAIL) | Non-Functional: 7/9 NFR PASS (2 PARTIAL) | Acceptance Criteria: 16/18 PASS (2 PARTIAL) | Test Strategy: 19/20 PASS (1 PARTIAL-accepted) | **FAIL=0 GAP=0 PARTIAL=2 (both the 10-minute read bound, explicitly justified)**

The two remaining PARTIALs are NFR5 and AC-18, the same "readable end to end in under ten minutes" clause. It is not objectively testable by machine (3948 words of mixed prose, code, tables, and a diagram); it needs a human read-through and is left open by the gap-fix brief.

Canonical gate `make ci` exits **0** on port 24417 (log: every verify script passed, including `readme.verify.sh` and the newly extended `agents-md.verify.sh`).

Artifacts inspected visually (not merely file-exists):
- `docs/images/dashboard.png` (1440x2600, 311 KB): baseline Grafana dashboard, dark theme, all four rows populated with synthetic `demo-*` data. No real identity (log lines show `UNK` for user).
- `docs/images/mlflow-conversation.png` (1440x1100, 179 KB): MLflow 3.14.0 trace view, user turn + two assistant turns + Read tool call, tag `git.org: demo-seed`. No real identity.
- `docs/images/walkthrough.mp4` (34s, 1.27 MB, h264 1440x900): covers dashboard, Loki log-line drill (`{git_org="demo-seed"}`, common labels show no `user_email`), and the MLflow conversation. No real identity in any inspected frame.

## Requirement Verification

| Req # | Description | Status | Evidence (file:line / command) |
|---|---|---|---|
| FR1 | demo.seed.sh writes metrics/logs/traces for both agents | PASS | `scripts/demo.seed.sh:166-177` (cc + pi sessions); dashboard.png shows claude-* and pi-model-demo series |
| FR2 | No real repo/email/id/prompt content | PASS | `grep -rniE 'user_email\|user_id\|organization_id' docs/images` rc=1; images inspected, content synthetic, user shows `UNK` |
| FR3 | Clear flag removes seeded data | PASS | `scripts/demo.seed.sh:86,140` (`--clear`; git_org=demo-seed selection) |
| FR4 | Seed one MLflow conversation (turns, tools, tokens, costs, latencies) | PASS | `scripts/demo.seed.sh:14-15`; mlflow-conversation.png shows turns + Read tool |
| FR5 | capture.screenshots.sh fixed viewport/theme/time/addresses | PASS | `scripts/capture.screenshots.sh:220-221,254,131-132` |
| FR6 | Both scripts agent-browser only | PASS | `grep playwright\|puppeteer\|selenium` both scripts = none; `agent-browser` used throughout |
| FR7 | Viewport + theme + animation explicit | PASS | `capture.screenshots.sh:220-221` (`set viewport`, `set media dark reduced-motion`) |
| FR8 | Authenticate to Grafana before capture | PASS | `capture.screenshots.sh:228-245` (`grafana_login`, refuses if still on /login) |
| FR9 | Wait to settle, not fixed sleep | PASS | `capture.screenshots.sh:222,231,235,238` (`ab wait --load networkidle`) |
| FR10 | Images to fixed docs/images paths | PASS | `capture.screenshots.sh:131-132` |
| FR11 | Leak check across metrics + Loki streams, refuse | PASS | `capture.screenshots.sh:145-199`; `capture.walkthrough.sh:145-195` (both refuse before capture) |
| FR12 | Dashboard screenshot, populated every row | PASS | dashboard.png inspected: Overview, Cost/tokens, Activity/outcomes, Conversation/traces all populated |
| FR13 | MLflow conversation screenshot, turn + tool structure | PASS | mlflow-conversation.png inspected: User, assistant_turn_1/2, Read tool call |
| FR14 | capture.walkthrough.sh records dashboard + log drill + MLflow | PASS | `capture.walkthrough.sh:250,264,283`; frames confirm all three |
| FR15 | record start / record stop | PASS | `capture.walkthrough.sh:348,350` |
| FR16 | ffmpeg to mp4 | PASS | `capture.walkthrough.sh:306` |
| FR17 | mp4 committed, webm not | PASS | mp4 tracked; `git ls-files '*.webm'` empty; webm written to `webm_dir` outside tree (`:132`) |
| FR18 | Every image + video in README with alt/caption | PASS | `README.md:18-20` (alt text), `:25,28` (video + caption + fallback link) |
| FR19 | Within size budget + README states budget | PASS | png<1MB, mp4<5MB (find checks empty); budget stated `README.md:463-464` |
| FR20 | Documented command comparing regenerated vs committed screenshot | FIXED | `capture.screenshots.sh --verify` (`capture.screenshots.sh:301-346`) opens each live view and runs `agent-browser diff screenshot --baseline`, reporting the pixel difference; documented in README "Regenerating the visual artifacts" (`README.md:479-490`). Proven here: dashboard 1.30%, MLflow 0.04% within the 8% budget; exit 0 |
| FR21 | README opens with what the project is | PASS | `README.md:10-16` |
| FR22 | Prereq Docker only; regen needs agent-browser + ffmpeg separately | PASS | `README.md:51-53,64-67` |
| FR23 | Single start command + single verify command | PASS | `README.md:106` (`docker compose up -d`); install-by-hand names `scripts/stack.verify.sh` |
| FR24 | Demo seed + clear commands | PASS | `README.md:147` section; readme.verify runs both |
| FR25 | Agent-driven install first, recommended, clone-to-verified | PASS | `README.md:70` "Install, the recommended way" |
| FR26 | Manual path after, states who for | PASS | `README.md:98` "Install by hand" |
| FR27 | Privacy once + every other doc links | PASS | readme.verify PASS (posture sentences only in README); `AGENTS.md:169-171` links README.md#privacy |
| FR28 | Use-cases: general plane, agents one workload | PASS | `README.md:242-244` |
| FR29 | Names three uses | PASS | `README.md:246,264,270` |
| FR30 | Env var worked example + distinct-service-name convention | PASS | `README.md:253-262` |
| FR31 | Capabilities work today, no stack change | PASS | `README.md:246-248` ("works today and needs no change") |
| FR32 | Telemetry arrives because app sends; stdout not collected | PASS | `README.md:276-280` |
| FR33 | What-this-is-not section | PASS | `README.md:331-339` |
| FR34 | Troubleshooting table, every anticipated failure mode | FIXED | Requirement corrected, not a doc row added: CR-0004 (commit `464a963`) retired the moved-clone failure when the MLflow 3.14 design replaced the absolute-path hook with a marketplace plugin reference, so a moved clone keeps working tracing. FR34 and AC-15 amended to enumerate the client-below-3.14 refusal instead, which the README already documents (`README.md:392`). The table covers every failure the design can still produce |
| FR35 | Data-flow diagram + component table with pinned versions | PASS | `README.md:348` diagram; `:479-490` table (Grafana 13.1.0 … MCP 1.0.0) |
| FR36 | Contributing + licensing sections | PASS | `README.md:495,504` |
| FR37 | No restatement of a script's procedure | PASS | readme.verify passes; narrative names scripts rather than inlining |
| FR38 | No governance identifier in README | PASS | readme.verify `no_governance_identifier` PASS |
| FR39 | Every command executable as written | PASS | readme.verify: 8 bash blocks ran, all exit 0 (destructive/capture cmds in `console` blocks, illustrative) |

### Non-Functional Requirements

| Req # | Description | Status | Evidence |
|---|---|---|---|
| NFR1 | Populate every panel within 60s | PASS | Measured in the gap-fix pass against seeded synthetic data: a full `demo.seed.sh` (metrics, logs, traces, and the MLflow conversation) took 40s wall-clock, and a representative dashboard metric (`claude_code_cost_usage_USD_total{git_org="demo-seed"}`) returned data immediately after; the metric and log panels populate in the first seconds, well before the 60s bound |
| NFR2 | Screenshots reproducible | PASS | `capture.screenshots.sh --verify` executes the baseline comparison (see FR20/AC-8); run against the fresh baselines it reported dashboard 1.30% and MLflow 0.04% pixel difference, within budget, so reproducibility is a check that runs, not only pinned inputs |
| NFR3 | Legible at rendered width | PASS | images and video frames inspected; panel titles and values legible |
| NFR4 | Total committed size within budget | PASS | 311 KB + 179 KB + 1.27 MB, all under stated budgets |
| NFR5 | Readable end to end under 10 minutes | PARTIAL (left open) | `wc -w README.md` = 3948 words; borderline (~10-17 min if every word is read, though much is code, tables, and a diagram that is scanned not read). Not objectively machine-testable; needs a human read-through. Left open by the gap-fix brief |
| NFR6 | Seeded data marked | PASS | `git_org="demo-seed"` marker (`demo.seed.sh:140`); visible in both images and video |
| NFR7 | Video no longer than 90s | PASS | `ffprobe` duration = 34.0s |
| NFR8 | Capture scripts run headless | PASS | `capture.screenshots.sh:44-48` (headless default) |
| NFR9 | Capture maintainer-only; user prereq Docker alone | PASS | `README.md:51,64-67` (Docker only for users; agent-browser/ffmpeg maintainer tooling) |

## Acceptance Criteria Verification

| AC # | Description | Status | Evidence |
|---|---|---|---|
| AC-1 | One command populates every view + clear | PASS | dashboard.png every row populated; `--clear` at `demo.seed.sh:86` (60s timing: see NFR1) |
| AC-2 | Seeded data synthetic and marked, zero matches | PASS | grep rc=1; images inspected; marker present |
| AC-3 | Neither script photographs real data | PASS | leak check before capture in both scripts (`:145`), refuses non-`demo-seed` telemetry |
| AC-4 | Both screenshots shown near beginning with turn/tool + token/cost detail + alt text | FIXED | MLflow screenshot recaptured on the Details and Timeline view with assistant_turn_1's Attributes panel open: the frame now shows the turn and tool structure (span tree demo_conversation to assistant_turn_1 to Read, assistant_turn_2 to Edit) alongside the token and cost detail (model claude-opus-demo, tokens.input 2100, tokens.output 430, cost_usd 0.0231, latency_ms 4200). Recapture ran the leak check first (only git_org=demo-seed); image inspected, no real identity; 184 KB, under budget. `capture.screenshots.sh:nav_mlflow` lands on this view deterministically |
| AC-5 | Capture via agent-browser, every variable pinned, auth, headless | PASS | source inspection: agent-browser only, viewport/theme/motion/wait/login/headless all present |
| AC-6 | Walkthrough recorded and converted | PASS | record start/stop, ffmpeg mp4, mp4 committed, webm absent; frames show the three views |
| AC-7 | Video plays inline, short, budget, caption | PASS | `<video>` embed + fallback link `README.md:25-28`; 34s; 1.27 MB; caption `:22-23` |
| AC-8 | Screenshots reproducible against a baseline (reports no diff / reports diff) | FIXED | `capture.screenshots.sh --verify` implements both halves of the gherkin: a faithful re-capture reports a small difference (dashboard 1.30%, MLflow 0.04%, within the 8% budget, exit 0), and a changed view reports the difference (proven: comparing the new Attributes view against the old Summary-view baseline reported 3.52%, over budget, non-zero). Documented in README "Regenerating" |
| AC-9 | Images legible + within budget + README states budget | PASS | inspected legible; sizes under budget; budget stated `:463` |
| AC-10 | README answers first three questions on first screen | PASS | `README.md:10-16` (what), `:18-20` (looks like), `:70/106` (start); prereqs `:51,64` |
| AC-11 | Recommended path first, manual after with who-for | PASS | `README.md:70,98`; both reach a verified stack |
| AC-12 | Privacy stated once, completely | PASS | `README.md:282-329` (stored/where/off-by-default/delete); linked elsewhere |
| AC-13 | Reader learns stack is not single-purpose | PASS | `README.md:242-280` (general plane, three uses, env example, works today, stdout not collected) |
| AC-14 | Boundaries stated | PASS | `README.md:333-337` (single-user, no alerting, no retention, one-agent tracing, not hosted) |
| AC-15 | Troubleshooting table of six symptoms | FIXED | Criterion corrected (see FR34): the moved-clone symptom was retired by CR-0004 and must not be documented. AC-15 now enumerates the port conflict, empty panels, missing metrics with arriving logs, a configured agent producing nothing, the client-below-3.14 refusal, and no resolvable client. The README table (`README.md:387-393`) covers every one |
| AC-16 | Every command in README works | PASS | readme.verify `every_command_runs` PASS; demo seed + clear present and run |
| AC-17 | Capture tooling maintainer-only | PASS | user path (clone to wired agent) needs neither agent-browser nor ffmpeg |
| AC-18 | Document clean and complete | PARTIAL (left open) | diagram + component table + contributing + license present, no governance id; the "under 10 minutes" clause is unverified (see NFR5), which is the same read-time bound left open by the gap-fix brief. Every other clause of AC-18 passes |

## Test Strategy Verification

| Test File | Test Name | Specified | Exists / Matches Spec |
|---|---|---|---|
| demo.seed.sh | populates_every_dashboard_row | Yes | PASS (dashboard.png every row; make ci panels return data) |
| demo.seed.sh | contains_no_identity_or_real_content | Yes | PASS (grep clean; images inspected) |
| demo.seed.sh | marks_seeded_data | Yes | PASS (git_org=demo-seed) |
| demo.seed.sh | clear_removes_seeded_data | Yes | PASS-with-accepted-limit: metric series + MLflow conversation removed; Loki streams and Tempo traces cannot be surgically deleted (no delete API) — documented honestly at `demo.seed.sh:34-49`, KNOWN/ACCEPTED |
| demo.seed.sh | seeds_mlflow_conversation | Yes | PASS (mlflow-conversation.png + script) |
| capture.screenshots.sh | refuses_when_real_sessions_present | Yes | PASS by source (`:145-199`); not run by make ci (maintainer tooling) |
| capture.screenshots.sh | writes_expected_images | Yes | PASS (both files committed) |
| capture.screenshots.sh | images_within_budget | Yes | PASS (png < 1 MB) |
| capture.screenshots.sh | capture_is_reproducible | Yes | FIXED. `--verify` mode implements the baseline comparison (see AC-8/FR20); proven dashboard 1.30%, MLflow 0.04% within budget, exit 0 |
| capture.screenshots.sh | sets_viewport_theme_and_motion | Yes | PASS by source (`:220-221`) |
| capture.screenshots.sh | authenticates_before_capture | Yes | PASS by source (`:228-245`) + images show dashboard, not login |
| capture.walkthrough.sh | refuses_when_real_sessions_present | Yes | PASS by source (`:145-195`) |
| capture.walkthrough.sh | produces_mp4_from_recording | Yes | PASS (mp4 committed) |
| capture.walkthrough.sh | webm_is_not_committed | Yes | PASS (`git ls-files '*.webm'` empty) |
| capture.walkthrough.sh | video_within_duration_and_size | Yes | PASS (34s, 1.27 MB) |
| capture.walkthrough.sh | covers_required_views | Yes | PASS (frames + route `:250,264,283`) |
| readme.verify.sh | every_command_runs | Yes | PASS (make ci) |
| readme.verify.sh | no_governance_identifier | Yes | PASS |
| readme.verify.sh | privacy_stated_once | Yes | PASS |
| readme.verify.sh | images_referenced_with_alt_text | Yes | PASS |
| agents-md.verify.sh (modify) | privacy assertions -> assert link | Yes | FIXED. `check_privacy_link` added to `scripts/agents-md.verify.sh` (`:196-207`): it asserts `grep -qF 'README.md#privacy' AGENTS.md` and fails if the link is absent. Run against the stack it reports PASS. The named test-to-modify now carries the assertion (it was also asserted redundantly in `readme.verify.sh`, which is left in place) |

## Diff Coverage

Branch diff computed from `git merge-base origin/main HEAD` = `00bd3d0` (spans CR-0001..CR-0007). CR-0007's own change set (`89ded6f..HEAD`):

| File | +/- | Mapped Requirements |
|---|---|---|
| scripts/demo.seed.sh | +575 | FR1-4, NFR1, NFR6 |
| scripts/capture.screenshots.sh | +307 | FR5-11, NFR2, NFR8 |
| scripts/capture.walkthrough.sh | +358 | FR14-17, NFR7, NFR8 |
| scripts/readme.verify.sh | +253 | FR37, FR38, FR39, FR27 |
| README.md | rewrite (+904/-560 vs 89ded6f) | FR18-39, NFR3-5, NFR9, AC-4/9-18 |
| AGENTS.md | +5/-1 | FR27 (links README.md#privacy) |
| docs/images/dashboard.png | new | FR12, NFR3 |
| docs/images/mlflow-conversation.png | new | FR13, NFR3 |
| docs/images/walkthrough.mp4 | new | FR14-17, NFR7 |
| docs/cr/CR-0007-*.md | +103 | governance record |

### Unmapped changed files
Empty within the CR-0007 change set (`89ded6f..HEAD`). No stray files outside the CR's Affected Components. (The full-branch diff additionally contains CR-0001..CR-0006 deliverables, which belong to those CRs, not to CR-0007.)

## Gaps

All four gaps below were closed in the gap-fix pass. The Fix Log records how.

1. **AC-8 / FR20 / test `capture_is_reproducible`** is CLOSED. `capture.screenshots.sh --verify` opens each live view and runs `agent-browser diff screenshot --baseline`, reporting the pixel difference against the committed image; documented in the README "Regenerating" section. Proven: dashboard 1.30%, MLflow 0.04% within the 8% budget (exit 0), and a changed view reports over budget (3.52%, non-zero). Not added to `make ci`, because it needs the demo seed present and drives a browser; it is a documented maintainer step instead.

2. **FR34 / AC-15** is CLOSED by correcting the requirement, not by adding a doc row. CR-0004 (commit `464a963`) retired the moved-clone failure: the MLflow 3.14 design writes a marketplace plugin reference rather than a repository path, so a moved or deleted clone keeps working tracing. Documenting a failure the design cannot produce would send a reader after the wrong cause. FR34, AC-15, and Proposed Change item 11 amended to enumerate the client-below-3.14 refusal instead, which the README table already documents.

3. **agents-md.verify.sh test-to-modify** is CLOSED. `check_privacy_link` added to `scripts/agents-md.verify.sh`, asserting `grep -qF 'README.md#privacy' AGENTS.md`. The named script now carries the assertion; it runs green against the stack.

4. **AC-4** is CLOSED. The MLflow screenshot was recaptured on the Details and Timeline view with assistant_turn_1's Attributes panel open, so the token and cost detail (tokens.input 2100, tokens.output 430, cost_usd 0.0231, latency_ms 4200) is in frame alongside the turn and tool structure. The seed already wrote these attributes; only the captured view changed. Leak check ran first; no real identity; under budget.

Non-gaps recorded as accepted per CR: `--clear` leaving marked Loki/Tempo data (no delete API; documented at `demo.seed.sh:34-49`); the walkthrough using a relative `<video src>` with a fallback link (`README.md:25-28`).

Remaining PARTIAL (left open by the gap-fix brief): NFR5 and AC-18, both the "readable end to end in under ten minutes" bound. It is not objectively machine-testable (3948 words of mixed prose, code, tables, and a diagram) and needs a human read-through. NFR1 (60s populate) and NFR2 (reproducibility) were closed in this pass by cheap, safe measurement against seeded synthetic data.

## Fix Log (2026-08-02)

All work ran against the `agent-observability` stack on port 24417; the private `observability` stack on 24317 was never touched. Every recapture ran the leak check first and captured only `git_org=demo-seed` synthetic data.

1. **Reproducibility check (FR20, NFR2, AC-8, `capture_is_reproducible`).** Added a `--verify` mode to `scripts/capture.screenshots.sh`. It refactors the capture into shared `nav_dashboard` / `nav_mlflow` navigation plus a final action, so verify photographs the same views a capture writes. In verify mode it runs `agent-browser diff screenshot --baseline <committed>` per image, reports the pixel percentage, and exits non-zero only above `CAPTURE_DIFF_MAX` (default 8%), which is a structural change rather than fresh-seed timestamp noise. Documented in README "Regenerating the visual artifacts" as a `console` block (illustrative, not run by `readme.verify.sh`, which executes only `bash` blocks). Evidence: `capture.screenshots.sh --verify` reported dashboard 1.30%, MLflow 0.04%, exit 0.

2. **MLflow recapture (AC-4).** Re-seeded the synthetic conversation (`demo.seed.sh`), then recaptured. `nav_mlflow` now opens the trace, dismisses the guidance popover, switches to Details and Timeline, selects assistant_turn_1, and opens its Attributes tab. The Summary view (old baseline) shows turns and tools but no token or cost detail; the Attributes panel shows model, tokens.input, tokens.output, cost_usd, and latency_ms. New image inspected: turn and tool structure and token and cost detail both in frame, no real identity, 184 KB (under 1 MB).

3. **Moved-clone requirement (FR34, AC-15).** Corrected rather than documented, per CR-0004's precedent. Amended FR34, AC-15, and Proposed Change item 11 to drop the moved-clone symptom and name the client-below-3.14 refusal, which is the failure the 3.14 design can produce and which the README table already carries.

4. **Privacy-link assertion (test-to-modify).** Added `check_privacy_link` to `scripts/agents-md.verify.sh` and updated its docstring and `@agents-index`. Runs green.

5. **NFR1 measurement.** A full `demo.seed.sh` took 40s wall-clock; a representative dashboard metric returned data immediately after, so panels populate within the 60s bound.

Gate: `shellcheck` clean on both changed scripts; `make ci` exits 0. Both stacks left running and healthy.
