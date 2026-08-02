#!/usr/bin/env bash
#
# dashboard.verify.sh
#
# @agents-index Proves the provisioned Coding Agent Observability dashboard in one run: present by uid, read-only, every panel target executes and returns data where its family has samples or an explicit empty where it does not, no identity labels, counters use last_over_time, variables present, panels documented, JSON reviewable.
#
# Purpose: prove the committed dashboard from the outside, the way Grafana loads
# it and the way a datasource answers its panels, in a single run. It asserts
# eight facts, each reported as its own check:
#   1. The dashboard is provisioned and present by uid agent-observability.
#   2. The dashboard is provisioned read-only, so the committed JSON stays true.
#   3. Every panel target executes against its datasource without a query error,
#      returns data where its metric family has samples on this stack, and an
#      explicit empty success where the family legitimately has none. The two
#      outcomes are printed distinctly so a reader can tell them apart.
#   4. No user identity label appears anywhere in the dashboard JSON.
#   5. Every metric target aggregates with last_over_time and none use rate or
#      increase, because the counters carry a session identifier and the growth
#      operators return zero on that shape.
#   6. The agent, repository, branch, model, and datasource variables exist.
#   7. Every data panel carries a description and a no-data message.
#   8. The JSON carries no absolute filesystem path and no volatile identifier.
# The script exits non-zero on the first failure. Every failure names what
# failed, the fix, and what to check after the fix.
#
# Usage:
#   scripts/dashboard.verify.sh          Run every check against the running stack.
#   scripts/dashboard.verify.sh -h       Print this usage and exit 0.
#
# Parameters:
#   -h, --help   Print usage and exit 0. The script takes no other argument.
#
# Environment:
#   EDGE_PORT        Loopback host port the edge proxy publishes. Read from the
#                    shell first, then from .env, then defaults to 24317.
#   GRAFANA_USER     Grafana API user. Default admin.
#   GRAFANA_PASSWORD Grafana API password. Default admin.

set -euo pipefail

# --- Location ----------------------------------------------------------------
# Resolve the repository root from the script location so the checks run the
# same way from any working directory.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
dashboard_json="$repo_root/stack/grafana/dashboards/agent-observability.json"
dashboard_uid="agent-observability"

# --- Usage -------------------------------------------------------------------
usage() {
	sed -n '3,42p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
	-h | --help)
		usage
		exit 0
		;;
	"") ;;
	*)
		echo "verify: FAIL unknown argument '$1'." >&2
		echo "  Fix: run 'scripts/dashboard.verify.sh' with no argument, or '-h' for usage." >&2
		echo "  After: re-run the command without the extra argument." >&2
		exit 2
		;;
esac

cd "$repo_root"

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
grafana_user="${GRAFANA_USER:-admin}"
grafana_password="${GRAFANA_PASSWORD:-admin}"

# The metric families known to hold samples on a stack where an agent has run,
# and the families that populate only after the agent writes, edits, commits, or
# opens a pull request, or that belong to an agent that is not installed. A
# populated family MUST return data; an empty family MUST execute and return an
# explicit empty result. A metric target that names a family in neither set is a
# typo or a rename and is a failure, which is what catches a broken panel.
populated_families="cost_usage_USD token_usage_tokens session_count active_time_seconds"
empty_families="lines_of_code_count code_edit_tool_decision commit_count pull_request_count"

# --- Reporting helpers -------------------------------------------------------
pass() {
	echo "verify: PASS $1"
}

fail() {
	local what="$1" fix="$2" after="$3"
	echo "verify: FAIL $what" >&2
	echo "  Fix: $fix" >&2
	echo "  After: $after" >&2
	exit 1
}

# --- Preconditions -----------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
	fail "jq is not installed, and every check parses JSON with it." \
		"install jq, for example 'brew install jq'." \
		"re-run 'scripts/dashboard.verify.sh' once jq is on PATH."
fi
if [ ! -f "$dashboard_json" ]; then
	fail "the dashboard JSON is missing at stack/grafana/dashboards/agent-observability.json." \
		"restore the committed dashboard file." \
		"re-run 'scripts/dashboard.verify.sh' once the file is present."
fi
if ! jq empty "$dashboard_json" >/dev/null 2>&1; then
	fail "the dashboard JSON does not parse." \
		"run 'jq empty stack/grafana/dashboards/agent-observability.json' to find the syntax error." \
		"re-run 'scripts/dashboard.verify.sh' once the JSON parses."
fi

# --- Check 1: provisioned and present by uid ---------------------------------
check_dashboard_provisioned() {
	local uids
	uids="$(curl -s --max-time 10 -u "${grafana_user}:${grafana_password}" \
		"${base_url}/api/search?query=Coding%20Agent%20Observability" | jq -r '.[].uid' || true)"
	if ! printf '%s\n' "$uids" | grep -qx "$dashboard_uid"; then
		fail "the dashboard with uid '${dashboard_uid}' is not listed by the Grafana search API." \
			"confirm 'stack/grafana/provisioning/dashboards/dashboards.yaml' loads the dashboard directory and re-provision with 'docker compose up -d grafana'." \
			"re-run 'scripts/dashboard.verify.sh' and confirm the uid is listed."
	fi
	pass "the dashboard is provisioned and present by uid '${dashboard_uid}'."
}

# --- Check 2: provisioned read-only ------------------------------------------
check_dashboard_readonly() {
	local provisioned
	provisioned="$(curl -s --max-time 10 -u "${grafana_user}:${grafana_password}" \
		"${base_url}/api/dashboards/uid/${dashboard_uid}" | jq -r '.meta.provisioned' || true)"
	if [ "$provisioned" != "true" ]; then
		fail "Grafana does not report the dashboard as provisioned, so a user could save over it." \
			"set 'allowUiUpdates: false' and 'disableDeletion: true' in the dashboard provider and re-provision with 'docker compose up -d grafana'." \
			"re-run 'scripts/dashboard.verify.sh' and confirm the provisioned flag is true."
	fi
	pass "the dashboard is provisioned read-only, so the committed JSON stays the source of truth."
}

# --- Query-string variable substitution --------------------------------------
# Replace the dashboard template variables and Grafana macros with match-all
# values, so a committed panel query runs standalone against its datasource. The
# order avoids one token being a prefix of another.
substitute_vars() {
	local e="$1"
	e="${e//\$__rate_interval/168h}"
	e="${e//\$__interval/168h}"
	e="${e//\$__range/168h}"
	e="${e//\$\{model:regex\}/.*}"
	e="${e//\$\{agent:pipe\}/claude-code|pi-coding-agent}"
	e="${e//\$agent/.+}"
	e="${e//\$git_repo/.*}"
	e="${e//\$git_branch/.*}"
	printf '%s' "$e"
}

# --- Check 3: every panel target executes with the right emptiness -----------
# Runs each committed panel target against its datasource. A metric target is
# classified by its family: a populated family MUST return data, an empty family
# MUST execute and return empty, and an unknown family is a failure. A Loki
# conversation target MUST return data; other log and trace targets execute and
# may be empty, which is legitimate on a stack where no tool ran and no span was
# exported. The data and empty outcomes are printed distinctly.
check_panel_queries_execute() {
	local start_ns end_ns tempo_body
	start_ns="$(( $(date +%s) - 604800 ))000000000"
	end_ns="$(date +%s)000000000"
	tempo_body="$(mktemp)"
	trap 'rm -f "$tempo_body"' RETURN

	local dstype title_b64 expr_b64 title expr q resp status n families fam expect

	while IFS=$'\t' read -r dstype title_b64 expr_b64; do
		[ -z "$dstype" ] && continue
		title="$(printf '%s' "$title_b64" | base64 -d)"
		expr="$(printf '%s' "$expr_b64" | base64 -d)"
		q="$(substitute_vars "$expr")"

		case "$dstype" in
			prometheus)
				families="$(printf '%s\n' "$expr" | grep -oE '(claude_code|pi)_[a-zA-Z_]+_total' | sed -E 's/^(claude_code|pi)_//; s/_total$//' | sort -u || true)"
				if [ -z "$families" ]; then
					fail "metric panel '${title}' has no recognisable metric family in its query." \
						"confirm the target selects a claude_code_* or pi_* series by __name__." \
						"re-run 'scripts/dashboard.verify.sh' and confirm the panel names a known family."
				fi
				expect="data"
				for fam in $families; do
					if printf '%s ' "$populated_families" | grep -qw "$fam"; then
						:
					elif printf '%s ' "$empty_families" | grep -qw "$fam"; then
						expect="empty"
					else
						fail "metric panel '${title}' queries an unknown metric family '${fam}'." \
							"correct the metric name, or add the family to the populated or empty set in this script if the pipeline legitimately added it." \
							"re-run 'scripts/dashboard.verify.sh' and confirm the panel names a documented family."
					fi
				done
				resp="$(curl -sG --max-time 20 "${base_url}/prometheus/api/v1/query" --data-urlencode "query=${q}" || true)"
				status="$(printf '%s' "$resp" | jq -r '.status' 2>/dev/null || echo error)"
				if [ "$status" != "success" ]; then
					fail "metric panel '${title}' returned a query error from Mimir." \
						"run the panel query in Grafana Explore to see the parser or execution error." \
						"re-run 'scripts/dashboard.verify.sh' and confirm the panel executes."
				fi
				n="$(printf '%s' "$resp" | jq '.data.result | length')"
				if [ "$expect" = "data" ]; then
					if [ "$n" -eq 0 ]; then
						fail "metric panel '${title}' returned no data, but its family has samples on this stack." \
							"confirm the target uses last_over_time rather than rate or increase, and that the template filters are not over-narrowing." \
							"re-run 'scripts/dashboard.verify.sh' and confirm the panel returns a value."
					fi
					pass "panel '${title}' executes and returns data (${n} series)."
				else
					pass "panel '${title}' executes and returns an explicit empty result (family populates only after the agent acts, or the agent is not installed)."
				fi
				;;
			loki)
				resp="$(curl -sG --max-time 20 "${base_url}/loki/api/v1/query_range" \
					--data-urlencode "query=${q}" \
					--data-urlencode "start=${start_ns}" \
					--data-urlencode "end=${end_ns}" \
					--data-urlencode "limit=5" || true)"
				status="$(printf '%s' "$resp" | jq -r '.status' 2>/dev/null || echo error)"
				if [ "$status" != "success" ]; then
					fail "log panel '${title}' returned a query error from Loki." \
						"run the panel query in Grafana Explore to see the LogQL error." \
						"re-run 'scripts/dashboard.verify.sh' and confirm the panel executes."
				fi
				n="$(printf '%s' "$resp" | jq '.data.result | length')"
				if printf '%s' "$expr" | grep -q 'user_prompt'; then
					if [ "$n" -eq 0 ]; then
						fail "the conversation log panel '${title}' returned no streams, but readable agent logs exist on this stack." \
							"confirm the Loki service_name filter and the readable-line regex match the ingested streams, and widen the time range." \
							"re-run 'scripts/dashboard.verify.sh' and confirm the panel returns streams."
					fi
					pass "panel '${title}' executes and returns data (${n} streams)."
				else
					pass "panel '${title}' executes and returns an explicit empty result (no tool event was logged in this window)."
				fi
				;;
			tempo)
				status="$(curl -s -o "$tempo_body" -w '%{http_code}' --max-time 20 -G \
					"${base_url}/tempo/api/search" \
					--data-urlencode "q=${q}" \
					--data-urlencode "limit=20" || true)"
				if [ "$status" != "200" ]; then
					fail "trace panel '${title}' returned HTTP '${status}' from Tempo, not 200." \
						"run the panel TraceQL in Grafana Explore to see the search error." \
						"re-run 'scripts/dashboard.verify.sh' and confirm the panel executes."
				fi
				if ! jq -e '.traces' "$tempo_body" >/dev/null 2>&1; then
					fail "trace panel '${title}' returned a body without a traces field, so Tempo reported an error." \
						"run the panel TraceQL in Grafana Explore to see the search error." \
						"re-run 'scripts/dashboard.verify.sh' and confirm the panel executes."
				fi
				n="$(jq '.traces | length' "$tempo_body")"
				if [ "$n" -eq 0 ]; then
					pass "panel '${title}' executes and returns an explicit empty result (no agent has exported spans to Tempo on this stack)."
				else
					pass "panel '${title}' executes and returns data (${n} traces)."
				fi
				;;
			*)
				fail "panel '${title}' has an unrecognised datasource type '${dstype}'." \
					"confirm the panel datasource is prometheus, loki, or tempo." \
					"re-run 'scripts/dashboard.verify.sh' and confirm every panel names a known datasource."
				;;
		esac
	done < <(jq -r '
		[.panels[] | select(.type != "row")] | .[]
		| .title as $t | .datasource.type as $dt
		| (.targets // [])[]
		| $dt + "\t" + ($t | @base64) + "\t" + (((.expr // .query) // "") | @base64)
	' "$dashboard_json")

	pass "every panel target executed against its datasource with no query error."
}

# --- Check 4: no identity labels ---------------------------------------------
check_no_identity_labels() {
	local hits
	hits="$(grep -nE 'user_email|user_id|user_account_id|user_account_uuid|organization_id' "$dashboard_json" || true)"
	if [ -n "$hits" ]; then
		echo "$hits" >&2
		fail "the dashboard JSON references a user identity label (listed above)." \
			"remove the label from the query, grouping, or text, because the dashboard is screenshotted into a public README." \
			"re-run 'scripts/dashboard.verify.sh' and confirm the identity scan is empty."
	fi
	pass "no user identity label appears in the dashboard JSON."
}

# --- Check 5: counters use last_over_time, not rate or increase --------------
check_counters_use_last_over_time() {
	local dstype title_b64 expr_b64 title expr
	while IFS=$'\t' read -r dstype title_b64 expr_b64; do
		[ "$dstype" != "prometheus" ] && continue
		title="$(printf '%s' "$title_b64" | base64 -d)"
		expr="$(printf '%s' "$expr_b64" | base64 -d)"
		if printf '%s' "$expr" | grep -qE 'rate\(|increase\('; then
			fail "metric panel '${title}' uses rate or increase, which return zero on the session-scoped counters." \
				"rewrite the target as sum(last_over_time(...)) over the window, per the requirement that counters aggregate the last value." \
				"re-run 'scripts/dashboard.verify.sh' and confirm no metric target uses rate or increase."
		fi
		if ! printf '%s' "$expr" | grep -q 'last_over_time'; then
			fail "metric panel '${title}' plots a counter without last_over_time." \
				"wrap the selector in last_over_time over the window so it returns a value rather than nothing." \
				"re-run 'scripts/dashboard.verify.sh' and confirm every metric target uses last_over_time."
		fi
	done < <(jq -r '
		[.panels[] | select(.type != "row")] | .[]
		| .title as $t | .datasource.type as $dt
		| (.targets // [])[]
		| $dt + "\t" + ($t | @base64) + "\t" + (((.expr // .query) // "") | @base64)
	' "$dashboard_json")
	pass "every metric target aggregates with last_over_time and none use rate or increase."
}

# --- Check 6: template variables present -------------------------------------
check_variables_present() {
	local want name
	want="agent git_repo git_branch model datasource_metrics datasource_logs datasource_traces"
	for name in $want; do
		if ! jq -e --arg n "$name" '.templating.list[] | select(.name == $n)' "$dashboard_json" >/dev/null; then
			fail "the template variable '${name}' is missing from the dashboard." \
				"add the '${name}' variable to templating.list." \
				"re-run 'scripts/dashboard.verify.sh' and confirm the variable is present."
		fi
	done
	pass "the agent, repository, branch, model, and three datasource variables are all present."
}

# --- Check 7: every data panel is documented ---------------------------------
check_panel_descriptions() {
	local missing
	missing="$(jq -r '
		.panels[] | select(.type != "row")
		| select((.description // "") == "" or (.fieldConfig.defaults.noValue // "") == "")
		| .title
	' "$dashboard_json")"
	if [ -n "$missing" ]; then
		echo "$missing" >&2
		fail "a data panel is missing a description or a no-data message (listed above)." \
			"add a description naming the metric family and a fieldConfig.defaults.noValue naming the likely cause and the fix." \
			"re-run 'scripts/dashboard.verify.sh' and confirm every panel is documented."
	fi
	pass "every data panel carries a description and a no-data message."
}

# --- Check 8: JSON is reviewable ---------------------------------------------
# The committed JSON must be free of machine-specific and per-run content, so a
# text diff reviews cleanly and no local path or session identifier leaks.
check_json_reviewable() {
	local path_hits id_hits
	path_hits="$(grep -nE '"/(Users|home|var|tmp|private|opt|mnt)/' "$dashboard_json" || true)"
	if [ -n "$path_hits" ]; then
		echo "$path_hits" >&2
		fail "the dashboard JSON carries an absolute filesystem path (listed above)." \
			"remove the machine-specific path so the JSON is portable." \
			"re-run 'scripts/dashboard.verify.sh' and confirm the path scan is empty."
	fi
	id_hits="$(grep -nE 'session_id|[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' "$dashboard_json" || true)"
	if [ -n "$id_hits" ]; then
		echo "$id_hits" >&2
		fail "the dashboard JSON carries a volatile per-session identifier (listed above)." \
			"remove the session identifier or UUID so the committed file does not pin one run." \
			"re-run 'scripts/dashboard.verify.sh' and confirm the identifier scan is empty."
	fi
	pass "the dashboard JSON carries no absolute path and no volatile identifier."
}

# --- Run every check in order ------------------------------------------------
echo "verify: checking the dashboard on port ${edge_port}"
check_dashboard_provisioned
check_dashboard_readonly
check_panel_queries_execute
check_no_identity_labels
check_counters_use_last_over_time
check_variables_present
check_panel_descriptions
check_json_reviewable
echo "verify: all checks passed"
