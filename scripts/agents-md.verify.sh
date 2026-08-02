#!/usr/bin/env bash
#
# agents-md.verify.sh
#
# @agents-index Proves AGENTS.md true against the running stack: every fenced command runs, every metric name it states exists in the store, its addresses use the port variable, the example .mcp.json holds no secret, and AGENTS.md links to the README privacy section rather than restating the posture.
#
# Purpose: keep the example instruction file honest by making every claim in it
# executable. A stale AGENTS.md makes an agent confidently wrong, so this script
# turns staleness into a failing check. It asserts:
#   1. Every fenced bash command block in AGENTS.md runs and exits 0.
#   2. Every metric name AGENTS.md states exists in the metrics store.
#   3. Every backend address in AGENTS.md is expressed through the port variable,
#      not a literal host:port.
#   4. The example .mcp.json holds no token, secret, password, or absolute path.
#   5. AGENTS.md links to the README privacy section (README.md#privacy) rather
#      than restating the full posture, so the posture is stated once. The full
#      privacy statement lives in the README; a restatement here would drift.
# It exits non-zero on the first failure. Every failure names what failed, the
# fix, and what to check after.
#
# Usage:
#   scripts/agents-md.verify.sh          Run every check against the running stack.
#   scripts/agents-md.verify.sh -h       Print this usage and exit 0.
#
# Parameters:
#   -h, --help   Print usage and exit 0. The script takes no other argument.
#
# Environment:
#   EDGE_PORT    Loopback host port the edge proxy publishes. Read from the shell
#                first, then from .env, then defaults to 24317. Exported before
#                the extracted commands run so they resolve the same port.

set -euo pipefail

# --- Location ----------------------------------------------------------------
# Resolve the repository root from the script location so it runs the same way
# from any working directory. The extracted commands run from the repository
# root, which is where AGENTS.md tells an agent it is.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

# --- Usage -------------------------------------------------------------------
usage() {
	sed -n '3,31p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
	-h | --help)
		usage
		exit 0
		;;
	"") ;;
	*)
		echo "agents-md-verify: FAIL unknown argument '$1'." >&2
		echo "  Fix: run 'scripts/agents-md.verify.sh' with no argument, or '-h' for usage." >&2
		echo "  After: re-run the command without the extra argument." >&2
		exit 2
		;;
esac

cd "$repo_root"

readonly AGENTS_MD="AGENTS.md"
readonly MCP_CONFIG=".mcp.json"

# --- Reporting helpers -------------------------------------------------------
fail() {
	local what="$1" fix="$2" after="$3"
	echo "agents-md-verify: FAIL $what" >&2
	echo "  Fix: $fix" >&2
	echo "  After: $after" >&2
	exit 1
}
pass() { echo "agents-md-verify: PASS $1"; }

[ -f "$AGENTS_MD" ] || fail "$AGENTS_MD is not present at the repository root." \
	"create AGENTS.md (phase 4 of the agent-interface change) before running this check." \
	"re-run 'scripts/agents-md.verify.sh' once AGENTS.md exists."

# --- Port resolution ---------------------------------------------------------
# Resolve the edge port and export it, so the extracted commands and this
# script's own queries resolve the same port as the rest of the stack.
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
# exported. A command that fails on a working stack means the file has drifted.
run_every_command() {
	local workdir count n=0 blockfile out
	workdir="$(mktemp -d)"
	# Python writes each ```bash block to its own numbered file, so a block with
	# blank lines stays one unit; command substitution cannot strip file bytes.
	count="$(python3 - "$AGENTS_MD" "$workdir" <<'PY'
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
		fail "AGENTS.md contains no runnable bash command block." \
			"every operational fact in AGENTS.md must be backed by a runnable command; add the command blocks." \
			"re-run 'scripts/agents-md.verify.sh' once the commands are present."
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
			fail "command block $n in AGENTS.md exited non-zero (shown above)." \
				"start the stack with 'scripts/stack.up.sh', then fix the drifted command in AGENTS.md so it matches the running stack." \
				"re-run 'scripts/agents-md.verify.sh' and confirm every command block exits 0."
		fi
	done
	rm -rf "$workdir"
	pass "all $n command blocks in AGENTS.md ran and exited 0."
}

# --- Check 2: every metric name exists ---------------------------------------
# Prometheus counters end in _total, so a metric name in AGENTS.md matches
# (claude_code|pi)_..._total. Each must exist in the metrics store.
check_metric_names() {
	local names known missing=()
	names="$(grep -oE '(claude_code|pi)_[A-Za-z_]+_total' "$AGENTS_MD" | sort -u)"
	if [ -z "$names" ]; then
		fail "AGENTS.md names no metric to verify." \
			"AGENTS.md must state the real metric names; add them." \
			"re-run 'scripts/agents-md.verify.sh' once the metric names are present."
	fi
	known="$(curl -s --max-time 15 "$B/prometheus/api/v1/label/__name__/values" \
		| python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin).get("data",[])))' || true)"
	if [ -z "$known" ]; then
		fail "the metrics store returned no metric names through port ${EDGE_PORT}." \
			"start the stack with 'scripts/stack.up.sh' and confirm '$B/prometheus/ready' answers." \
			"re-run 'scripts/agents-md.verify.sh' once the metrics store answers."
	fi
	local name
	while IFS= read -r name; do
		grep -qxF "$name" <<<"$known" || missing+=("$name")
	done <<<"$names"
	if [ "${#missing[@]}" -ne 0 ]; then
		fail "AGENTS.md names metrics that do not exist in the store: ${missing[*]}." \
			"correct the metric name in AGENTS.md, or confirm the metric is emitted; run 'curl -s \"$B/prometheus/api/v1/label/__name__/values\"' to list the real names." \
			"re-run 'scripts/agents-md.verify.sh' and confirm zero unknown metric names."
	fi
	pass "every metric name in AGENTS.md exists in the store ($(wc -l <<<"$names" | tr -d ' ') names checked)."
}

# --- Check 3: addresses use the port variable --------------------------------
# A literal host:port address (localhost:<digits>) means the file hard-coded a
# port instead of deriving it from EDGE_PORT.
check_no_literal_port() {
	local hits
	hits="$(grep -nE 'localhost:[0-9]+' "$AGENTS_MD" || true)"
	if [ -n "$hits" ]; then
		echo "$hits" >&2
		fail "AGENTS.md contains a literal host:port address (listed above)." \
			"express every backend address through the port variable, for example \"\$B\" or \"http://localhost:\${EDGE_PORT}/...\"." \
			"re-run 'scripts/agents-md.verify.sh' and confirm no literal host:port remains."
	fi
	pass "every backend address in AGENTS.md is expressed through the port variable."
}

# --- Check 4: the example configuration holds no secret ----------------------
check_no_secret() {
	[ -f "$MCP_CONFIG" ] || fail "$MCP_CONFIG is not present at the repository root." \
		"create the example .mcp.json (phase 5 of the agent-interface change)." \
		"re-run 'scripts/agents-md.verify.sh' once .mcp.json exists."
	local hits
	hits="$(grep -nEi 'token|secret|password|/Users/|/home/' "$MCP_CONFIG" || true)"
	if [ -n "$hits" ]; then
		echo "$hits" >&2
		fail "$MCP_CONFIG contains a token, secret, password, or absolute path (listed above)." \
			"remove the secret or absolute path; the server holds the Grafana credentials internally, so nothing is pasted here." \
			"re-run 'scripts/agents-md.verify.sh' and confirm .mcp.json holds no secret."
	fi
	pass "the example .mcp.json holds no token, secret, password, or absolute path."
}

# --- Check 5: privacy is linked, not restated --------------------------------
# The full privacy posture is stated once, in the README. AGENTS.md carries the
# agent-facing rules and links to the README for the posture. This asserts the
# link is present, so the posture is stated once and a reader is sent to the one
# authoritative copy rather than a restatement that can drift.
check_privacy_link() {
	if ! grep -qF 'README.md#privacy' "$AGENTS_MD"; then
		fail "$AGENTS_MD does not link to the README privacy section (README.md#privacy)." \
			"add a link to README.md#privacy in AGENTS.md instead of restating the full posture; the posture is stated once, in the README." \
			"re-run 'scripts/agents-md.verify.sh' once AGENTS.md links to the README privacy section."
	fi
	pass "AGENTS.md links to the README privacy section rather than restating the posture."
}

run_every_command
check_metric_names
check_no_literal_port
check_no_secret
check_privacy_link

echo "agents-md-verify: PASS (AGENTS.md is executable and true against the stack on port ${EDGE_PORT})"
