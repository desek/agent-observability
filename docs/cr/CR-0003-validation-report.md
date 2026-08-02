# CR-0003 Validation Report

Validator: CR Validator (documentation-only audit). No source was modified.
Date: 2026-08-02. Repo root: `/Users/desek/Repo/desek/experiments/agent-observability`.

## Summary

Requirements (FR 1-31 + NFR 1-6 = 37): PASS 32 | PARTIAL 5 | FAIL 0 | GAP 0
Acceptance Criteria (AC 1-16): PASS 12 | PARTIAL 4 | FAIL 0 | GAP 0
Tests: unit suite 36/36 PASS; install smoke test `scripts/pi-package.verify.sh` exit 0.

Everything PARTIAL is PARTIAL for one of two honest reasons: (a) the check needs an
authenticated npm session or the GitHub secret list, and the bootstrap npm token was
revoked, so it cannot be run here; or (b) the criterion is a runtime latency/gallery
assertion with no automated test and no manual step run in this session. No requirement
is downgraded to hide a defect. One documentation gap (the contributor local-install
path, FR26) is called out under Gaps.

### Port and version discipline

- This repository's stack uses `EDGE_PORT=24417` (read from the gitignored `.env`).
  A **separate private stack** answers on `24317`. Both were confirmed up and left
  running. Every measurement below names the port it used.
- Tooling: `node v24.15.0`, `npm 11.12.1` (local). Published package: `@desek/pi-opentelemetry@0.1.0`. pi entry loader verified with `jiti@2.7.0`.
- Registry facts were read **unauthenticated** from `https://registry.npmjs.org`.

### Clean-install entry-point check (the silent-no-op guard)

`bash scripts/pi-package.verify.sh` → exit 0. It packs the working tree, installs the
tarball into a clean temp project, reads `pi.extensions` from the installed manifest,
resolves `./src/index.ts` on disk, and loads it through `jiti@2.7.0`:
```
pi-package.verify: PASS the manifest, README, LICENSE, and entry point are present
pi-package.verify: PASS manifest entry resolves on disk
pi-package.verify: PASS loaded ./src/index.ts -> function factory
pi-package.verify: PASS all checks
```
The published packument also confirms `pi:{"extensions":["./src/index.ts"]}` on the
registry copy. The entry point ships and resolves after a real install: **PASS**.

## Diff basis note

`git merge-base origin/main HEAD` = `00bd3d0`, which already sits **inside** the
CR-0003 commit chain (origin/main is not pre-CR). The strict `merge-base...HEAD` diff
therefore shows only the finalization commit. The full CR-0003 implementation spans
`1199a45...HEAD` (commits `78fdb5b` through `72d5e3e`); that range is used as the diff
evidence below. `git diff 1199a45...HEAD --name-only` lists all 29 changed files; no
changed file falls outside the CR's Affected Components (see Diff Coverage).

## Requirement Verification

| Req # | Description | Status | Evidence (file:line / test / command + port) |
|-------|-------------|--------|-----------------------------------------------|
| FR1 | Source at `packages/pi-opentelemetry/`, one concern per file + sibling tests | PASS | `find packages/pi-opentelemetry/src` = 9 source `.ts` + 9 sibling `.test.ts` (plus manifest/pi-sdk tests) |
| FR2 | Named `@desek/pi-opentelemetry` | PASS | `package.json:2`; registry `name: @desek/pi-opentelemetry` (unauth) |
| FR3 | No `private` | PASS | `package.json` has no `private`; `package.manifest.test.ts:74` asserts absent |
| FR4 | Apache-2.0 + license file | PASS | `package.json:5`; `LICENSE:1-2` "Apache License Version 2.0" |
| FR5 | repository/homepage/bugs point at this repo | PASS | `package.json:8-16`; `package.manifest.test.ts:79-84` |
| FR6 | `pi-package` in keywords | PASS | `package.json:18`; registry keywords include `pi-package` (unauth) |
| FR7 | publishConfig public access | PASS | `package.json:37-39`; registry copy fetched anonymously (is public) |
| FR8 | Explicit files list, no test/dev/lock published | PASS | `package.json:30-36`; `npm pack --dry-run` = 13 files, no `.test.ts`, no lockfile; verify.sh checks 1-2 PASS |
| FR9 | engines + CI tests every named version | PASS | `package.json:27-29` (`>=22.14.0`); `.github/workflows/ci.yml:39` matrix `22.14.0, 22, 24` |
| FR10 | pi entry proven to load from tarball by automated test | PASS | `scripts/pi-package.verify.sh` exit 0; `src/pi-sdk.exporter.test.ts` loads via pi's jiti path |
| FR11 | `@opentelemetry/api` is a peer dependency | PASS | `package.json:48-50`; test `api package is a peer dependency` PASS |
| FR12 | No signal/exporter when switch false | PASS | `src/index.ts:68`; test `no-op when the master switch is off` PASS (in-process gRPC receiver, 0 exports) |
| FR13 | Silent, no error above debug, when no collector | PASS | `src/index.ts` `failSafe`/try-catch; test `silent when the collector is unreachable` PASS |
| FR14 | Content flags default off | PASS | `src/config.env.ts:153-160,361-367`; test `content-gating` PASS |
| FR15 | No exception into agent, no block/delay | PASS | `src/index.ts:36-42,74-199` every handler wrapped in `failSafe`; test `handler-failsafe-and-flush` PASS |
| FR16 | README no private refs | PASS | `grep -rE 'pi-extensions/\|link-pi.sh\|agent-orchestration\|CR-[0-9]{4}'` over package = exit 1 (no match) |
| FR17 | README documents every var: default, effect, content recorded | PASS | `README.md:99-171` config tables + content-flag "Records" column |
| FR18 | README verification procedure | PASS | `README.md:222-262` "Verify it is exporting" |
| FR19 | README troubleshooting, cause+fix | PASS | `README.md:264-293` six named causes with fixes |
| FR20 | CHANGELOG dated heading | PASS | `CHANGELOG.md:8` `## 0.1.0 - 2026-08-02` |
| FR21 | CI runs unit tests every Node version on push+PR | PASS | `.github/workflows/ci.yml:18-57` |
| FR22 | CI install smoke test packs/installs/loads entry | PASS | `.github/workflows/ci.yml:59-72`; `scripts/pi-package.verify.sh` exit 0 |
| FR23 | Publish workflow: tag-triggered, trusted publishing OIDC, provenance auto | PASS | `.github/workflows/publish.yml:16-27,103-106` (workflow correct; see provenance note re the already-published 0.1.0) |
| FR24 | Publish fails when version already on registry | PASS | `publish.yml:88-100` (curl HTTP 200 guard) |
| FR25 | manifest/changelog/tag agreement, verified | PASS | `publish.yml:60-83` |
| FR26 | Repo docs state BOTH install paths (registry + local for contributors) | PARTIAL | Registry path in `packages/pi-opentelemetry/README.md:24-26`; contributor local-path documented **nowhere** (root `README.md` never mentions the package). See Gaps |
| FR27 | `id-token: write` permission | PASS | `publish.yml:27` |
| FR28 | npm >=11.5.1, node >=22.14.0 in publish | PASS | `publish.yml:46` (`22.14.0`), `:50` (`npm@^11.5.1`) |
| FR29 | No long-lived npm token as repo secret | PARTIAL | `publish.yml` references no `NODE_AUTH_TOKEN`/secret (evidence for). Cannot enumerate GitHub repo secrets unauthenticated; needs `gh secret list` (authenticated) |
| FR30 | Trust created with `npm trust github` naming publish.yml + repo | PARTIAL | Command documented `docs/cr/...:265`. Per implementation facts the CLI returned 400 and trust was set via the npmjs.com web UI instead; trust state not verifiable unauthenticated (`npm trust list` needs auth). Known issue recorded below |
| FR31 | Repo documents four-step bootstrap | PASS | `docs/cr/CR-0003-...:261-268` states implement, publish with temp token, `npm trust github`, revoke. Note: lives only in the CR, not a user-facing doc |
| NFR1 | <=100ms added to startup when enabled+healthy | PARTIAL | Design is async health probe + lazy provider init (`src/index.ts:55-86`); no startup-latency measurement exists in the suite. Not measured |
| NFR2 | No measurable turn latency when collector unreachable | PARTIAL | `failSafe` + `doesNotReject` in `silent when the collector is unreachable`; no latency figure measured |
| NFR3 | No native compile at install | PASS | verify.sh clean `npm install` of tarball succeeds; deps are pure-JS (`@grpc/grpc-js` is the pure-JS impl) |
| NFR4 | Tarball excludes tests, lockfile, stack-config | PASS | `npm pack --dry-run` = 13 files; verify.sh checks 1-2 PASS |
| NFR5 | Unit tests run without network/running stack | PASS | `npm test` 36/36 PASS locally; tests use in-process receivers (`src/pi-sdk.exporter.test.ts:97,139`) |
| NFR6 | Functions on a machine without the stack by staying silent | PASS | dynamic-default health gate `src/config.env.ts:303-311`; tests `unhealthy-when-unreachable`, `silent when the collector is unreachable` PASS |

## Acceptance Criteria Verification

| AC # | Description | Status | Evidence (test / command + port) |
|------|-------------|--------|----------------------------------|
| AC-1 | Package is publishable (name/private/license/repo/keywords/publishConfig/files/engines/peer/changelog) | PASS | `package.manifest.test.ts` `manifest declares publishable fields` PASS; registry copy confirms name, `license: Apache-2.0`, keyword `pi-package` (unauth) |
| AC-2 | Registry install loads the extension | PASS | `scripts/pi-package.verify.sh` exit 0; `pi loads the extension and all three signals reach the collector` PASS |
| AC-3 | Tarball ships only intended files | PASS | verify.sh checks 1-3 PASS; `npm pack --dry-run` 13 files, README+LICENSE+manifest+`src/index.ts` present, no test/lock |
| AC-4 | No-op when switched off | PASS | `no-op when the master switch is off` PASS (0 exports at in-process gRPC receiver) |
| AC-5 | Silent without a collector | PASS | `silent when the collector is unreachable` + `unhealthy-when-unreachable` PASS (latency sub-clause not measured; behavior verified) |
| AC-6 | Content logging opt-in | PASS | `content-gating` PASS |
| AC-7 | Never breaks the agent; startup <100ms | PARTIAL | Fail-safe proven (`handler-failsafe-and-flush`, `doesNotReject` cases); the <100ms startup sub-clause is not measured by any test |
| AC-8 | Docs serve a stranger | PASS | `README.md` install/enable/config/content-privacy/verify/troubleshoot; no private ref (FR16 grep) |
| AC-9 | CI on every supported Node version, offline | PASS | `ci.yml:39` matrix; `npm test` 36/36 offline (in-process servers). CI run itself not observed here |
| AC-10 | Publication gated and verifiable | PASS | `publish.yml` OIDC + `id-token: write` + version-agreement + already-published guards; no stored token in workflow |
| AC-11 | pi user installs and uses in one command; signals queryable in 30s | PARTIAL | Runtime end-to-end AC; no automated test and no live pi turn run this session. Requires pi + a running stack (edge port 24417 here) |
| AC-12 | Appears in the pi gallery via `pi-package` keyword | PARTIAL | Keyword present and package published (unauth registry), but the gallery listing itself was not queried |
| AC-13 | No native build at install time | PASS | verify.sh clean install succeeds, no compile step (pure-JS deps) |
| AC-14 | Bootstrap sequence documented | PASS | `docs/cr/CR-0003-...:261-268` four steps + exact `npm trust github ... --file publish.yml --repo desek/agent-observability` (`:265`) + token-not-a-secret. Note: only in the CR |
| AC-15 | Personal scope needs no org (`npm whoami` = desek) | PARTIAL | `npm whoami` requires an authenticated session; the bootstrap token is revoked, so it returns 401 here. Cannot verify. Scope name `@desek` confirmed live on the registry (unauth) |
| AC-16 | One-concern-per-file layout preserved | PASS | 9 source files each with one sibling `.test.ts`; `git diff 1199a45...HEAD --name-only` |

## Test Strategy Verification

| Test File | Test Name | Specified | Exists | Matches Spec |
|-----------|-----------|-----------|--------|--------------|
| `src/package.manifest.test.ts` | manifest declares publishable fields | yes | yes | yes (PASS) |
| `src/package.manifest.test.ts` | manifest entry point exists on disk | yes | yes (`...exists on disk and the files list would ship it`) | yes, extended to also assert files-list shipping (PASS) |
| `src/package.manifest.test.ts` | api package is a peer dependency | yes | yes | yes (PASS) |
| `src/package.manifest.test.ts` | version agrees with changelog | yes | yes | yes (PASS) |
| `scripts/pi-package.verify.sh` | pack install and load | yes | yes | yes (exit 0) |
| `scripts/pi-package.verify.sh` | tarball excludes tests and lockfile | yes | yes | yes (checks 1-2 PASS) |
| `src/index.test.ts` | no-op when master switch is false | yes | yes (as `no-op when the master switch is off` in `pi-sdk.exporter.test.ts`) | behavior covered; location moved to the SDK-level test |
| `src/index.test.ts` | silent when collector is unreachable | yes | yes (in `pi-sdk.exporter.test.ts`) | behavior covered; location moved |
| `src/index.test.ts` | content flags default to off | yes | yes (as `content-gating` in `config.env.test.ts`) | behavior covered; location moved |
| `src/index.test.ts` | emitter failure never reaches the agent | yes | yes (`handler-failsafe-and-flush`) | behavior covered |
| `config.env.test.ts` (modify) | endpoint default asserts exported constant | yes | yes (`DEFAULT_OTLP_ENDPOINT`) | yes |
| `health.alloy.test.ts` (modify) | probe path asserts exported constant | yes | yes (`default-health-url-is-alloy-native-default`) | yes |

Note: the four operational-contract tests the CR placed in `index.test.ts` were
implemented at a higher fidelity in `src/pi-sdk.exporter.test.ts`, which loads the real
extension through pi's own `discoverAndLoadExtensions`/jiti path and asserts on protobuf
wire bytes captured by in-process OTLP gRPC and HTTP receivers. This is a location
divergence from the Test Strategy table, not a coverage gap; every named behavior is
asserted and passes. Additional protocol tests (`http/protobuf carries all three
signals`, `per-signal transport: metrics over HTTP and traces over gRPC`, `an
unsupported protocol disables only that signal and never raises into pi`) cover the OTLP
protocol fix (see below).

## OTLP protocol fix verification

The setting `OTEL_EXPORTER_OTLP_PROTOCOL` was previously parsed and ignored, so a user
selecting `http/protobuf` silently got gRPC. Current behavior:
- `src/otel.providers.ts:146-149` `resolveTransport` maps `grpc`/empty → gRPC,
  `http/protobuf` → HTTP; `:250-292` construct the matching gRPC or HTTP exporter per
  signal; `:221-227` write an actionable stderr diagnostic for an unsupported value and
  leave other signals unaffected.
- Tests PASS: `resolve-transport-maps-supported-and-rejects-unsupported`,
  `http/protobuf carries all three signals to an HTTP collector` (asserts `/v1/{signal}`
  HTTP wire bytes), `per-signal transport: metrics over HTTP and traces over gRPC in one
  run`, `an unsupported protocol disables only that signal and never raises into pi`.

Verdict: the protocol setting is now honored end to end. **PASS**.

## Diff Coverage

`git diff 1199a45...HEAD` — 29 files, +7307. All within Affected Components
(`packages/pi-opentelemetry/`, `.github/workflows/`, plus the CR doc).

| File group | Mapped requirements |
|------------|---------------------|
| `packages/pi-opentelemetry/package.json` | FR2-FR11, FR20, FR28, NFR3 |
| `packages/pi-opentelemetry/LICENSE` | FR4 |
| `packages/pi-opentelemetry/README.md` | FR16-FR19, AC-8 |
| `packages/pi-opentelemetry/CHANGELOG.md` | FR20, FR25 |
| `packages/pi-opentelemetry/src/*.ts` (source) | FR1, FR12-FR15, NFR2, NFR6, protocol fix |
| `packages/pi-opentelemetry/src/*.test.ts`, `pi-sdk.exporter.test.ts`, `package.manifest.test.ts` | FR10, FR12-FR15, NFR5, AC-1..AC-7, AC-16 |
| `packages/pi-opentelemetry/package-lock.json` | committed for CI (`ci.yml:49`); excluded from publish (NFR4) |
| `.github/workflows/ci.yml` | FR9, FR21, FR22, NFR5, AC-9 |
| `.github/workflows/publish.yml` | FR23-FR25, FR27-FR29, AC-10 |
| `scripts/pi-package.verify.sh` | FR22, FR8, NFR4, AC-2, AC-3, AC-13 |
| `docs/cr/CR-0003-pi-opentelemetry-package.md` | FR31, AC-14 (finalization metadata) |

### Unmapped changed files

None. Every changed file maps to at least one requirement and lies within the CR's
Affected Components. `agents/pi-otel.env` (an Affected Component) exists and was not
modified in this range; its documentation update (Proposed Change 10) is not evidenced
in the diff — folded into the FR26 gap below.

## Trusted publishing known issue (record for the next package author)

`npm trust github` could **not** be configured from the command line. It returned
**HTTP 400 with an empty detail body on every attempt**, with every documented
prerequisite verified met: no pre-existing trust config, npm 11.12.1, package write
access, account 2FA at auth-and-writes, granular-token cause ruled out by reproducing
from outside the repo with nothing in scope, repository public, workflow readable at the
exact path npm checks, payload well formed, GitHub account linked. The repository owner
then configured trusted publishing successfully through the **npmjs.com web interface**.
Consequence for FR30: the trust relationship exists (per the owner) but was created via
the web UI, not the CLI command the requirement names; it cannot be verified from this
unauthenticated session. The next person to add a package should expect the CLI 400 and
use the web UI.

## Provenance correction

A prior finalization pass claimed the published package carries provenance attestations.
**That claim is wrong.** Verified unauthenticated:
- `GET https://registry.npmjs.org/-/npm/v1/attestations/@desek%2fpi-opentelemetry@0.1.0`
  → HTTP 404 `{"error":"Not found"}`.
- Packument `0.1.0` `dist` has `signatures` (the standard npm **registry** signing key,
  present on every publish) but **no** `attestations` field and no `_attestations`.

`0.1.0` therefore has **no provenance attestations**, which is correct: it was the
one-time bootstrap publish from a developer machine (provenance needs the CI OIDC
identity token). The `publish.yml` workflow is the path that will attach provenance on
the next tagged release. Recorded as the true state.

## Gaps

1. **FR26 — contributor local-install path is undocumented.** The registry path
   (`pi install npm:@desek/pi-opentelemetry`) is in the package README, but neither the
   root `README.md` nor any doc states the local-path install for a contributor
   developing the extension, and the root README never mentions the package or
   `agents/pi-otel.env`'s relationship to it (Proposed Change 10). Suggested minimal
   fix: add a short "pi telemetry extension" section to the root `README.md` giving both
   the `npm:` specifier and a `file:packages/pi-opentelemetry` (or path) install for
   contributors, and one line on `agents/pi-otel.env`.

The remaining non-PASS rows (FR29, FR30, NFR1, NFR2, AC-7, AC-11, AC-12, AC-15) are
PARTIAL due to an authenticated session being unavailable (revoked bootstrap token) or a
runtime latency/gallery measurement with no automated test — not implementation gaps.
Each names the session or measurement it needs. None is a FAIL.

## Stacks left running

Both stacks confirmed up and untouched:
- This repo's stack (`agent-observability-*` containers) on `EDGE_PORT=24417` → `GET http://localhost:24417/` HTTP 302.
- The separate private stack (`observability-*` containers) on `24317` → `GET http://localhost:24317/` HTTP 302.
