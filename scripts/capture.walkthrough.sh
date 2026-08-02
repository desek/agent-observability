#!/usr/bin/env bash
#
# capture.walkthrough.sh
#
# @agents-index Records a short silent walkthrough (dashboard, one drill into a log line, one MLflow conversation) with agent-browser from seeded synthetic data only, refusing before recording if any telemetry not carrying git_org="demo-seed" is in the window, then converts the WebM with ffmpeg to a committed docs/images/walkthrough.mp4 (and an optional gif) capped at 90 seconds and a stated size budget; the WebM original is written outside the working tree and never committed.
#
# Purpose: produce the short walkthrough video the README embeds. It records the
# working product, the dashboard with its rows, one drill into a log line, and
# one agent conversation in the MLflow interface, with the viewport, dark theme,
# and reduced motion pinned so the recording does not depend on a machine default.
# agent-browser records WebM only and a repository page embeds .mp4 or .mov, so
# ffmpeg converts the recording to a committed .mp4 (and an optional .gif preview).
#
# The leak check is the load-bearing control and it runs BEFORE recording starts,
# never after, because a recording that has already shown a real prompt or a real
# log line cannot be made safe by a later assertion. The video carries the greater
# exposure of the two capture scripts, because it shows many views in sequence,
# and the log-line drill is the sharpest exposure of all: an expanded Loki log
# line reveals the identity fields (user_email and the rest) directly, per the
# privacy rules in AGENTS.md. The check therefore asserts that every git_org label
# value in Mimir and Loki within the window is exactly the seeded marker
# "demo-seed", and refuses otherwise, recording nothing.
#
# The WebM original is written to a path OUTSIDE the working tree, so it is never
# committed by construction rather than by an ignore rule; only the converted mp4
# and optional gif land under docs/images/.
#
# The house conventions for driving agent-browser, and the record-to-frames
# pipeline, live in the agent-browser-specialization skill; this script follows
# them rather than restating command mechanics.
#
# Usage:
#   scripts/capture.walkthrough.sh          Record and convert the walkthrough,
#                                            refusing if any unseeded telemetry is
#                                            in the window.
#   scripts/capture.walkthrough.sh -h       Print this usage and exit 0.
#
# Parameters:
#   -h, --help   Print usage and exit 0.
#
# Environment:
#   EDGE_PORT             Loopback host port the edge proxy publishes. Read from
#                         the shell first, then from .env, then defaults to 24317.
#   GRAFANA_USER          Grafana login user. Defaults to admin.
#   GRAFANA_PASSWORD      Grafana login password. Defaults to admin.
#   CAPTURE_WINDOW_SECS   Look-back window, in seconds, for the leak check and the
#                         dashboard range. Defaults to 21600 (6h).
#   CAPTURE_HEADED        Set to 1 to record headed; defaults to headless.
#   WALKTHROUGH_MAKE_GIF  Set to 1 to also write an optional gif preview.
#
# Output (fixed paths):
#   docs/images/walkthrough.mp4          The committed video the README embeds.
#   docs/images/walkthrough.gif          Optional preview, only if requested.
#
# Budgets: the video runs no longer than 90 seconds and stays under 5 MB.
#
# Exit status: 0 on success; non-zero on the first failure or on a leak refusal,
# with a message that names what failed, the fix, and what to check after.

set -euo pipefail

# --- Location ----------------------------------------------------------------
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

# --- Usage -------------------------------------------------------------------
usage() {
	sed -n '3,66p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
	-h | --help)
		usage
		exit 0
		;;
	"") ;;
	*)
		echo "walkthrough: FAIL unknown argument '$1'." >&2
		echo "  Fix: run 'scripts/capture.walkthrough.sh' with no arguments, or '-h' for usage." >&2
		echo "  After: re-run the command without the extra argument." >&2
		exit 2
		;;
esac

cd "$repo_root"

# --- Reporting helpers -------------------------------------------------------
info() { echo "walkthrough: $1"; }
pass() { echo "walkthrough: PASS $1"; }
fail() {
	local what="$1" fix="$2" after="$3"
	echo "walkthrough: FAIL $what" >&2
	echo "  Fix: $fix" >&2
	echo "  After: $after" >&2
	exit 1
}

# --- Preconditions -----------------------------------------------------------
for tool in curl jq agent-browser ffmpeg ffprobe; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		fail "the required tool '$tool' is not installed." \
			"install '$tool' (agent-browser drives the recording, ffmpeg converts it; see the agent-browser-specialization skill)." \
			"re-run 'scripts/capture.walkthrough.sh' once '$tool' is on PATH."
	fi
done

# --- Port resolution ---------------------------------------------------------
resolve_edge_port() {
	local port="${EDGE_PORT:-}"
	if [ -z "$port" ] && [ -f "$repo_root/.env" ]; then
		port="$(grep -E '^[[:space:]]*EDGE_PORT[[:space:]]*=' "$repo_root/.env" | tail -n1 | cut -d= -f2 | tr -d '[:space:]')"
	fi
	printf '%s' "${port:-24317}"
}

edge_port="$(resolve_edge_port)"
base_url="http://127.0.0.1:${edge_port}"
grafana_user="${GRAFANA_USER:-admin}"
grafana_password="${GRAFANA_PASSWORD:-admin}"
window_secs="${CAPTURE_WINDOW_SECS:-21600}"

# --- Constants ---------------------------------------------------------------
readonly DEMO_ORG="demo-seed"
readonly VIEW_W=1440
readonly VIEW_H=900
readonly MP4_PATH="docs/images/walkthrough.mp4"
readonly GIF_PATH="docs/images/walkthrough.gif"
readonly MAX_SECONDS=90
readonly MAX_MP4_BYTES=$((5 * 1024 * 1024))
# The WebM is written outside the working tree so it is never committed.
webm_dir="${TMPDIR:-/tmp}/cr0007-walkthrough"
webm_path="${webm_dir}/run.webm"

# --- Reachability ------------------------------------------------------------
require_stack() {
	local code
	code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${base_url}/alloy/-/healthy" || true)"
	if [ "$code" != "200" ]; then
		fail "the stack did not answer on port ${edge_port} (health returned '${code}')." \
			"start the stack with 'scripts/stack.up.sh' and confirm it with 'scripts/stack.verify.sh'." \
			"re-run 'scripts/capture.walkthrough.sh' once the stack answers on port ${edge_port}."
	fi
}

# --- The leak check, before recording ----------------------------------------
git_org_values_mimir() {
	local now start
	now="$(date +%s)"
	start="$((now - window_secs))"
	curl -s --max-time 15 --get "${base_url}/prometheus/api/v1/label/git_org/values" \
		--data-urlencode "start=${start}" --data-urlencode "end=${now}" \
		| jq -r '.data[]?' 2>/dev/null || true
}

git_org_values_loki() {
	local now start
	now="$(date +%s)"
	start="$((now - window_secs))"
	curl -s --max-time 15 --get "${base_url}/loki/api/v1/label/git_org/values" \
		--data-urlencode "start=${start}000000000" --data-urlencode "end=${now}000000000" \
		| jq -r '.data[]?' 2>/dev/null || true
}

assert_only_seeded() {
	require_stack
	info "leak check: asserting the stack holds only git_org=${DEMO_ORG} telemetry in the last ${window_secs}s window (port ${edge_port})"
	local mimir loki unseeded=""
	mimir="$(git_org_values_mimir)"
	loki="$(git_org_values_loki)"

	local store name
	for store in "mimir:${mimir}" "loki:${loki}"; do
		name="${store%%:*}"
		while IFS= read -r val; do
			[ -z "$val" ] && continue
			if [ "$val" != "$DEMO_ORG" ]; then
				unseeded="${unseeded}${unseeded:+, }${val} (${name})"
			fi
		done <<-EOF
			${store#*:}
		EOF
	done

	if [ -n "$unseeded" ]; then
		fail "unseeded telemetry is present in the ${window_secs}s recording window. Found git_org values other than '${DEMO_ORG}': ${unseeded}. Recording now could publish a real email address, user identifier, prompt, or repository name into a public video, which cannot be recalled." \
			"wipe THIS stack's volumes with 'docker compose down -v' (verify first that 'docker compose ls' shows you are on project 'agent-observability' on port ${edge_port}, NEVER 'observability' on 24317), bring it back with 'scripts/stack.up.sh', seed synthetic data with 'scripts/demo.seed.sh', then re-run this script." \
			"re-run 'scripts/capture.walkthrough.sh'; it must report only git_org='${DEMO_ORG}' before it records."
	fi

	if ! printf '%s\n' "$mimir" "$loki" | grep -qx "$DEMO_ORG"; then
		fail "no seeded telemetry (git_org=${DEMO_ORG}) is present in the ${window_secs}s window, so the recording would show empty panels." \
			"seed synthetic data with 'scripts/demo.seed.sh', then re-run this script." \
			"re-run 'scripts/capture.walkthrough.sh' once the seed reports success."
	fi
	pass "leak check clear: only git_org=${DEMO_ORG} telemetry is in the recording window."
}

# --- Browser session ---------------------------------------------------------
SESSION=""
cleanup() {
	if [ -n "$SESSION" ]; then
		agent-browser --session "$SESSION" record stop >/dev/null 2>&1 || true
		agent-browser --session "$SESSION" close >/dev/null 2>&1 || true
	fi
}
trap cleanup EXIT

ab() { agent-browser --session "$SESSION" "$@"; }

open_session() {
	SESSION="$(date +%s)-cr0007-walkthrough"
	local headed=()
	[ "${CAPTURE_HEADED:-0}" = "1" ] && headed=(--headed)
	agent-browser --session "$SESSION" "${headed[@]}" open "${base_url}/login" >/dev/null
	ab set viewport "$VIEW_W" "$VIEW_H" >/dev/null
	ab set media dark reduced-motion >/dev/null
	ab wait --load networkidle >/dev/null || true
}

grafana_login() {
	info "authenticating to Grafana as ${grafana_user}"
	ab open "${base_url}/login" >/dev/null
	ab wait --load networkidle >/dev/null || true
	ab fill 'input[name=user]' "$grafana_user" >/dev/null
	ab fill 'input[name=password]' "$grafana_password" >/dev/null
	ab click 'button[type=submit]' >/dev/null
	ab wait --load networkidle >/dev/null || true
	ab find text "Skip" click >/dev/null 2>&1 || true
	ab wait --load networkidle >/dev/null || true
	local url
	url="$(ab get url 2>/dev/null || true)"
	case "$url" in
		*"/login"*)
			fail "Grafana login did not complete; the browser is still on the login page." \
				"confirm the Grafana credentials (GRAFANA_USER and GRAFANA_PASSWORD, default admin and admin) and that the stack is healthy." \
				"re-run 'scripts/capture.walkthrough.sh' with the correct credentials."
			;;
	esac
}

# --- The route ---------------------------------------------------------------
# Three required views in sequence: the dashboard, one drill into a log line, and
# one MLflow conversation. Each step waits for its view to settle so the recording
# drives a settled interface rather than a transition.
drive_route() {
	# Grafana Explore and MLflow keep live connections open, so the network never
	# goes idle; wait on a visible text or a fixed settle rather than networkidle,
	# which would time out and leave the recording dwelling on one view.

	# 1. The dashboard, all rows, in kiosk mode. Scroll through so the recording
	#    reveals every row (Grafana renders panels as they enter the viewport).
	info "route: the dashboard"
	ab open "${base_url}/d/agent-observability/coding-agent-observability?from=now-${window_secs}s&to=now&kiosk" >/dev/null
	ab wait --text "Overview" >/dev/null 2>&1 || true
	ab wait 4000 >/dev/null
	ab scroll down 650 >/dev/null 2>&1 || true
	ab wait 2000 >/dev/null
	ab scroll down 650 >/dev/null 2>&1 || true
	ab wait 2000 >/dev/null
	ab scroll up 1300 >/dev/null 2>&1 || true
	ab wait 1500 >/dev/null

	# 2. One drill into a log line, in Grafana Explore against Loki, seeded data
	#    only. Clicking a log line expands it to reveal its full label and field
	#    set; on seeded data those labels are synthetic (git_org=demo-seed and no
	#    identity fields), which is exactly why the stack was seeded first.
	info "route: drill into a log line"
	local logs_expr
	logs_expr='{git_org="'"${DEMO_ORG}"'"}'
	local left
	left="$(jq -cn --arg expr "$logs_expr" --arg win "${window_secs}s" \
		'{datasource:"loki", queries:[{refId:"A", expr:$expr, datasource:{type:"loki", uid:"loki"}}], range:{from:("now-"+$win), to:"now"}}')"
	ab open "${base_url}/explore?left=$(printf '%s' "$left" | jq -sRr @uri)&orgId=1" >/dev/null
	ab wait --text "Logs volume" >/dev/null 2>&1 || true
	ab wait 4000 >/dev/null
	ab scroll down 550 >/dev/null 2>&1 || true
	ab wait 1500 >/dev/null
	# Expand the seeded user_prompt line; its request text is one the seed writes,
	# so it is a stable handle and reveals only synthetic labels when expanded.
	ab find text "Add a health check endpoint to" click >/dev/null 2>&1 || true
	ab wait 4000 >/dev/null

	# 3. One agent conversation in the MLflow interface: open the seeded trace so
	#    the recording shows its turn and tool structure, not just the trace list.
	info "route: an MLflow conversation"
	ab open "${base_url}/mlflow/#/experiments/1/traces" >/dev/null
	ab wait --text "Add a health check endpoint" >/dev/null 2>&1 || true
	ab wait 3000 >/dev/null
	ab find text "Got it" click >/dev/null 2>&1 || true
	ab find text "Close guidance" click >/dev/null 2>&1 || true
	ab wait 1000 >/dev/null
	ab find text "Add a health check endpoint to the demo web store service." click >/dev/null 2>&1 \
		|| ab find first "tbody a" click >/dev/null 2>&1 || true
	ab wait --text "Inputs" >/dev/null 2>&1 || true
	ab wait 5000 >/dev/null
}

# --- Convert -----------------------------------------------------------------
convert_video() {
	local dur
	dur="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$webm_path" 2>/dev/null || echo 0)"
	info "recording duration: ${dur}s (cap ${MAX_SECONDS}s)"
	# Cap the output at MAX_SECONDS with ffmpeg's -t, so a route that ran long
	# still yields a within-budget video rather than failing the budget check.
	rm -f "${repo_root:?}/${MP4_PATH}"
	if ! ffmpeg -y -i "$webm_path" -t "$MAX_SECONDS" \
		-c:v libx264 -pix_fmt yuv420p -movflags +faststart -an \
		-vf "fps=24,scale=trunc(iw/2)*2:trunc(ih/2)*2" \
		"${repo_root}/${MP4_PATH}" >/dev/null 2>&1; then
		fail "ffmpeg failed to convert the recording to ${MP4_PATH}." \
			"confirm ffmpeg 7.x is installed and that the WebM at ${webm_path} is non-empty." \
			"re-run 'scripts/capture.walkthrough.sh'."
	fi

	local out_dur out_bytes
	out_dur="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "${repo_root}/${MP4_PATH}" 2>/dev/null || echo 0)"
	out_bytes="$(wc -c <"${repo_root}/${MP4_PATH}" | tr -d ' ')"
	# Assert the duration budget.
	if awk -v d="$out_dur" -v m="$MAX_SECONDS" 'BEGIN{exit !(d > m + 0.5)}'; then
		fail "the converted video runs ${out_dur}s, over the ${MAX_SECONDS}s budget." \
			"shorten the route in drive_route() so the recording is under ${MAX_SECONDS}s." \
			"re-run 'scripts/capture.walkthrough.sh'."
	fi
	# Assert the size budget.
	if [ "$out_bytes" -gt "$MAX_MP4_BYTES" ]; then
		fail "the converted video is ${out_bytes} bytes, over the $((MAX_MP4_BYTES / 1024 / 1024)) MB budget." \
			"lower the fps or the resolution in convert_video(), or shorten the route." \
			"re-run 'scripts/capture.walkthrough.sh'."
	fi

	if [ "${WALKTHROUGH_MAKE_GIF:-0}" = "1" ]; then
		info "writing the optional gif preview to ${GIF_PATH}"
		rm -f "${repo_root:?}/${GIF_PATH}"
		ffmpeg -y -i "${repo_root}/${MP4_PATH}" \
			-vf "fps=8,scale=720:-1:flags=lanczos" "${repo_root}/${GIF_PATH}" >/dev/null 2>&1 || true
	fi

	pass "wrote ${MP4_PATH} (${out_dur}s, ${out_bytes} bytes); WebM original left outside the tree at ${webm_path}."
}

# --- Run ---------------------------------------------------------------------
assert_only_seeded
mkdir -p "$webm_dir"
rm -f "$webm_path"
open_session
grafana_login
info "recording to ${webm_path} (outside the working tree, never committed)"
ab record start "$webm_path" >/dev/null
drive_route
ab record stop >/dev/null
ab close >/dev/null 2>&1 || true
SESSION=""
if [ ! -s "$webm_path" ]; then
	fail "no WebM recording was written to ${webm_path}." \
		"confirm ffmpeg is on PATH (agent-browser record needs it) and that the session recorded." \
		"re-run 'scripts/capture.walkthrough.sh'."
fi
convert_video
