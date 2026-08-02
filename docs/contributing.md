<!-- Purpose: the maintainer document. It names the single check command and what it
     covers, where every tracked path belongs, how the committed screenshots and
     the walkthrough are regenerated and verified, and what a pull request is
     expected to carry.
     @agents-index: Contributing document: the make ci gate, the repository layout table, the screenshot and walkthrough regeneration procedure, and the pull-request expectations. -->

# Contributing

[Back to the front page](../README.md)

## Checks

`make ci` is the single command that checks the repository. It runs a self-test,
compose and HAProxy validation, a shell lint over every script, and every
verification script, including `scripts/readme.verify.sh`, which asserts every
command in the front page and in these documents runs, that no governance
identifier appears in any of them, that privacy is stated only in
[`docs/privacy.md`](privacy.md), that every document is linked from the front
page, and that both screenshots carry alternative text:

```console
$ make ci
```

A check that needs a running stack is skipped with a named report when the stack
is down, and a skip is never reported as a pass. Run `make help` to list the
individual targets.

## Repository layout

| Path | Holds |
|------|-------|
| `compose.yaml` | The whole stack. Run `docker compose up -d` from here. |
| `.env.example` | The template for `.env`. Documents every variable and its default. |
| `AGENTS.md` | The example agent instruction file. `CLAUDE.md` is a symbolic link to it. |
| `.mcp.json` | The example MCP client configuration. No credential to paste. |
| `Makefile` | `make ci`, the single check entry point. |
| `LICENSE` | The Apache-2.0 license. |
| `stack/` | Per-service configuration: Alloy, Grafana, HAProxy, Loki, Mimir, Tempo, and the thin MLflow image build. |
| `packages/pi-opentelemetry/` | The `@desek/pi-opentelemetry` pi extension: source, tests, and its published-package manifest. |
| `agents/` | The opt-in OpenTelemetry content flags and the optional git-provenance direnv helper. |
| `scripts/` | Start, verify, seed, capture, deep-link, and verification scripts. |
| `docs/` | The reader documentation the front page links to. |
| `docs/images/` | The committed screenshots and the walkthrough video. |
| `docs/cr/` | The governance record for this repository. |
| `skills/observability-install/` | The agent-driven install and uninstall instruction. |

## Regenerating the visual artifacts

The two screenshots and the walkthrough are produced by maintainer scripts that
drive `agent-browser` against the demo seed, so they contain no real data. Each
committed PNG stays under 1 MB, the walkthrough `.mp4` under 5 MB, and the video
under 90 seconds; a contributor who regenerates them keeps to that budget. The
WebM original the recorder produces is never committed. Seed the stack, capture,
record, then clear:

```console
$ ./scripts/demo.seed.sh
$ ./scripts/capture.screenshots.sh
$ ./scripts/capture.walkthrough.sh
$ ./scripts/demo.seed.sh --clear
```

`scripts/capture.screenshots.sh` and `scripts/capture.walkthrough.sh` refuse to
run if any real agent session exists in the capture window, because a picture of
a real prompt cannot be recalled once published.

To confirm the committed screenshots still match the interface, seed the stack
and run the capture script in verify mode. It opens each view live and reports
the pixel difference against the committed baseline, so reproducibility is a
check rather than a claim. A faithful re-capture differs only by a few percent,
which is fresh-seed timestamp noise; a larger difference means the interface
moved and the images want a re-capture and a look.

```console
$ ./scripts/demo.seed.sh
$ ./scripts/capture.screenshots.sh --verify
$ ./scripts/demo.seed.sh --clear
```

Verification is a maintainer step against a seeded stack, not part of `make ci`,
because it needs the demo data present and drives a browser.

## Pull requests

Contributions go through a pull request with a Conventional Commits title. Run
`make ci` before you open one; it is the single gate the project checks against.
Add or change a script under `scripts/` with a top docstring and one
`@agents-index` line, and keep every command in the front page and in these
documents runnable, because `scripts/readme.verify.sh` runs them all. The
governance record for every change lives under `docs/cr/`.

## Next

* [Architecture](architecture.md), what a change has to keep true.
* [Privacy](privacy.md), the posture a change must not weaken.
