#!/usr/bin/env bash
#
# demo.seed.sh
#
# @agents-index Writes a marked synthetic telemetry dataset (metrics, logs, traces, and one MLflow conversation) into the running stack so every dashboard panel populates from data that was never real, and clears the seeded data with --clear; every seeded series and stream carries the git_org="demo-seed" marker and carries no email, user identifier, or real repository name.
#
# Purpose: fill the running stack with plausible, obviously synthetic telemetry
# so the README screenshots and the walkthrough are captured from data that was
# never real, and so a user with an empty stack can see every view populated
# within a minute of cloning. It emits, through the single edge port and the
# same OTLP ingress the real agents use, several sessions for both agents across
# a handful of invented repositories and branches, with costs, token counts
# split by type, tool decisions, lines of code, commits, and pull requests, plus
# matching readable log lines and traces, and one multi-turn MLflow conversation
# with tool calls, token counts, costs, and latencies. Every value is invented.
# No email address, no user identifier, and no real repository name appears
# anywhere. Every seeded series and stream carries the marker git_org="demo-seed"
# so a user who seeds and forgets can tell it from real data at a glance.
#
# Why OTLP and not a backend push API: the real agents export OTLP to Alloy,
# which promotes the git provenance resource attributes to labels and rewrites
# log bodies into readable one-line summaries. Emitting the same OTLP shape makes
# the seeded data identical in structure to real data, so the dashboard's own
# committed queries return it with no special case.
#
# Why the marker is git_org: Mimir and Loki both promote git.org, git.repo,
# git.branch, and git.path from OTLP resource attributes onto every series and
# stream (see stack/mimir/config.yaml and stack/loki/config.yaml). Encoding the
# marker as git_org="demo-seed" therefore stamps it on every metric series and
# every log stream as a first-class, queryable label, distinct from the real
# git_org value, so --clear and the leak assertions can select seeded data
# precisely and never touch real data.
#
# What --clear can and cannot remove, and why: this stack's stores provide no
# surgical delete. Mimir 3.1.2 has no series or tenant deletion API at any
# configuration; Loki's delete API is disabled here and, even enabled, applies
# no sooner than its cancel period; and Tempo has no delete-by-query. The only
# full wipe is `docker compose down -v`, which removes real telemetry too. So
# --clear removes seeded data by the two surgical means the stack does support:
# it re-emits every seeded metric series as a counter-reset (value 0 at a later
# timestamp), which makes every dashboard metric panel, all of which read with
# last_over_time, return zero for the seeded series while real series are
# untouched; and it deletes the seeded MLflow conversation through the tracking
# server's delete-traces API, selected by the demo_seed tag so real traces stay.
# The seeded Loki log streams and Tempo traces carry the git_org="demo-seed"
# marker and cannot be surgically deleted on this stack; --clear reports this and
# names `docker compose down -v` as the only full removal, per the README.
#
# Usage:
#   scripts/demo.seed.sh            Seed the synthetic dataset into the running stack.
#   scripts/demo.seed.sh --clear    Remove the seeded metric series and MLflow
#                                    conversation; report the log and trace stores.
#   scripts/demo.seed.sh -h         Print this usage and exit 0.
#
# Parameters:
#   -h, --help   Print usage and exit 0.
#   --clear      Remove what a prior seed wrote, leaving real telemetry alone.
#
# Environment:
#   EDGE_PORT    Loopback host port the edge proxy publishes. Read from the shell
#                first, then from .env, then defaults to 24317. The stack address
#                is derived from it and is never hard-coded.
#
# Exit status: 0 on success; non-zero on the first failure, with a message that
# names what failed, the fix, and what to check after.

set -euo pipefail

# --- Location ----------------------------------------------------------------
# Resolve the repository root from the script location so the script runs the
# same way from any working directory.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

# --- Usage -------------------------------------------------------------------
usage() {
	sed -n '3,70p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

mode="seed"
case "${1:-}" in
	-h | --help)
		usage
		exit 0
		;;
	--clear)
		mode="clear"
		;;
	"") ;;
	*)
		echo "seed: FAIL unknown argument '$1'." >&2
		echo "  Fix: run 'scripts/demo.seed.sh' to seed, '--clear' to remove, or '-h' for usage." >&2
		echo "  After: re-run the command with a supported argument." >&2
		exit 2
		;;
esac

cd "$repo_root"

# --- Reporting helpers -------------------------------------------------------
info() { echo "seed: $1"; }
pass() { echo "seed: PASS $1"; }
fail() {
	local what="$1" fix="$2" after="$3"
	echo "seed: FAIL $what" >&2
	echo "  Fix: $fix" >&2
	echo "  After: $after" >&2
	exit 1
}

# --- Preconditions -----------------------------------------------------------
for tool in curl jq; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		fail "the required tool '$tool' is not installed." \
			"install '$tool' (for example 'brew install $tool'), which this script uses to build payloads and talk to the stack." \
			"re-run 'scripts/demo.seed.sh' once '$tool' is on PATH."
	fi
done

# --- Port resolution ---------------------------------------------------------
# The shell environment wins, then .env, then the default. This matches how
# docker compose resolves EDGE_PORT, so the script and the stack never disagree.
# Only the EDGE_PORT line is read from .env, so no other value in that file is
# touched.
resolve_edge_port() {
	local port="${EDGE_PORT:-}"
	if [ -z "$port" ] && [ -f "$repo_root/.env" ]; then
		port="$(grep -E '^[[:space:]]*EDGE_PORT[[:space:]]*=' "$repo_root/.env" | tail -n1 | cut -d= -f2 | tr -d '[:space:]')"
	fi
	printf '%s' "${port:-24317}"
}

edge_port="$(resolve_edge_port)"
base_url="http://127.0.0.1:${edge_port}"

# --- Constants ---------------------------------------------------------------
# The marker. Encoded as the promoted git.org resource attribute so it lands as
# a queryable git_org label on every metric series and every Loki stream, and as
# a tag on the MLflow conversation. Distinct from any real git_org value.
readonly DEMO_ORG="demo-seed"
# The MLflow agent experiment identifier the conversation is written to and
# selected from. The experiment name (claude-code) is set inside the Python block.
readonly MLFLOW_EXPERIMENT_ID="1"

# --- Reachability ------------------------------------------------------------
require_stack() {
	local code
	code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${base_url}/alloy/-/healthy" || true)"
	if [ "$code" != "200" ]; then
		fail "the OTLP ingress did not answer on port ${edge_port} (health returned '${code}')." \
			"start the stack with 'scripts/stack.up.sh' and confirm it is healthy with 'scripts/stack.verify.sh'." \
			"re-run 'scripts/demo.seed.sh' once the stack answers on port ${edge_port}."
	fi
}

# --- The synthetic session set ----------------------------------------------
# A fixed, deterministic set of sessions so that a --clear run reproduces the
# exact same label sets it seeded and can zero every series. Fields per row:
#   agent  repo  branch  model  session_id  cost_cents
# The agent is cc (Claude Code, service.name claude-code, claude_code.* metrics)
# or pi (service.name pi-coding-agent, pi.* metrics). pi seeds only the families
# real pi emits (cost, session, token); Claude Code seeds the full set. Costs are
# uneven across repositories on purpose, so the picture is representative rather
# than flattering.
sessions=(
	"cc demo-web-store main claude-opus-demo demo-session-01 214"
	"cc demo-web-store feat/checkout-flow claude-sonnet-demo demo-session-02 61"
	"cc demo-billing-api fix/token-refresh claude-sonnet-demo demo-session-03 88"
	"cc demo-billing-api main claude-opus-demo demo-session-04 133"
	"cc demo-mobile-app feat/checkout-flow claude-sonnet-demo demo-session-05 27"
	"cc demo-infra-tools chore/upgrade-deps claude-sonnet-demo demo-session-06 19"
	"cc demo-web-store main claude-opus-demo demo-session-07 176"
	"cc demo-mobile-app main claude-sonnet-demo demo-session-08 33"
	"pi demo-web-store main pi-model-demo demo-session-09 42"
	"pi demo-billing-api fix/token-refresh pi-model-demo demo-session-10 58"
	"pi demo-mobile-app main pi-model-demo demo-session-11 15"
	"pi demo-infra-tools chore/upgrade-deps pi-model-demo demo-session-12 24"
)

# Short, obviously synthetic conversation snippets about a fictional task. No
# identity, no real repository name, no real prompt content.
prompt_for() {
	case "$1" in
		demo-web-store) echo "Add a health check endpoint to the demo web store service." ;;
		demo-billing-api) echo "Fix the token refresh timeout in the demo billing API." ;;
		demo-mobile-app) echo "Update the demo mobile app to read the new config flag." ;;
		*) echo "Upgrade the pinned dependencies in the demo infra tools repo." ;;
	esac
}
response_for() {
	case "$1" in
		demo-web-store) echo "Added a /healthz route and a test that asserts it returns 200." ;;
		demo-billing-api) echo "Raised the refresh timeout and added a retry with backoff." ;;
		demo-mobile-app) echo "Wired the config flag through and covered it with a unit test." ;;
		*) echo "Bumped the three pinned versions and confirmed the build passes." ;;
	esac
}

# --- OTLP resource attributes -------------------------------------------------
# Build the resource attribute array shared by a session's metrics, logs, and
# traces. service.name becomes the job / service_name label; the git.* attributes
# are promoted to git_org/git_repo/git_branch/git_path labels, and git.org is the
# marker.
resource_attrs_json() {
	local service_name="$1" repo="$2" branch="$3"
	jq -n --arg sn "$service_name" --arg org "$DEMO_ORG" --arg repo "$repo" \
		--arg branch "$branch" --arg path "/demo/$repo" '[
		{key:"service.name", value:{stringValue:$sn}},
		{key:"git.org", value:{stringValue:$org}},
		{key:"git.repo", value:{stringValue:$repo}},
		{key:"git.branch", value:{stringValue:$branch}},
		{key:"git.path", value:{stringValue:$path}}
	]'
}

# --- Metric emission ---------------------------------------------------------
# Post one cumulative monotonic Sum data point. The metric name is the desired
# Prometheus stem with dots for underscores; Mimir appends _total (see
# otel_metric_suffixes_enabled), so claude_code.cost.usage.USD becomes
# claude_code_cost_usage_USD_total. value_kind is asInt or asDouble. attrs_json
# is a (possibly empty) JSON array of data-point attributes such as type or model.
push_metric() {
	local service_name="$1" repo="$2" branch="$3" name="$4" value_kind="$5" value="$6" attrs_json="$7" ts_ns="$8"
	local res
	res="$(resource_attrs_json "$service_name" "$repo" "$branch")"
	local point
	point="$(jq -n --arg v "$value" --arg ts "$ts_ns" --argjson attrs "$attrs_json" \
		--arg kind "$value_kind" '{($kind): ($v|tonumber), timeUnixNano:$ts, startTimeUnixNano:$ts, attributes:$attrs}')"
	local body
	body="$(jq -n --argjson res "$res" --arg name "$name" --argjson point "$point" '{
		resourceMetrics: [{
			resource: {attributes: $res},
			scopeMetrics: [{
				scope: {name: "demo.seed"},
				metrics: [{name: $name, sum: {aggregationTemporality: 2, isMonotonic: true, dataPoints: [$point]}}]
			}]
		}]
	}')"
	local code
	code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -X POST "${base_url}/v1/metrics" \
		-H 'Content-Type: application/json' --data-binary "$body" || true)"
	if [ "$code" != "200" ]; then
		fail "the OTLP metrics endpoint returned '${code}' for '${name}', not 200." \
			"confirm Alloy is healthy ('scripts/stack.verify.sh') and that port ${edge_port} reaches /v1/metrics." \
			"re-run 'scripts/demo.seed.sh' once the metrics endpoint returns 200."
	fi
}

# Emit every metric family for one session. In clear mode every value is 0, which
# resets the cumulative counter so last_over_time returns 0 for the seeded series.
seed_session_metrics() {
	local agent="$1" repo="$2" branch="$3" model="$4" sid="$5" cost_cents="$6" ts_ns="$7" zero="$8"
	local service_name cost tokens_in tokens_out cache_read cache_create active added removed accepts rejects commits prs
	if [ "$agent" = "cc" ]; then service_name="claude-code"; local ns="claude_code"; else service_name="pi-coding-agent"; local ns="pi"; fi

	# Deterministic per-session values derived from the session number, so a clear
	# run reproduces the identical label sets. Zero mode blanks every value.
	local n="${sid##*-}"; n="$((10#$n))"
	cost="$(awk -v c="$cost_cents" 'BEGIN{printf "%.6f", c/100}')"
	tokens_in="$((1800 + n * 130))"
	tokens_out="$((420 + n * 25))"
	cache_read="$((5200 + n * 300))"
	cache_create="$((900 + n * 40))"
	active="$((180 + n * 47))"
	added="$((40 + n * 9))"
	removed="$((6 + n * 2))"
	accepts="$((3 + n % 4))"
	rejects="$((n % 3))"
	commits="$((1 + n % 2))"
	prs="$(( n % 2 ))"

	if [ "$zero" = "zero" ]; then
		cost=0; tokens_in=0; tokens_out=0; cache_read=0; cache_create=0
		active=0; added=0; removed=0; accepts=0; rejects=0; commits=0; prs=0
	fi

	local sid_attr
	sid_attr="$(jq -n --arg s "$sid" '[{key:"session_id", value:{stringValue:$s}}]')"

	# Cost, split by model.
	local model_attr
	model_attr="$(jq -n --arg m "$model" --arg s "$sid" '[{key:"model",value:{stringValue:$m}},{key:"session_id",value:{stringValue:$s}}]')"
	push_metric "$service_name" "$repo" "$branch" "${ns}.cost.usage.USD" asDouble "$cost" "$model_attr" "$ts_ns"
	# Session count.
	push_metric "$service_name" "$repo" "$branch" "${ns}.session.count" asInt 1 "$sid_attr" "$ts_ns"
	# Tokens, split by type and carrying the model.
	local t
	for t in "input $tokens_in" "output $tokens_out" "cacheRead $cache_read" "cacheCreation $cache_create"; do
		local ttype="${t%% *}" tval="${t##* }" tattr
		tattr="$(jq -n --arg ty "$ttype" --arg m "$model" --arg s "$sid" '[{key:"type",value:{stringValue:$ty}},{key:"model",value:{stringValue:$m}},{key:"session_id",value:{stringValue:$s}}]')"
		push_metric "$service_name" "$repo" "$branch" "${ns}.token.usage.tokens" asInt "$tval" "$tattr" "$ts_ns"
	done

	# The remaining families are ones only Claude Code emits in this stack, which
	# mirrors the real data shape where pi carries cost, session, and tokens only.
	if [ "$agent" != "cc" ]; then
		return 0
	fi
	push_metric "$service_name" "$repo" "$branch" "${ns}.active_time.seconds" asDouble "$active" "$sid_attr" "$ts_ns"
	local lt
	for lt in "added $added" "removed $removed"; do
		local ltype="${lt%% *}" lval="${lt##* }" lattr
		lattr="$(jq -n --arg ty "$ltype" --arg s "$sid" '[{key:"type",value:{stringValue:$ty}},{key:"session_id",value:{stringValue:$s}}]')"
		push_metric "$service_name" "$repo" "$branch" "${ns}.lines_of_code.count" asInt "$lval" "$lattr" "$ts_ns"
	done
	local dt
	for dt in "accept $accepts" "reject $rejects"; do
		local dec="${dt%% *}" dval="${dt##* }" dattr
		dattr="$(jq -n --arg d "$dec" --arg s "$sid" '[{key:"decision",value:{stringValue:$d}},{key:"tool_name",value:{stringValue:"Edit"}},{key:"session_id",value:{stringValue:$s}}]')"
		push_metric "$service_name" "$repo" "$branch" "${ns}.code_edit_tool.decision" asInt "$dval" "$dattr" "$ts_ns"
	done
	push_metric "$service_name" "$repo" "$branch" "${ns}.commit.count" asInt "$commits" "$sid_attr" "$ts_ns"
	push_metric "$service_name" "$repo" "$branch" "${ns}.pull_request.count" asInt "$prs" "$sid_attr" "$ts_ns"

	# Tool calls, split by tool. Nothing else says which tools an agent actually
	# reaches for, and the shape is distinctive: a shell-heavy agent with a long
	# edit tail looks nothing like a research-heavy one.
	local tw
	for tw in "Bash 34" "Edit 12" "Read 9" "Write 4" "Grep 3" "WebFetch 1"; do
		local tname="${tw%% *}" tcount="${tw##* }" tattr
		tcount="$((tcount + n))"
		tattr="$(jq -n --arg t "$tname" --arg s "$sid" '[{key:"tool",value:{stringValue:$t}},{key:"session_id",value:{stringValue:$s}}]')"
		[ "$zero" = "zero" ] && tcount=0
		push_metric "$service_name" "$repo" "$branch" "${ns}.tool.use.count" asInt "$tcount" "$tattr" "$ts_ns"
	done

	# The subagent dimension. This is the one thing in the whole stack that shows
	# an agent delegating to another agent, so the seed must produce it or a fresh
	# clone cannot see the feature at all. Only some sessions delegate, which is
	# what real work looks like.
	if [ "$((n % 3))" -ne 0 ]; then
		return 0
	fi
	local sa
	for sa in "reviewer 3 620 41000 14" "implementor 2 1450 96000 31" "validator 1 380 22000 8"; do
		# shellcheck disable=SC2086
		set -- $sa
		local atype="$1" acount="$2" asecs="$3" atoks="$4" atools="$5" aattr
		asecs="$((asecs + n * 40))"; atoks="$((atoks + n * 900))"; atools="$((atools + n))"
		if [ "$zero" = "zero" ]; then acount=0; asecs=0; atoks=0; atools=0; fi
		aattr="$(jq -n --arg a "$atype" --arg s "$sid" '[{key:"agent_type",value:{stringValue:$a}},{key:"session_id",value:{stringValue:$s}}]')"
		push_metric "$service_name" "$repo" "$branch" "${ns}.subagent.count" asInt "$acount" "$aattr" "$ts_ns"
		push_metric "$service_name" "$repo" "$branch" "${ns}.subagent.duration.seconds" asDouble "$asecs" "$aattr" "$ts_ns"
		push_metric "$service_name" "$repo" "$branch" "${ns}.subagent.token.usage.tokens" asInt "$atoks" "$aattr" "$ts_ns"
		push_metric "$service_name" "$repo" "$branch" "${ns}.subagent.tool_use.count" asInt "$atools" "$aattr" "$ts_ns"
	done
}

# --- Log emission ------------------------------------------------------------
# Post one OTLP log record. body is the event name the Alloy transform matches
# (for example claude_code.user_prompt); attrs_json carries the fields the
# transform folds into the readable one-line summary. All original attributes
# stay in Loki structured metadata.
push_log() {
	local service_name="$1" repo="$2" branch="$3" body="$4" attrs_json="$5" ts_ns="$6"
	local res
	res="$(resource_attrs_json "$service_name" "$repo" "$branch")"
	local payload
	payload="$(jq -n --argjson res "$res" --arg body "$body" --argjson attrs "$attrs_json" --arg ts "$ts_ns" '{
		resourceLogs: [{
			resource: {attributes: $res},
			scopeLogs: [{
				scope: {name: "demo.seed"},
				logRecords: [{timeUnixNano: $ts, observedTimeUnixNano: $ts, body: {stringValue: $body}, attributes: $attrs}]
			}]
		}]
	}')"
	local code
	code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -X POST "${base_url}/v1/logs" \
		-H 'Content-Type: application/json' --data-binary "$payload" || true)"
	if [ "$code" != "200" ]; then
		fail "the OTLP logs endpoint returned '${code}', not 200." \
			"confirm Alloy is healthy ('scripts/stack.verify.sh') and that port ${edge_port} reaches /v1/logs." \
			"re-run 'scripts/demo.seed.sh' once the logs endpoint returns 200."
	fi
}

# Emit a short readable conversation and its tool events for one session. Each
# body matches an Alloy readable-line rule, so the Loki view shows lines like
# "[user_prompt] ..." and "[tool_decision] ...". One pi session also emits an
# error event so the picture includes an unhappy path.
seed_session_logs() {
	local agent="$1" repo="$2" branch="$3" model="$4" sid="$5" ts_ns="$6"
	local service_name ns
	if [ "$agent" = "cc" ]; then service_name="claude-code"; ns="claude_code"; else service_name="pi-coding-agent"; ns="pi"; fi
	local prompt response
	prompt="$(prompt_for "$repo")"
	response="$(response_for "$repo")"
	local n="${sid##*-}"; n="$((10#$n))"

	push_log "$service_name" "$repo" "$branch" "${ns}.user_prompt" \
		"$(jq -n --arg p "$prompt" '[{key:"prompt",value:{stringValue:$p}}]')" "$ts_ns"
	push_log "$service_name" "$repo" "$branch" "${ns}.api_request" \
		"$(jq -n --arg m "$model" --arg i "$((1800 + n * 130))" --arg o "$((420 + n * 25))" --arg c "0.0${n}42" --arg d "$((3000 + n * 210))" \
			'[{key:"model",value:{stringValue:$m}},{key:"input_tokens",value:{stringValue:$i}},{key:"output_tokens",value:{stringValue:$o}},{key:"cost_usd",value:{stringValue:$c}},{key:"duration_ms",value:{stringValue:$d}}]')" "$ts_ns"
	push_log "$service_name" "$repo" "$branch" "${ns}.tool_decision" \
		"$(jq -n '[{key:"tool_name",value:{stringValue:"Edit"}},{key:"decision",value:{stringValue:"accept"}},{key:"source",value:{stringValue:"config"}}]')" "$ts_ns"
	# One session shows a rejected decision, so the tool events are not all happy.
	if [ "$((n % 4))" -eq 0 ]; then
		push_log "$service_name" "$repo" "$branch" "${ns}.tool_decision" \
			"$(jq -n '[{key:"tool_name",value:{stringValue:"Bash"}},{key:"decision",value:{stringValue:"reject"}},{key:"source",value:{stringValue:"user"}}]')" "$ts_ns"
	fi
	push_log "$service_name" "$repo" "$branch" "${ns}.tool_result" \
		"$(jq -n --arg d "$((200 + n * 30))" '[{key:"tool_name",value:{stringValue:"Edit"}},{key:"success",value:{stringValue:"true"}},{key:"duration_ms",value:{stringValue:$d}}]')" "$ts_ns"
	# One pi session records an API error, the representative unhappy path.
	if [ "$agent" = "pi" ] && [ "$((n % 5))" -eq 0 ]; then
		push_log "$service_name" "$repo" "$branch" "pi.api_error" \
			"$(jq -n --arg m "$model" '[{key:"model",value:{stringValue:$m}},{key:"status_code",value:{stringValue:"529"}},{key:"error",value:{stringValue:"overloaded"}},{key:"duration_ms",value:{stringValue:"1200"}}]')" "$ts_ns"
	fi
	push_log "$service_name" "$repo" "$branch" "${ns}.assistant_response" \
		"$(jq -n --arg r "$response" '[{key:"response",value:{stringValue:$r}}]')" "$ts_ns"
}

# --- Trace emission ----------------------------------------------------------
# Post one OTLP trace shaped like a real agent session: a root span with tool
# children and subagent children beneath it, staggered and of differing lengths.
#
# Why the shape matters. A trace waterfall is the one view that shows an agent
# session decomposed, and it is the view most likely to make a newcomer look
# twice. A trace of two identical spans does not show that; a trace where a
# subagent runs for minutes while tool calls come and go around it does. The
# offsets and durations below are therefore deliberately uneven.
hex() { head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'; }

seed_session_trace() {
	local agent="$1" repo="$2" branch="$3" ts_ns="$4"
	local service_name
	if [ "$agent" = "cc" ]; then service_name="claude-code"; else service_name="pi-coding-agent"; fi
	local res trace_id root_id end_ns
	res="$(resource_attrs_json "$service_name" "$repo" "$branch")"
	trace_id="$(hex 16)"; root_id="$(hex 8)"
	# Ten minutes of session, which is a realistic length for a piece of agent work.
	end_ns="$((ts_ns + 600000000000))"

	# Each entry is: name, start offset in ms, duration in ms.
	local plan=(
		"tool.Bash 0 42000"
		"subagent.reviewer 15000 186000"
		"tool.Edit 62000 28000"
		"subagent.implementor 95000 243000"
		"tool.Read 152000 9000"
		"tool.Write 214000 15000"
		"tool.Bash 268000 63000"
		"subagent.validator 349000 121000"
		"tool.Edit 480000 34000"
	)

	local spans_json="[]" entry
	spans_json="$(jq -n --arg tid "$trace_id" --arg rid "$root_id" --arg start "$ts_ns" --arg end "$end_ns" \
		'[{traceId:$tid, spanId:$rid, name:"agent_session", kind:1,
		   startTimeUnixNano:$start, endTimeUnixNano:$end,
		   attributes:[{key:"demo_seed",value:{stringValue:"true"}}]}]')"
	for entry in "${plan[@]}"; do
		# shellcheck disable=SC2086
		set -- $entry
		local sname="$1" soff="$2" sdur="$3" sid_hex sstart send
		sid_hex="$(hex 8)"
		sstart="$((ts_ns + soff * 1000000))"
		send="$((sstart + sdur * 1000000))"
		local kindattr="tool"
		case "$sname" in subagent.*) kindattr="subagent" ;; esac
		spans_json="$(jq -n --argjson acc "$spans_json" --arg tid "$trace_id" --arg rid "$root_id" \
			--arg sid "$sid_hex" --arg nm "$sname" --arg st "$sstart" --arg en "$send" --arg ka "$kindattr" \
			'$acc + [{traceId:$tid, spanId:$sid, parentSpanId:$rid, name:$nm, kind:1,
			          startTimeUnixNano:$st, endTimeUnixNano:$en,
			          attributes:[{key:"span.kind.agent",value:{stringValue:$ka}},
			                      {key:"demo_seed",value:{stringValue:"true"}}]}]')"
	done

	local payload
	payload="$(jq -n --argjson res "$res" --argjson spans "$spans_json" '{
		resourceSpans: [{
			resource: {attributes: $res},
			scopeSpans: [{scope: {name: "demo.seed"}, spans: $spans}]
		}]
	}')"
	local code
	code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -X POST "${base_url}/v1/traces" \
		-H 'Content-Type: application/json' --data-binary "$payload" || true)"
	if [ "$code" != "200" ]; then
		fail "the OTLP traces endpoint returned '${code}', not 200." \
			"confirm Alloy is healthy ('scripts/stack.verify.sh') and that port ${edge_port} reaches /v1/traces." \
			"re-run 'scripts/demo.seed.sh' once the traces endpoint returns 200."
	fi
}

# --- MLflow conversation (Phase 2) -------------------------------------------
# Resolve a Python that can import mlflow 3.14, preferring an ephemeral uv-run
# client so no permanent install is required, exactly as the repo's tracing hook
# resolves a client. Prints the argv to run.
resolve_mlflow_python() {
	if command -v uv >/dev/null 2>&1; then
		echo "uv run --python 3.12 --with mlflow==3.14.0 python"
		return 0
	fi
	return 1
}

seed_mlflow_conversation() {
	local py
	if ! py="$(resolve_mlflow_python)"; then
		fail "no way to run an MLflow 3.14 client was found (uv is not installed)." \
			"install uv (https://docs.astral.sh/uv/) so the conversation can be written with a version-matched client, per the repo's tracing convention." \
			"re-run 'scripts/demo.seed.sh' once uv is on PATH."
	fi
	info "writing the synthetic MLflow conversation (this resolves an mlflow 3.14 client, first run may download it)"
	if ! MLFLOW_TRACKING_URI="${base_url}/mlflow" $py - <<'PY'
"""Write one marked, multi-turn synthetic conversation into the claude-code
experiment, shaped like a real traced agent session but with invented content:
a root conversation span, two assistant turns each with a tool call, and token,
cost, and latency attributes. The trace is tagged demo_seed=true so --clear can
select and delete it without touching real traces."""
import os
import mlflow

mlflow.set_tracking_uri(os.environ["MLFLOW_TRACKING_URI"])
mlflow.set_experiment("claude-code")

user_msg = "Add a health check endpoint to the demo web store service."
final = "Added a /healthz endpoint to the demo web store service, with a test."

with mlflow.start_span(name="demo_conversation", span_type="AGENT") as root:
    root.set_inputs({"messages": [{"role": "user", "content": user_msg}]})
    # session_id is a first-class parameter, stored as the mlflow.trace.session
    # metadata key. That key is what MLflow's Sessions view groups on, so a trace
    # written without it leaves that whole view empty.
    mlflow.update_current_trace(
        session_id="demo-session-01",
        tags={"demo_seed": "true", "git.org": "demo-seed", "git.repo": "demo-web-store"},
    )

    with mlflow.start_span(name="assistant_turn_1", span_type="LLM") as t1:
        t1.set_inputs({"prompt": user_msg})
        t1.set_attributes(
            {"model": "claude-opus-demo", "tokens.input": 2100,
             "tokens.output": 430, "cost_usd": 0.0231, "latency_ms": 4200}
        )
        with mlflow.start_span(name="Read", span_type="TOOL") as tool1:
            tool1.set_inputs({"file": "src/server.ts"})
            tool1.set_outputs({"lines": 128})
        t1.set_outputs({"response": "I will add a /healthz route to the server."})

    with mlflow.start_span(name="assistant_turn_2", span_type="LLM") as t2:
        t2.set_inputs({"prompt": "Now add a test for the endpoint."})
        t2.set_attributes(
            {"model": "claude-opus-demo", "tokens.input": 2540,
             "tokens.output": 610, "cost_usd": 0.0288, "latency_ms": 5100}
        )
        with mlflow.start_span(name="Edit", span_type="TOOL") as tool2:
            tool2.set_inputs({"file": "test/server.test.ts", "edits": 1})
            tool2.set_outputs({"applied": True})
        t2.set_outputs({"response": "Added a test that asserts /healthz returns 200."})

    root.set_outputs({"messages": [{"role": "assistant", "content": final}]})

print("seeded conversation trace:", root.trace_id)
PY
	then
		fail "writing the MLflow conversation failed." \
			"confirm the tracking server answers at ${base_url}/mlflow ('scripts/stack.verify.sh') and that uv can resolve mlflow==3.14.0." \
			"re-run 'scripts/demo.seed.sh' once the tracking server is reachable."
	fi
}

# --- Seed --------------------------------------------------------------------
do_seed() {
	require_stack
	# Samples are stamped within the last few minutes, spread so the time-series
	# panels show more than a single point.
	# Seeded activity spans session_step_seconds between sessions, which puts the
	# oldest session about one and a half hours back for the current
	# session set. The span is bounded by the narrowest backend, and each bound
	# below was measured against the running stack rather than read from a
	# default:
	#
	#   Loki   is the binding constraint at two hours. Its ingester refuses an
	#          entry older than that with "entry too far behind", governed by
	#          max_chunk_age and NOT by reject_old_samples, which is set false
	#          here and does not govern this check. The window is measured from
	#          the newest entry already in the stream, so a stream that already
	#          holds recent entries has a tighter window than a fresh one: a
	#          first probe against a new stream accepted seven hours, while a
	#          re-seed of an established stream accepted two. The seed must
	#          assume the established case, because that is what a second run is.
	#   Mimir  accepts far more, up to out_of_order_time_window, set to 72h here.
	#          A span under twelve hours has a second benefit: the querier reads
	#          it from the ingester rather than the long-term store, so it is
	#          visible immediately instead of after the bucket store
	#          synchronises, which takes up to fifteen minutes.
	#   Tempo  does not surface a back-dated trace at all. A trace written even
	#          ten minutes in the past is accepted with a success status and is
	#          never searchable. Traces are therefore written at the present
	#          moment rather than at the session's timestamp, which is why the
	#          trace call below uses its own value. The trace panel is a table of
	#          recent traces rather than a time series, so this costs nothing.
	#
	# Widening the picture past two hours therefore means raising Loki's
	# max_chunk_age, not changing this number.
	local session_step_seconds=480
	local now_s spread row agent repo branch model sid cost_cents ts_ns trace_ts_ns i=0
	now_s="$(date +%s)"
	info "seeding synthetic telemetry into the stack on port ${edge_port} (marker git_org=${DEMO_ORG})"
	for row in "${sessions[@]}"; do
		# shellcheck disable=SC2086
		set -- $row
		agent="$1"; repo="$2"; branch="$3"; model="$4"; sid="$5"; cost_cents="$6"
		spread=$(( i * session_step_seconds ))
		ts_ns="$(( (now_s - spread) * 1000000000 ))"
		seed_session_metrics "$agent" "$repo" "$branch" "$model" "$sid" "$cost_cents" "$ts_ns" "value"
		seed_session_logs "$agent" "$repo" "$branch" "$model" "$sid" "$ts_ns"
		if [ "$((i % 3))" -eq 0 ]; then
			# Present-moment timestamp, not the session's. Tempo does not surface a
			# back-dated trace, so a trace written at the session's own time would
			# be accepted and then never appear.
			trace_ts_ns="$(( $(date +%s) * 1000000000 ))"
			seed_session_trace "$agent" "$repo" "$branch" "$trace_ts_ns"
		fi
		i=$((i + 1))
	done
	seed_mlflow_conversation
	pass "seeded ${#sessions[@]} sessions of metrics, logs, and traces, and one MLflow conversation, all marked git_org=${DEMO_ORG}."
	info "capture the views now; run 'scripts/demo.seed.sh --clear' when done."
}

# --- Clear -------------------------------------------------------------------
clear_mlflow() {
	local search resp ids
	search="$(curl -s --max-time 15 "${base_url}/mlflow/api/3.0/mlflow/traces/search" \
		-H 'Content-Type: application/json' \
		-d "{\"locations\":[{\"type\":\"MLFLOW_EXPERIMENT\",\"mlflow_experiment\":{\"experiment_id\":\"${MLFLOW_EXPERIMENT_ID}\"}}],\"max_results\":100}" || true)"
	# Select only traces carrying the demo_seed tag, so real conversations are
	# never deleted. tags come back as a JSON object (a tag-name to value map).
	ids="$(printf '%s' "$search" | jq -c '[.traces[]? | select(.tags.demo_seed == "true") | .trace_id]' 2>/dev/null || echo '[]')"
	local count
	count="$(printf '%s' "$ids" | jq 'length' 2>/dev/null || echo 0)"
	if [ "$count" -eq 0 ]; then
		info "no seeded MLflow conversation was found to remove."
		return 0
	fi
	resp="$(curl -s --max-time 20 "${base_url}/mlflow/api/3.0/mlflow/traces/delete-traces" \
		-H 'Content-Type: application/json' \
		-d "{\"experiment_id\":\"${MLFLOW_EXPERIMENT_ID}\",\"request_ids\":${ids}}" || true)"
	local deleted
	deleted="$(printf '%s' "$resp" | jq -r '.traces_deleted // 0' 2>/dev/null || echo 0)"
	pass "removed ${deleted} seeded MLflow conversation trace(s); real traces left in place."
}

do_clear() {
	require_stack
	info "clearing seeded data on port ${edge_port} (marker git_org=${DEMO_ORG})"
	# Metrics: re-emit every seeded series as a counter reset (value 0) at a
	# timestamp just ahead of the seed, so every dashboard metric panel, all of
	# which read with last_over_time, returns 0 for the seeded series. Real series
	# carry a different git_org and are never touched.
	local now_s ts_ns row agent repo branch model sid cost_cents
	now_s="$(date +%s)"
	ts_ns="$(( (now_s + 2) * 1000000000 ))"
	for row in "${sessions[@]}"; do
		# shellcheck disable=SC2086
		set -- $row
		agent="$1"; repo="$2"; branch="$3"; model="$4"; sid="$5"; cost_cents="$6"
		seed_session_metrics "$agent" "$repo" "$branch" "$model" "$sid" "$cost_cents" "$ts_ns" "zero"
	done
	pass "reset every seeded metric series to zero; the dashboard metric panels now read empty for demo data."
	clear_mlflow
	# Logs and traces: this stack's stores provide no surgical delete (Mimir has
	# no delete API, Loki's is disabled here, Tempo has none), so the seeded,
	# marked log streams and traces remain until a full wipe.
	info "the seeded Loki log streams and Tempo traces carry git_org=${DEMO_ORG} and cannot be surgically deleted on this stack."
	info "to remove them, and all other stored telemetry, tear the stack down with 'docker compose down -v' (this also removes real data)."
}

# --- Run ---------------------------------------------------------------------
case "$mode" in
	seed) do_seed ;;
	clear) do_clear ;;
esac
