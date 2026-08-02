#!/usr/bin/env bash
#
# readme.verify.sh
#
# @agents-index Proves README.md true against the running stack: every fenced bash command runs and exits 0, no governance identifier appears, the privacy posture is stated only in the README and linked from elsewhere, and both committed screenshots are referenced with non-empty alternative text.
#
# Purpose: keep the front page honest and keep it from drifting back into an
# accreted document. The README is the first thing a reader meets, so a stale
# command, a leaked governance identifier, a second copy of the privacy posture,
# or a screenshot with no alternative text each fails a check here rather than
# reaching a reader. It asserts:
#   1. Every ```bash block in README.md runs and exits 0 on the running stack.
#      Illustrative or destructive commands are written in ```console blocks,
#      which are shown but not run, so this check never tears the stack down,
#      never edits a settings file, and never recurses into `make ci`.
#   2. No governance identifier of the form CR- followed by four digits appears.
#   3. The privacy posture is stated once, in the README, and every other
#      document links to it: the README has a Privacy section, AGENTS.md links to
#      it, and the two posture-defining sentences appear only in the README.
#   4. Both committed screenshots are referenced with non-empty alternative text.
# It exits non-zero on the first failure and names the fix.
#
# A --selftest mode proves the governance-identifier check catches a violation:
# it injects a governance identifier into a temporary copy of the README, runs
# the check against that copy, and confirms the check fails. This makes the
# negative case observable rather than assumed.
#
# Usage:
#   scripts/readme.verify.sh            Run every check against the running stack.
#   scripts/readme.verify.sh --selftest Prove the governance check fails on a
#                                       planted violation, then exit 0.
#   scripts/readme.verify.sh -h         Print this usage and exit 0.
#
# Parameters:
#   -h, --help    Print usage and exit 0.
#   --selftest    Run the negative test for the governance-identifier check.
#
# Environment:
#   EDGE_PORT     Loopback host port the edge proxy publishes. Read from the
#                 shell first, then from .env, then defaults to 24317. Exported
#                 before the extracted commands run so they resolve the same port.

set -euo pipefail

# --- Location ----------------------------------------------------------------
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

# --- Usage -------------------------------------------------------------------
usage() {
	sed -n '3,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# --- Reporting helpers -------------------------------------------------------
fail() {
	local what="$1" fix="$2" after="$3"
	echo "readme-verify: FAIL $what" >&2
	echo "  Fix: $fix" >&2
	echo "  After: $after" >&2
	exit 1
}
pass() { echo "readme-verify: PASS $1"; }

readonly README="README.md"
readonly AGENTS_MD="AGENTS.md"
readonly IMG_DASHBOARD="docs/images/dashboard.png"
readonly IMG_MLFLOW="docs/images/mlflow-conversation.png"
# The regular expression for a governance identifier: CR- and exactly four digits.
readonly GOV_RE='CR-[0-9]{4}'
# Two sentences that, together, define the privacy posture. They must live only
# in the README, so a second copy anywhere else is a restatement that can drift.
readonly POSTURE_A='load-bearing privacy control'
readonly POSTURE_B='Content logging is enabled by default'

# --- Governance-identifier check (shared by the run and the selftest) ---------
# Asserts the given file holds no governance identifier. Returns non-zero and
# prints a fix when one is found, so the selftest can observe the failure.
check_no_governance() {
	local file="$1" hits
	hits="$(grep -nE "$GOV_RE" "$file" || true)"
	if [ -n "$hits" ]; then
		echo "$hits" >&2
		fail "$file contains a governance identifier (listed above)." \
			"remove the CR-NNNN reference from the README; governance lives under docs/cr, not on the front page." \
			"re-run 'scripts/readme.verify.sh' and confirm zero governance identifiers."
	fi
	pass "no governance identifier appears in $file."
}

# --- Selftest: prove the governance check fails on a planted violation --------
run_selftest() {
	local tmp
	tmp="$(mktemp)"
	trap 'rm -f "$tmp"' EXIT
	# A README that is clean except for one planted governance identifier.
	# The identifier is built at run time rather than written as a literal. A
	# literal here would be a governance identifier inside a tracked file
	# outside docs, which is the very thing the repository forbids and which
	# stack.verify.sh scans for, so this self-test would fail the build it is
	# meant to protect.
	local planted
	planted="$(printf 'CR-%04d' 7)"
	printf '# Title\n\nThis references %s which must be caught.\n' "$planted" >"$tmp"
	local out rc
	out="$( (check_no_governance "$tmp") 2>&1 )" && rc=0 || rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "the governance-identifier check passed a README that contains a governance identifier." \
			"the negative test is broken; the check must fail when CR-NNNN is present." \
			"fix check_no_governance so it catches the planted identifier."
	fi
	echo "readme-verify: selftest observed the expected failure:"
	local line
	while IFS= read -r line; do
		echo "    $line"
	done <<<"$out"
	pass "the governance-identifier check fails on a planted violation (negative test)."
	trap - EXIT
	rm -f "$tmp"
	exit 0
}

case "${1:-}" in
	-h | --help)
		usage
		exit 0
		;;
	--selftest)
		run_selftest
		;;
	"") ;;
	*)
		echo "readme-verify: FAIL unknown argument '$1'." >&2
		echo "  Fix: run 'scripts/readme.verify.sh', '--selftest', or '-h'." >&2
		echo "  After: re-run without the extra argument." >&2
		exit 2
		;;
esac

cd "$repo_root"

[ -f "$README" ] || fail "$README is not present at the repository root." \
	"run this check from a clone that contains README.md." \
	"re-run 'scripts/readme.verify.sh' once README.md exists."

# --- Port resolution ---------------------------------------------------------
resolve_edge_port() {
	local port="${EDGE_PORT:-}"
	if [ -z "$port" ] && [ -f "$repo_root/.env" ]; then
		port="$(grep -E '^[[:space:]]*EDGE_PORT[[:space:]]*=' "$repo_root/.env" | tail -n1 | cut -d= -f2 | tr -d '[:space:]')"
	fi
	printf '%s' "${port:-24317}"
}
EDGE_PORT="$(resolve_edge_port)"
export EDGE_PORT
B="http://localhost:${EDGE_PORT}"
export B

# --- Check 1: every fenced bash command runs ---------------------------------
# Extract each ```bash block and run it under set -e with EDGE_PORT and B already
# exported. Only ```bash blocks run; ```console blocks are illustrative and are
# not executed, which is how the destructive commands (teardown, install, the
# capture scripts, the tracing enable) stay in the README without being run here.
run_every_command() {
	local workdir count n=0 blockfile out
	workdir="$(mktemp -d)"
	count="$(python3 - "$README" "$workdir" <<'PY'
import re, sys, os
txt = open(sys.argv[1]).read()
workdir = sys.argv[2]
blocks = re.findall(r'```bash\n(.*?)```', txt, re.S)
for i, block in enumerate(blocks):
    with open(os.path.join(workdir, "block_%03d.sh" % i), "w") as fh:
        fh.write(block)
print(len(blocks))
PY
)"
	if [ "${count:-0}" -eq 0 ]; then
		rm -rf "$workdir"
		fail "README.md contains no runnable bash command block." \
			"every runnable instruction in the README must be a fenced bash block; add them." \
			"re-run 'scripts/readme.verify.sh' once the commands are present."
	fi
	for blockfile in "$workdir"/block_*.sh; do
		n=$((n + 1))
		out="$workdir/out_$n.log"
		if ! bash -c "set -e; source '$blockfile'" >/dev/null 2>"$out"; then
			echo "---- failing command block $n ----" >&2
			cat "$blockfile" >&2
			echo "---- its output ----" >&2
			cat "$out" >&2
			rm -rf "$workdir"
			fail "command block $n in README.md exited non-zero (shown above)." \
				"start the stack with 'scripts/stack.up.sh', then fix the drifted command in README.md so it matches the running stack." \
				"re-run 'scripts/readme.verify.sh' and confirm every command block exits 0."
		fi
	done
	rm -rf "$workdir"
	pass "all $n bash command blocks in README.md ran and exited 0."
}

# --- Check 3: privacy stated once, and linked from elsewhere ------------------
check_privacy_once() {
	# The README carries the single Privacy section.
	grep -qE '^##[[:space:]]+Privacy[[:space:]]*$' "$README" || fail \
		"README.md has no '## Privacy' section." \
		"add one Privacy section to README.md stating what is stored, where, what is off by default, and how to delete it." \
		"re-run 'scripts/readme.verify.sh' once the Privacy section exists."
	# AGENTS.md links to it rather than restating the posture.
	if [ -f "$AGENTS_MD" ]; then
		grep -qF 'README.md#privacy' "$AGENTS_MD" || fail \
			"$AGENTS_MD does not link to the README privacy section." \
			"add a link to README.md#privacy in AGENTS.md instead of restating the posture." \
			"re-run 'scripts/readme.verify.sh' once AGENTS.md links to the README."
	fi
	# Each posture-defining sentence appears in the README and nowhere else among
	# the tracked Markdown documents (governance records under docs/cr excepted).
	local phrase files other
	for phrase in "$POSTURE_A" "$POSTURE_B"; do
		files="$(grep -rlF "$phrase" --include='*.md' . | grep -v '/docs/cr/' | grep -v './docs/cr/' | sort -u)"
		if [ "$files" != "./$README" ] && [ "$files" != "$README" ]; then
			other="$(printf '%s\n' "$files" | grep -vE "(^|/)$README\$" || true)"
			echo "$other" >&2
			fail "the privacy posture sentence '$phrase' appears outside README.md (listed above)." \
				"remove the restatement from that document and link to README.md#privacy instead; the posture is stated once." \
				"re-run 'scripts/readme.verify.sh' and confirm the posture lives only in the README."
		fi
	done
	pass "the privacy posture is stated once in README.md and linked from elsewhere."
}

# --- Check 4: both screenshots referenced with non-empty alternative text -----
check_images_alt_text() {
	local img alt_re
	for img in "$IMG_DASHBOARD" "$IMG_MLFLOW"; do
		[ -f "$img" ] || fail "$img is not present." \
			"regenerate the screenshots with scripts/capture.screenshots.sh, or restore the committed file." \
			"re-run 'scripts/readme.verify.sh' once $img exists."
		# Markdown image with non-empty alt text: ![<one or more chars>](<img>).
		alt_re="!\[[^]]+\]\($img\)"
		grep -qE "$alt_re" "$README" || fail \
			"README.md does not reference $img with non-empty alternative text." \
			"reference it as '![descriptive alt text]($img)' so a reader without the image still learns what it shows." \
			"re-run 'scripts/readme.verify.sh' and confirm the image carries alt text."
	done
	pass "both screenshots are referenced in README.md with non-empty alternative text."
}

run_every_command
check_no_governance "$README"
check_privacy_once
check_images_alt_text

echo "readme-verify: PASS (README.md is executable and true against the stack on port ${EDGE_PORT})"
