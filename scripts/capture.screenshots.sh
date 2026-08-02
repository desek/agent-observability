#!/usr/bin/env bash
#
# capture.screenshots.sh
#
# @agents-index Drives agent-browser to capture the two committed README images (the baseline Grafana dashboard and one MLflow conversation) from seeded synthetic data only, refusing before any frame is taken if the stack holds telemetry not carrying the git_org="demo-seed" marker, with the viewport, theme, and reduced motion pinned and Grafana authenticated first.
#
# Purpose: produce the two still images the README embeds, reproducibly and from
# data that was never real. Every variable that would make a capture depend on a
# machine default is pinned here through agent-browser: the viewport, the dark
# theme, and reduced motion. Grafana runs with anonymous access disabled, so the
# script authenticates through the login form before it navigates, otherwise it
# would photograph a login page.
#
# The leak check is the load-bearing control and it runs BEFORE any capture,
# never after, because a frame already written cannot be made safe by a later
# assertion. It asserts that every git_org label value present in the metric
# store (Mimir) and the log store (Loki), within the window the images capture,
# is exactly the seeded marker "demo-seed". Any other value means real or
# unseeded telemetry is in the window, and an expanded Grafana panel or log line
# would reveal a real email address, user identifier, or repository name into a
# public image. When that happens the script refuses and captures nothing. The
# log store is checked and not only the metric store, because an expanded Loki
# log line reveals the identity fields (user_email, user_id, and the rest)
# directly, per the privacy rules in AGENTS.md.
#
# Why agent-browser and not another driver: it is this machine's standard browser
# driver for agents, and it provides the viewport, theme, animation, wait, and
# screenshot controls this script needs as first-class commands. The house
# conventions for driving it live in the agent-browser-specialization skill.
#
# Usage:
#   scripts/capture.screenshots.sh          Capture both images, refusing if any
#                                            unseeded telemetry is in the window.
#   scripts/capture.screenshots.sh --verify Do not write; open each view live and
#                                            report its pixel difference against the
#                                            committed baseline, so reproducibility
#                                            is a check rather than a claim (FR20,
#                                            NFR2, AC-8). Refuses on unseeded data
#                                            just like a capture. Reports the diff
#                                            per image and exits non-zero only when
#                                            a difference exceeds CAPTURE_DIFF_MAX,
#                                            which is a structural change (an
#                                            interface moved) rather than the small
#                                            timestamp noise a fresh seed produces.
#   scripts/capture.screenshots.sh -h       Print this usage and exit 0.
#
# Parameters:
#   --verify     Compare each live view against its committed baseline instead of
#                writing new images. Uses agent-browser diff screenshot --baseline.
#   -h, --help   Print usage and exit 0.
#
# Environment:
#   EDGE_PORT             Loopback host port the edge proxy publishes. Read from
#                         the shell first, then from .env, then defaults to 24317.
#   GRAFANA_USER          Grafana login user. Defaults to admin.
#   GRAFANA_PASSWORD      Grafana login password. Defaults to admin.
#   CAPTURE_WINDOW_SECS   The look-back window, in seconds, the leak check and the
#                         dashboard both use. Defaults to 21600 (6h), matching the
#                         dashboard's own default range.
#   CAPTURE_DIFF_MAX      --verify only. The largest pixel-difference percentage
#                         that still counts as reproduced. Defaults to 8. A live
#                         re-seed moves timestamps and the MLflow-computed latency,
#                         so a faithful re-capture still differs by a few percent;
#                         a structural interface change differs by far more.
#   CAPTURE_HEADED        Set to 1 to run headed so the run can be watched;
#                         defaults to headless, so no attended desktop is needed.
#
# Output (fixed paths):
#   docs/images/dashboard.png            The baseline dashboard, all four rows.
#   docs/images/mlflow-conversation.png  One synthetic MLflow conversation.
#
# Exit status: 0 on success; non-zero on the first failure or on a leak refusal,
# with a message that names what failed, the fix, and what to check after.

set -euo pipefail

# --- Location ----------------------------------------------------------------
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

# --- Usage -------------------------------------------------------------------
usage() {
	sed -n '3,73p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

mode="capture"
case "${1:-}" in
	-h | --help)
		usage
		exit 0
		;;
	--verify)
		mode="verify"
		;;
	"") ;;
	*)
		echo "capture: FAIL unknown argument '$1'." >&2
		echo "  Fix: run 'scripts/capture.screenshots.sh' to capture, '--verify' to compare against the baselines, or '-h' for usage." >&2
		echo "  After: re-run the command without the extra argument." >&2
		exit 2
		;;
esac

cd "$repo_root"

# --- Reporting helpers -------------------------------------------------------
info() { echo "capture: $1"; }
pass() { echo "capture: PASS $1"; }
fail() {
	local what="$1" fix="$2" after="$3"
	echo "capture: FAIL $what" >&2
	echo "  Fix: $fix" >&2
	echo "  After: $after" >&2
	exit 1
}

# --- Preconditions -----------------------------------------------------------
for tool in curl jq agent-browser; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		fail "the required tool '$tool' is not installed." \
			"install '$tool' (agent-browser is this machine's browser driver; see the agent-browser-specialization skill)." \
			"re-run 'scripts/capture.screenshots.sh' once '$tool' is on PATH."
	fi
done

# --- Port resolution ---------------------------------------------------------
# The shell environment wins, then .env, then the default, matching how docker
# compose resolves EDGE_PORT so the script and the stack never disagree. Only the
# EDGE_PORT line is read from .env, so no other value in that file is touched.
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
diff_max="${CAPTURE_DIFF_MAX:-8}"

# --- Constants ---------------------------------------------------------------
readonly DEMO_ORG="demo-seed"
readonly VIEW_W=1440
readonly VIEW_H=900
# The dashboard is taller than one baseline viewport, and Grafana virtualizes
# panels that are off-screen: a scrolling capture would show only the panels in
# view. A viewport tall enough to hold the whole dashboard keeps every panel in
# view, so all four rows render and populate before the single frame is taken.
readonly DASH_VIEW_H=2600
# The MLflow trace detail is shorter than the dashboard; this height holds the
# span tree, the attributes panel, and the trace-breakdown graph in one frame.
readonly MLFLOW_VIEW_H=1100
readonly DASH_PATH="docs/images/dashboard.png"
readonly MLFLOW_PATH="docs/images/mlflow-conversation.png"

# --- Reachability ------------------------------------------------------------
require_stack() {
	local code
	code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${base_url}/alloy/-/healthy" || true)"
	if [ "$code" != "200" ]; then
		fail "the stack did not answer on port ${edge_port} (health returned '${code}')." \
			"start the stack with 'scripts/stack.up.sh' and confirm it with 'scripts/stack.verify.sh'." \
			"re-run 'scripts/capture.screenshots.sh' once the stack answers on port ${edge_port}."
	fi
}

# --- The leak check, before any capture --------------------------------------
# Collect every git_org label value present in Mimir and in Loki within the
# capture window, and refuse unless the only value is the seeded marker. Runs
# first so no frame is ever taken while unseeded telemetry is in the window.
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
		fail "unseeded telemetry is present in the ${window_secs}s capture window. Found git_org values other than '${DEMO_ORG}': ${unseeded}. Capturing now could publish a real email address, user identifier, prompt, or repository name into a public image, which cannot be recalled." \
			"wipe THIS stack's volumes with 'docker compose down -v' (verify first that 'docker compose ls' shows you are on project 'agent-observability' on port ${edge_port}, NEVER 'observability' on 24317), bring it back with 'scripts/stack.up.sh', seed synthetic data with 'scripts/demo.seed.sh', then re-run this script." \
			"re-run 'scripts/capture.screenshots.sh'; it must report only git_org='${DEMO_ORG}' before it captures."
	fi

	# A stack with no seeded data at all would capture empty panels; catch that too.
	if ! printf '%s\n' "$mimir" "$loki" | grep -qx "$DEMO_ORG"; then
		fail "no seeded telemetry (git_org=${DEMO_ORG}) is present in the ${window_secs}s window, so the capture would show empty panels." \
			"seed synthetic data with 'scripts/demo.seed.sh', then re-run this script." \
			"re-run 'scripts/capture.screenshots.sh' once the seed reports success."
	fi
	pass "leak check clear: only git_org=${DEMO_ORG} telemetry is in the capture window."
}

# --- Browser session ---------------------------------------------------------
SESSION=""
cleanup() {
	if [ -n "$SESSION" ]; then
		agent-browser --session "$SESSION" close >/dev/null 2>&1 || true
	fi
}
trap cleanup EXIT

ab() { agent-browser --session "$SESSION" "$@"; }

open_session() {
	SESSION="$(date +%s)-cr0007-screenshots"
	local headed=()
	[ "${CAPTURE_HEADED:-0}" = "1" ] && headed=(--headed)
	# Pin the viewport, the theme, and reduced motion so no capture depends on a
	# machine default and none is taken mid-transition.
	agent-browser --session "$SESSION" "${headed[@]}" open "${base_url}/login" >/dev/null
	ab set viewport "$VIEW_W" "$VIEW_H" >/dev/null
	ab set media dark reduced-motion >/dev/null
	ab wait --load networkidle >/dev/null || true
}

# Grafana runs with anonymous access disabled, so authenticate through the login
# form before navigating. A fresh admin login is met by a change-password prompt
# that is skipped, otherwise the capture would show that prompt.
grafana_login() {
	info "authenticating to Grafana as ${grafana_user}"
	ab open "${base_url}/login" >/dev/null
	ab wait --load networkidle >/dev/null || true
	ab fill 'input[name=user]' "$grafana_user" >/dev/null
	ab fill 'input[name=password]' "$grafana_password" >/dev/null
	ab click 'button[type=submit]' >/dev/null
	ab wait --load networkidle >/dev/null || true
	# Dismiss the default-password change prompt if it appears.
	ab find text "Skip" click >/dev/null 2>&1 || true
	ab wait --load networkidle >/dev/null || true
	local url
	url="$(ab get url 2>/dev/null || true)"
	case "$url" in
		*"/login"*)
			fail "Grafana login did not complete; the browser is still on the login page." \
				"confirm the Grafana credentials (GRAFANA_USER and GRAFANA_PASSWORD, default admin and admin) and that the stack is healthy." \
				"re-run 'scripts/capture.screenshots.sh' with the correct credentials."
			;;
	esac
}

# --- Navigation, shared by capture and verify --------------------------------
# Each nav_* function leaves the browser on the exact view an image is taken
# from, so a capture and a --verify comparison photograph the same thing.
nav_dashboard() {
	# Set a viewport tall enough to hold the whole dashboard, so every panel stays
	# in view and renders (Grafana does not query panels scrolled out of view).
	ab set viewport "$VIEW_W" "$DASH_VIEW_H" >/dev/null
	# Kiosk mode hides the Grafana chrome so the image is the dashboard itself.
	ab open "${base_url}/d/agent-observability/coding-agent-observability?from=now-${window_secs}s&to=now&kiosk" >/dev/null
	ab wait --load networkidle >/dev/null || true
	# Settle on the first row heading, then on a bottom panel heading so the whole
	# height has rendered, then a reduced-motion settle for the charts and tables.
	ab wait --text "Overview" >/dev/null 2>&1 || true
	ab wait --text "Recent agent traces" >/dev/null 2>&1 || true
	ab wait 8000 >/dev/null
}

nav_mlflow() {
	ab set viewport "$VIEW_W" "$MLFLOW_VIEW_H" >/dev/null
	ab open "${base_url}/mlflow/#/experiments/1/traces" >/dev/null
	ab wait --load networkidle >/dev/null || true
	ab wait --text "Add a health check endpoint" >/dev/null 2>&1 || true
	ab wait 2500 >/dev/null
	# Dismiss any first-visit guidance popovers on the trace list before the click,
	# otherwise the click lands on the popover rather than on the trace.
	ab find text "Got it" click >/dev/null 2>&1 || true
	ab find text "Close guidance" click >/dev/null 2>&1 || true
	ab wait 1000 >/dev/null
	# Open the seeded conversation by its request cell. The request text is one the
	# seed writes, so it is a stable handle.
	ab find text "Add a health check endpoint to the demo web store service." click >/dev/null 2>&1 \
		|| ab find first "tbody a" click >/dev/null 2>&1 || true
	ab wait --text "Inputs" >/dev/null 2>&1 || true
	ab wait 2500 >/dev/null
	# Switch to Details and Timeline, select the first assistant turn, then open its
	# Attributes. The Summary view shows the turns and tools but not the token and
	# cost detail; the Attributes panel of a turn span shows tokens.input,
	# tokens.output, cost_usd, and latency_ms, which is what AC-4 requires in frame
	# alongside the turn and tool structure the left-hand span tree keeps visible.
	ab find text "Details & Timeline" click >/dev/null 2>&1 || true
	ab wait 1500 >/dev/null
	ab find text "assistant_turn_1" click >/dev/null 2>&1 || true
	ab wait 1000 >/dev/null
	ab find text "Attributes" click --exact >/dev/null 2>&1 || true
	ab wait 1500 >/dev/null
}

# --- Write one image ---------------------------------------------------------
write_image() {
	local path="$1" label="$2"
	info "capturing the ${label} to ${path}"
	rm -f "${repo_root}/${path}"
	ab screenshot "${repo_root}/${path}" >/dev/null
	if [ ! -s "${repo_root}/${path}" ]; then
		fail "the ${label} image was not written to ${path}." \
			"confirm agent-browser is installed ('agent-browser install') and that the view loads on port ${edge_port}." \
			"re-run 'scripts/capture.screenshots.sh'."
	fi
}

# --- Compare one live view against its committed baseline --------------------
# Runs agent-browser's pixel diff between the current live view and the committed
# image, prints the difference, and returns non-zero when it exceeds diff_max.
# Sets verify_failed when a comparison is over budget, so the caller can exit
# with the right status after reporting every image rather than on the first.
verify_failed=0
report_diff() {
	local path="$1" label="$2" out pct
	if [ ! -s "${repo_root}/${path}" ]; then
		fail "no committed baseline at ${path} to compare against." \
			"capture the baselines first with 'scripts/capture.screenshots.sh', commit them, then re-run '--verify'." \
			"re-run 'scripts/capture.screenshots.sh --verify' once the baseline exists."
	fi
	out="$(ab diff screenshot --baseline "${repo_root}/${path}" 2>&1 || true)"
	# The tool prints a line like "✗ 3.52% pixels differ"; pull the percentage out.
	pct="$(printf '%s\n' "$out" | grep -oE '[0-9]+\.[0-9]+%' | head -1 | tr -d '%')"
	if [ -z "$pct" ]; then
		fail "could not read a difference percentage from the ${label} comparison. agent-browser said: ${out}" \
			"confirm the view loaded and 'agent-browser diff screenshot --baseline' works on this version." \
			"re-run 'scripts/capture.screenshots.sh --verify'."
	fi
	if awk -v p="$pct" -v m="$diff_max" 'BEGIN{exit !(p+0 <= m+0)}'; then
		pass "${label} reproduced: ${pct}% of pixels differ from the baseline (within the ${diff_max}% budget; the remainder is fresh-seed timestamp noise)."
	else
		echo "capture: DIFF ${label} differs by ${pct}% from the committed baseline, over the ${diff_max}% budget." >&2
		echo "  This is a structural difference, not timestamp noise: the interface or the seeded shape changed." >&2
		echo "  Fix: re-capture with 'scripts/capture.screenshots.sh' and review the new image before committing it." >&2
		echo "  After: re-run '--verify' and confirm every image is within budget." >&2
		verify_failed=1
	fi
}

# --- Run ---------------------------------------------------------------------
assert_only_seeded
open_session
grafana_login
if [ "$mode" = "verify" ]; then
	info "verify: comparing each live view against its committed baseline (budget ${diff_max}% pixels, port ${edge_port})"
	nav_dashboard
	report_diff "$DASH_PATH" "dashboard"
	nav_mlflow
	report_diff "$MLFLOW_PATH" "MLflow conversation"
	if [ "$verify_failed" -ne 0 ]; then
		exit 1
	fi
	pass "both committed images are reproducible from the seeded data within the ${diff_max}% budget."
else
	nav_dashboard
	write_image "$DASH_PATH" "dashboard"
	nav_mlflow
	write_image "$MLFLOW_PATH" "MLflow conversation"
	pass "wrote ${DASH_PATH} and ${MLFLOW_PATH} from seeded synthetic data only."
fi
