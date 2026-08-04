# CR-0009 Validation Report

Validated 2026-08-04 against the repository at HEAD (main). CR-0009 was
implemented on `main` rather than a feature branch, on purpose: FR20 requires a
real release, and a real release requires real merges to the default branch.
The diff is therefore traced over the CR phase-commit range
`da1baed^..1cedc9f`, and the requirements are cross-checked against external
reality (the npm registry, the git remote's tags, the GitHub releases, the
release-workflow run history, and live executions of both verification scripts)
rather than against the source alone.

## Summary

Requirements: 28/28 (FR 23/23, NFR 5/5) | Acceptance Criteria: 18/18 | Tests: 16/16 | Gaps: 0

External reality confirms the design end-to-end:

- `npm view @desek/pi-opentelemetry versions` -> `['0.1.0','0.1.1']`
- `npm view @desek/pi-mlflow-tracing versions` -> `['0.0.1','0.1.0']`
- `git ls-remote --tags origin` -> component-scoped tags only (`pi-opentelemetry-v0.1.0`, `pi-opentelemetry-v0.1.1`, `pi-mlflow-tracing-v0.1.0`); no bare `v<version>` tag exists.
- `gh release list` -> a GitHub release for each of those tags.
- `scripts/release.verify.sh` exits 0 for both released versions and exits 1 for `@desek/pi-opentelemetry 9.9.9`.

## Requirement Verification

| Req # | Description | Status | Evidence (file:line / runtime) |
|---|---|---|---|
| FR1 | config declares both packages, node type | PASS | `release-please-config.json:5-11` (both paths, `release-type: node`) |
| FR2 | manifest records every declared package's version | PASS | `.release-please-manifest.json:2-3` |
| FR3 | manifest records pi-opentelemetry at the published version | PASS | manifest `0.1.1`; `npm view` latest published is `0.1.1` |
| FR4 | already-published release recorded as component tag and release | PASS | `git ls-remote` tag `pi-opentelemetry-v0.1.0`; `gh release list` release `pi-opentelemetry-v0.1.0` (2026-08-03) |
| FR5 | every tag carries `<component>-v<version>` | PASS | all remote tags are component form; zero bare `v` tags |
| FR6 | each package gets its own release PR | PASS | `release-please-config.json:3` `separate-pull-requests: true`; PRs #7 (mlflow) and #8 (opentelemetry) are separate |
| FR7 | a one-package commit does not release the other | PASS | run 30918687560 published only `packages/pi-opentelemetry`; run 30912352978 published only `packages/pi-mlflow-tracing` |
| FR8 | automation runs from a workflow reading config+manifest by path | PASS | `.github/workflows/release.yml:75-87` (`config-file`, `manifest-file` inputs) |
| FR9 | publish in the same run, gated on released-paths | PASS | `release.yml:99-115` (`needs: release-please`, `if: releases_created=='true'`, matrix from `paths_released`); run logs confirm |
| FR10 | publish job holds id-token; trust names the workflow file | PASS | `release.yml:120-122` `id-token: write`; provenance-carrying publishes prove the registry trust relationship names `release.yml` |
| FR11 | trusted publishing over OIDC, no stored token | PASS | `release.yml:195-198` (no `NODE_AUTH_TOKEN`); grep finds no npm token in any workflow; provenance present on registry |
| FR12 | refuse a version already on the registry, state version and fix | PASS | `release.yml:178-192` names package, version, and fix; npm duplicate rejection is the backstop |
| FR13 | publish only the packages reported as released | PASS | `release.yml:112-115` matrix over `paths_released`; run logs show one publish leg per released package |
| FR14 | CI runs unit tests and install smoke for both packages | PASS | `ci.yml:60-86` unit matrix over configured packages; `ci.yml:88-101` smoke via `scripts/pi-package.verify.sh` |
| FR15 | every squash subject is a Conventional Commit; doc states it and what it controls | PASS | `docs/contributing.md:94-112` |
| FR16 | one script validates config against packages on disk | PASS | `scripts/release.config.verify.sh`; live-tested for undeclared package and version drift (see AC-9/AC-10) |
| FR17 | doc states how a release happens and what a contributor does or does not do | PASS | `docs/contributing.md:105-112` |
| FR18 | every failure names what failed, fixes, what to check after | PASS | `release.config.verify.sh` (all four checks), `release.verify.sh`, and `release.yml:168-172,188-192` follow the pattern |
| FR19 | runbook states the whole loop as numbered steps, each wait named | PASS | `docs/release-runbook.md:47-107` (steps 1-8; waits at 3, 6, 7 name what and where) |
| FR20 | one complete release rehearsal producing a real published version | PASS | two real releases on the registry; run history 30918687560 and 30912352978 |
| FR21 | rehearsal recorded (package, version, tag, release, artifact) | PASS | CR Rehearsal Record table `CR-0009...md:605-608` |
| FR22 | script verifies a completed release from outside | PASS | `scripts/release.verify.sh` ran: exit 0 for both released versions, exit 1 for a never-released version |
| FR23 | new package seeded so its first proposed release is its intended first version | PASS | `release.config.verify.sh:64,168-172` (0.0.0 sentinel); mlflow-tracing published `0.1.0` via automation, `0.0.1` was the documented hand bootstrap |
| NFR1 | config is the single statement of releasable packages | PASS | `ci.yml:50-58` derives the test matrix from config keys; no second list |
| NFR2 | no hand-typed version or changelog | PASS | release-please derives both; generated CHANGELOGs; AC-11 |
| NFR3 | nothing publishes without a merged release PR | PASS | `release.yml:104` gate; run 30918963699 shows `publish` skipped on a non-releasing push |
| NFR4 | a third package needs only a config+manifest entry | PASS | grep of workflows: package names appear only in comments (`release.yml:64`, `ci.yml:43-44`), never in executable logic; matrices derive from config/`paths_released` |
| NFR5 | automation holds no registry credential | PASS | no npm token in any workflow; OIDC only |

## Acceptance Criteria Verification

| AC # | Description | Status | Evidence |
|---|---|---|---|
| AC-1 | config names both packages | PASS | `release-please-config.json:5-11`, `.release-please-manifest.json:2-3` |
| AC-2 | automation starts from what is published, proposes no existing version | PASS | manifest seeded to published version; registry has a clean `0.1.0`->`0.1.1` sequence with no duplicate proposal; non-releasing pushes cut no release |
| AC-3 | a tag names its package, no bare tag | PASS | `git ls-remote` all component-form; zero bare `v` tags |
| AC-4 | one package's change does not release the other | PASS | separate PRs #7/#8; run logs show a single publish leg per release |
| AC-5 | release run publishes only what it released; no release => skip | PASS | run 30918963699 `publish` skipped; releasing runs each have exactly one matrix leg |
| AC-6 | publication needs no stored credential | PASS | `release.yml:120-122,195-198`; provenance on registry proves OIDC trust |
| AC-7 | a published version is never republished | PASS | `release.yml:178-192` states package, version, fix; npm duplicate rejection backstop |
| AC-8 | both packages tested on every change | PASS | `ci.yml:60-86` unit matrix + `ci.yml:88-101` smoke |
| AC-9 | undeclared package fails a check | PASS | live test in scratch copy: script exits 1 naming `packages/pi-newcomer` and the entry to add |
| AC-10 | manifest cannot drift from packages | PASS | live test: script exits 1 naming both values (`0.2.0` vs `0.1.0`) and which to change |
| AC-11 | release needs no hand version or changelog | PASS | release-please derives; generated CHANGELOG entries |
| AC-12 | convention stated where a contributor reads it | PASS | `docs/contributing.md:94-112` |
| AC-13 | whole loop written with wait points and the one-time act | PASS | `docs/release-runbook.md:47-137` |
| AC-14 | the loop is run once, for real | PASS | rehearsal: real publishes, tags, releases; run history |
| AC-15 | completed release verifiable from outside, non-zero when missing | PASS | `release.verify.sh` ran: exit 0 both, exit 1 for `9.9.9` |
| AC-16 | the runbook matches what happened (8 rehearsal findings) | PASS | all eight findings present: PR-permission setting (runbook:37-45), release-PR gets no CI (157-165), literal-version test (170-173), changelog-agreement check (174-178), static outputs map (179-183), Release-As footer scope (145-149), sticky `release-as` (150-155), bootstrap hand publish (109-137) |
| AC-17 | a third package needs only two entries | PASS | proven by inspection: no package named in workflow executable logic; `ci.yml:50-58` and `release.yml:112-115` derive from config/`paths_released` |
| AC-18 | the unpublished new package can publish its first version | PASS | mlflow-tracing `0.1.0` proposed and published via automation (run 30912352978, publish leg success); `0.0.1` is the documented hand bootstrap |

## Test Strategy Verification

| Test File | Test Name | Specified | Exists | Matches Spec |
|---|---|---|---|---|
| `release.config.verify.sh` | every package is declared | yes | yes (`:105-124`) | yes (live-tested, names undeclared package) |
| `release.config.verify.sh` | every declared package exists | yes | yes (`:129-145`) | yes |
| `release.config.verify.sh` | manifest and package versions agree | yes | yes (`:150-195`) | yes (live-tested, names disagreement and fix) |
| `release.config.verify.sh` | both files parse | yes | yes (`:77-100`) | yes |
| `release.config.verify.sh` | usage without arguments | yes | yes (`:206-209`) | yes (no-arg prints usage, exit 0) |
| `release.verify.sh` | the tag and the release exist | yes | yes | yes (ran: PASS for both, FAIL/exit1 for `9.9.9`) |
| `release.verify.sh` | the version is on the registry | yes | yes | yes (ran) |
| `release.verify.sh` | the artifact carries provenance | yes | yes | yes (ran: provenance PASS for both) |
| `release.verify.sh` | a missing release fails | yes | yes | yes (exit 1 for `9.9.9`) |
| `ci.yml` (modify) | unit job over configured matrix | yes | yes (`:60-86`) | yes |
| `ci.yml` (modify) | smoke job unchanged, both packages | yes | yes (`:88-101`) | yes |
| `publish.yml` -> `release.yml` (modify) | publish inside release run | yes | yes (`release.yml:99-198`) | yes (`publish.yml` deleted in e1e5a2e) |
| `release.yml` (modify) | version-agreement guard vs manifest | yes | yes (`:156-173`) | yes |
| `pi-package.verify.sh` (modify) | no change required | yes | yes (unchanged) | yes |
| `Makefile` (modify) | ci runs release-config validation unconditionally | yes | yes (`:34,44-51`, `check-release-config` prerequisite; `verify:102-103` skips it) | yes |
| `publish.yml` (remove) | changelog heading assertion removed | yes | removed | yes (no changelog check in `release.yml`) |

## Diff Coverage

Diff computed over the CR phase range `da1baed^..1cedc9f` (work landed on `main`).

| File | +/- | Mapped Requirements |
|---|---|---|
| `release-please-config.json` | +12 | FR1, FR6, NFR1 |
| `.release-please-manifest.json` | +4 | FR2, FR3, FR23 |
| `.github/workflows/release.yml` | +198 | FR8, FR9, FR10, FR11, FR12, FR13, NFR3, NFR4 |
| `.github/workflows/ci.yml` | +/-61 | FR14, NFR1, NFR4, AC-8 |
| `.github/workflows/publish.yml` | -106 | Tests-to-remove; FR9 (publish moved into release run) |
| `Makefile` | +/-29 | FR16, quality-standard `make ci` wiring |
| `scripts/release.config.verify.sh` | +216 | FR16, FR18, AC-9, AC-10, NFR1 |
| `scripts/release.verify.sh` | +225 | FR22, FR18, AC-15 |
| `docs/contributing.md` | +21 | FR15, FR17, AC-12 |
| `docs/release-runbook.md` | +208 | FR19, AC-13, AC-16 |
| `packages/pi-opentelemetry/CHANGELOG.md` | +/-20 | FR (changelog generated), AC-11 |
| `packages/pi-mlflow-tracing/CHANGELOG.md` | +50 | FR23, AC-11, AC-18 (bootstrap note) |
| `packages/pi-opentelemetry/package.json` + lock | +/-6 | FR20 (rehearsal bump to 0.1.1) |
| `packages/pi-opentelemetry/src/package.manifest.test.ts` | +/-32 | rehearsal finding #3 (literal-version pin removed) |
| `packages/pi-mlflow-tracing/src/package.manifest.test.ts` | +/-32 | rehearsal finding #3 |
| `README.md` | +1 | runbook link (docs) |
| `.agents/rollback/2026-08-04-phantom-mlflow-tracing-release.md` | +79 | FR20/FR21 rehearsal recovery record |
| `docs/cr/CR-0009-monorepo-release-management.md` | +96 | the CR itself (Rehearsal Record) |

### Unmapped changed files

None. Every changed file maps to a CR Affected Component (root config/manifest,
`.github/workflows/`, both packages' CHANGELOG and released state, `scripts/`,
the runbook, contributor documentation, or git tags and releases). The two
`package.manifest.test.ts` edits and the rollback record are within scope: they
are the rehearsal's own findings and recovery, which FR20/FR21 require.

## Gaps

None.

### Notes on evidence strength (not gaps)

- AC-7 / FR12 (republish refusal) and AC-17 / NFR4 (third-package extensibility)
  are verified by inspection of the workflow logic plus the surrounding runtime
  evidence, not by an isolated run that exercised those exact branches. The
  republish guard's refuse branch was not observed firing in isolation (npm's
  own duplicate rejection is the backstop), and no literal third package was
  added. Both mechanisms are nonetheless demonstrable: the guard message meets
  FR18, and a grep proves no workflow names any package in executable logic.
- The registry trust relationship (FR10) is configured on npmjs.org and cannot
  be read from the repository; the provenance-carrying publishes are the proof
  it correctly names `.github/workflows/release.yml`.
