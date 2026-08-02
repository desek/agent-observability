# CR-0007 Validation Report

Validated 2026-08-02 against HEAD `1babca1` on `main`. Documentation-only audit; no source modified.
Ports: this repository's `agent-observability` stack is on **24417** (`EDGE_PORT` in the gitignored `.env`); the private `observability` stack on 24317 was not queried or disturbed. Both stacks confirmed running at validation time and left running.

## Summary

Requirements: 37/39 FR PASS (2 PARTIAL, 0 FAIL) | Non-Functional: 5/9 NFR PASS (4 PARTIAL) | Acceptance Criteria: 14/18 PASS (3 PARTIAL, 1 GAP) | Test Strategy: 16/20 PASS (1 PARTIAL-accepted, 3 GAP) | **FAIL=0 PARTIAL=9 GAP=4**

Canonical gate `make ci` exits **0** on port 24417 (log: every verify script passed, including `readme.verify.sh`).

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
| FR20 | Documented command comparing regenerated vs committed screenshot | PARTIAL | `agent-browser diff screenshot --baseline` appears ONLY in this CR (`:600`); absent from README "Regenerating" section, from `capture.screenshots.sh`, and from make ci. Reproducibility stays a claim, not a check |
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
| FR34 | Troubleshooting table, every anticipated failure mode | PARTIAL | `README.md:383-394`: 5 of 6 AC-15 symptoms present; "conversation tracing stopped after the clone moved" (CR-0004 hook path) is not a row |
| FR35 | Data-flow diagram + component table with pinned versions | PASS | `README.md:348` diagram; `:479-490` table (Grafana 13.1.0 … MCP 1.0.0) |
| FR36 | Contributing + licensing sections | PASS | `README.md:495,504` |
| FR37 | No restatement of a script's procedure | PASS | readme.verify passes; narrative names scripts rather than inlining |
| FR38 | No governance identifier in README | PASS | readme.verify `no_governance_identifier` PASS |
| FR39 | Every command executable as written | PASS | readme.verify: 8 bash blocks ran, all exit 0 (destructive/capture cmds in `console` blocks, illustrative) |

### Non-Functional Requirements

| Req # | Description | Status | Evidence |
|---|---|---|---|
| NFR1 | Populate every panel within 60s | PARTIAL | dashboard.png + make ci verify prove every row populates from seed; the 60s bound not timed (seed not re-run to avoid disturbing the live stack) |
| NFR2 | Screenshots reproducible | PARTIAL | `capture.screenshots.sh` pins viewport/theme/motion/waits (supports it), but no baseline comparison executes, so reproducibility is not verified as a check (see FR20/AC-8) |
| NFR3 | Legible at rendered width | PASS | images and video frames inspected; panel titles and values legible |
| NFR4 | Total committed size within budget | PASS | 311 KB + 179 KB + 1.27 MB, all under stated budgets |
| NFR5 | Readable end to end under 10 minutes | PARTIAL | `wc -w README.md` = 3840 words; borderline (~10-17 min if every word read; much is code/tables/diagram). Not precisely testable; could-not-verify against the 10-minute bound |
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
| AC-4 | Both screenshots shown near beginning with turn/tool + token/cost detail + alt text | PARTIAL | dashboard + MLflow both near top (`README.md:18-20`) with alt text; MLflow Summary view shows turns and Read tool but **token and cost detail are not visible** in the committed frame (only latency 29.50ms shown) |
| AC-5 | Capture via agent-browser, every variable pinned, auth, headless | PASS | source inspection: agent-browser only, viewport/theme/motion/wait/login/headless all present |
| AC-6 | Walkthrough recorded and converted | PASS | record start/stop, ffmpeg mp4, mp4 committed, webm absent; frames show the three views |
| AC-7 | Video plays inline, short, budget, caption | PASS | `<video>` embed + fallback link `README.md:25-28`; 34s; 1.27 MB; caption `:22-23` |
| AC-8 | Screenshots reproducible against a baseline (reports no diff / reports diff) | GAP | No baseline-comparison check exists anywhere in the repo (scripts/README/Makefile); the behavior is neither implemented nor run |
| AC-9 | Images legible + within budget + README states budget | PASS | inspected legible; sizes under budget; budget stated `:463` |
| AC-10 | README answers first three questions on first screen | PASS | `README.md:10-16` (what), `:18-20` (looks like), `:70/106` (start); prereqs `:51,64` |
| AC-11 | Recommended path first, manual after with who-for | PASS | `README.md:70,98`; both reach a verified stack |
| AC-12 | Privacy stated once, completely | PASS | `README.md:282-329` (stored/where/off-by-default/delete); linked elsewhere |
| AC-13 | Reader learns stack is not single-purpose | PASS | `README.md:242-280` (general plane, three uses, env example, works today, stdout not collected) |
| AC-14 | Boundaries stated | PASS | `README.md:333-337` (single-user, no alerting, no retention, one-agent tracing, not hosted) |
| AC-15 | Troubleshooting table of six symptoms | PARTIAL | 5 of 6 present; "tracing stopping after the clone moved" missing (see FR34) |
| AC-16 | Every command in README works | PASS | readme.verify `every_command_runs` PASS; demo seed + clear present and run |
| AC-17 | Capture tooling maintainer-only | PASS | user path (clone to wired agent) needs neither agent-browser nor ffmpeg |
| AC-18 | Document clean and complete | PARTIAL | diagram + component table + contributing + license present, no governance id; the "under 10 minutes" clause is unverified (see NFR5) |

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
| capture.screenshots.sh | capture_is_reproducible | Yes | GAP — no baseline comparison implemented (see AC-8/FR20) |
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
| agents-md.verify.sh (modify) | privacy assertions -> assert link | Yes | GAP — `scripts/agents-md.verify.sh` was NOT modified in the CR-0007 commits and contains no README/privacy/link assertion. The link is instead asserted by `readme.verify.sh` (`grep -qF 'README.md#privacy' AGENTS.md`), so FR27 holds, but the specified test modification was not applied |

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

1. **AC-8 / FR20 / test `capture_is_reproducible` (GAP/PARTIAL)** — the baseline reproducibility check does not exist in the repository. `agent-browser diff screenshot --baseline` appears only inside this CR document, not in the "Regenerating the visual artifacts" README section, not in `capture.screenshots.sh`, and not in make ci. *Minimal fix:* add a `--verify`/baseline-diff step to `capture.screenshots.sh` (or a small verify script) that runs `agent-browser diff screenshot --baseline docs/images/dashboard.png`, and document the command in the README regeneration section.

2. **FR34 / AC-15 (PARTIAL)** — the troubleshooting table covers 5 of the 6 enumerated symptoms; "conversation tracing stopped after the clone was moved" (the CR-0004 absolute-path hook failure) has no row. *Minimal fix:* add one row: symptom "tracing stopped after moving the clone", cause "the autolog hook stored an absolute path to the old location", fix "re-run `scripts/mlflow.autolog.claude.sh` from the new path".

3. **agents-md.verify.sh test-to-modify (GAP)** — the specified modification (assert AGENTS.md links to the README rather than restating the posture) was not applied to `scripts/agents-md.verify.sh`. The assertion exists elsewhere (`readme.verify.sh`), so the underlying requirement holds. *Minimal fix:* add a `grep -qF 'README.md#privacy' AGENTS.md` assertion to `scripts/agents-md.verify.sh`, or record the relocation of the assertion in the CR.

4. **AC-4 (PARTIAL)** — the committed MLflow screenshot shows the user turn, two assistant turns, and the Read tool call, but does not visibly show token and cost detail (only latency 29.50ms is on-frame). The seed does write tokens/costs (FR4), and turn/tool structure (FR13) is fully met. *Minimal fix (optional):* recapture with a span expanded to reveal token/cost attributes, or accept turn+tool+latency as sufficient and relax AC-4's wording.

Non-gaps recorded as accepted per CR: `--clear` leaving marked Loki/Tempo data (no delete API; documented at `demo.seed.sh:34-49`); the walkthrough using a relative `<video src>` with a fallback link (`README.md:25-28`).

Timing NFRs (NFR1 60s, NFR5 10-minute read) and reproducibility (NFR2) are marked PARTIAL because they require running the capture/seed pipeline against the live stack, which would write to and disturb it; the committed artifacts and make ci evidence substantiate the observable outcomes but not the timing bounds.
