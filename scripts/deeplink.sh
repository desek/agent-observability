#!/usr/bin/env bash
#
# deeplink.sh
#
# @agents-index Builds the four Grafana deep-link kinds (dashboard, metrics, logs, trace) for the local stack, host and port derived from EDGE_PORT, with a self-check that asserts each link resolves to its intended view.
#
# Purpose: give an agent one place to build a Grafana link a user can click, so
# a link is never hand-assembled and its format lives in a single verified
# script. It builds four kinds:
#   dashboard  the provisioned dashboard, with template variables and a time
#              range pre-selected.
#   metrics    an Explore view for a PromQL query against Mimir.
#   logs       an Explore view for a LogQL selector against Loki.
#   trace      an Explore view for a trace identifier against Tempo.
#
# The link formats are not written from memory. They are exactly what the
# Grafana MCP server's own generate_deeplink tool (navigation category) produces,
# rehosted onto the stack's single edge port, and each was opened in a browser
# against the running Grafana and confirmed to resolve to the intended view.
#
#   Grafana version verified against: 13.1.1
#   MCP server that produced the formats: grafana/mcp-grafana:1.0.0
#
# Verified formats (BASE is http://localhost:<EDGE_PORT>):
#   dashboard  BASE/d/<uid>?from=<from>&to=<to>&var-<name>=<value>...
#              uid is the provisioned dashboard "agent-observability".
#              Grafana normalises the URL to add the dashboard slug and the
#              remaining variables at their defaults; the supplied variables and
#              range are applied.
#   explore    BASE/explore?left=<url-encoded compact JSON>, where the JSON is
#              {"datasource":"<uid>","queries":[<query>],"range":{"from":"<from>","to":"<to>"}}
#              Grafana 13.1.1 migrates the legacy left= parameter into its
#              current panes=+schemaVersion=1 form, preserving datasource, query,
#              and range. The per-kind query object is:
#                metrics  {"expr":"<promql>","refId":"A"}          datasource uid mimir
#                logs     {"expr":"<logql>","refId":"A"}           datasource uid loki
#                trace    {"query":"<traceid>","queryType":"traceql","refId":"A"} datasource uid tempo
#
# Usage:
#   scripts/deeplink.sh dashboard [--from <t>] [--to <t>] [--var name=value ...]
#   scripts/deeplink.sh metrics <promql>  [--from <t>] [--to <t>]
#   scripts/deeplink.sh logs    <logql>   [--from <t>] [--to <t>]
#   scripts/deeplink.sh trace   <traceid> [--from <t>] [--to <t>]
#   scripts/deeplink.sh --self-check   Assert every kind resolves to its view.
#   scripts/deeplink.sh -h             Print this usage and exit 0.
#
# Each build subcommand prints one URL to stdout and nothing else, so the output
# is safe to hand straight to a user or embed in a message. --from and --to
# accept any Grafana time expression (for example now-6h, now, or a millisecond
# epoch). They default to now-6h..now for dashboard and now-1h..now for explore.
#
# Parameters:
#   dashboard --var name=value   Repeatable. Sets a dashboard template variable,
#                                for example --var agent=claude-code. Pass the
#                                Grafana all-token as --var model='$__all'.
#
# Environment:
#   EDGE_PORT        Loopback host port the edge proxy publishes. Read from the
#                    shell first, then from .env, then defaults to 24317. The
#                    link host and port are derived from it, never hard-coded.
#   GRAFANA_USER     Grafana user the self-check authenticates as. Default admin.
#   GRAFANA_PASSWORD Grafana password for the self-check. Default admin.
#
# Exit status: 0 on success. Non-zero on a bad argument or a failed self-check
# assertion; every failure names what failed, the fix, and what to check after.

set -euo pipefail

# --- Location ----------------------------------------------------------------
# Resolve the repository root from the script location so it runs the same way
# from any working directory.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

# The uid of the provisioned dashboard the dashboard link opens. It is stable by
# provisioning, which is what makes a dashboard link durable.
readonly DASHBOARD_UID="agent-observability"

# --- Usage -------------------------------------------------------------------
usage() {
	sed -n '3,70p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# --- Reporting helpers -------------------------------------------------------
# fail prints the three-part actionable message (what failed, the fix, what to
# check after) to stderr and exits non-zero.
fail() {
	local what="$1" fix="$2" after="$3"
	echo "deeplink: FAIL $what" >&2
	echo "  Fix: $fix" >&2
	echo "  After: $after" >&2
	exit 1
}

# --- Port resolution ---------------------------------------------------------
# The shell environment wins, then .env, then the default. This matches how
# docker compose and scripts/stack.verify.sh resolve EDGE_PORT, so the script
# and the stack never disagree. Only the EDGE_PORT line is read from .env.
resolve_edge_port() {
	local port="${EDGE_PORT:-}"
	if [ -z "$port" ] && [ -f "$repo_root/.env" ]; then
		port="$(grep -E '^[[:space:]]*EDGE_PORT[[:space:]]*=' "$repo_root/.env" | tail -n1 | cut -d= -f2 | tr -d '[:space:]')"
	fi
	printf '%s' "${port:-24317}"
}

edge_port="$(resolve_edge_port)"
base_url="http://localhost:${edge_port}"
grafana_user="${GRAFANA_USER:-admin}"
grafana_password="${GRAFANA_PASSWORD:-admin}"

# --- URL builders ------------------------------------------------------------
# build_explore_url emits an Explore deep link. Python does the JSON assembly
# and URL-encoding so an arbitrary PromQL, LogQL, or trace value is quoted
# correctly rather than by a fragile shell escape. It is present in this repo's
# script toolchain already (see scripts/mlflow.provision.sh).
#   $1 kind: metrics, logs, or trace
#   $2 datasource uid
#   $3 the query value (PromQL, LogQL, or a trace id)
#   $4 from   $5 to
build_explore_url() {
	local kind="$1" ds="$2" value="$3" from="$4" to="$5" left
	left="$(python3 - "$kind" "$ds" "$value" "$from" "$to" <<'PY'
import json, sys, urllib.parse
kind, ds, value, frm, to = sys.argv[1:6]
if kind == "trace":
    query = {"query": value, "queryType": "traceql", "refId": "A"}
else:  # metrics and logs both carry the query in expr
    query = {"expr": value, "refId": "A"}
state = {"datasource": ds, "queries": [query], "range": {"from": frm, "to": to}}
sys.stdout.write(urllib.parse.quote(json.dumps(state, separators=(",", ":")), safe=""))
PY
)"
	printf '%s/explore?left=%s\n' "$base_url" "$left"
}

# build_dashboard_url emits the provisioned-dashboard deep link with its time
# range and any template variables. Variable values are URL-encoded by python so
# the Grafana all-token $__all and any special character survive.
#   $1 from   $2 to   $3.. zero or more name=value template-variable pairs
build_dashboard_url() {
	local from="$1" to="$2"
	shift 2
	local query
	query="$(python3 - "$from" "$to" "$@" <<'PY'
import sys, urllib.parse
frm, to = sys.argv[1:3]
parts = ["from=" + urllib.parse.quote(frm, safe=""), "to=" + urllib.parse.quote(to, safe="")]
for pair in sys.argv[3:]:
    if "=" not in pair:
        sys.stderr.write("bad --var value (expected name=value): %s\n" % pair)
        sys.exit(3)
    name, _, val = pair.partition("=")
    parts.append("var-" + urllib.parse.quote(name, safe="") + "=" + urllib.parse.quote(val, safe=""))
sys.stdout.write("&".join(parts))
PY
)" || fail "a --var value is not in name=value form." \
		"pass each template variable as --var name=value, for example --var agent=claude-code." \
		"re-run the command with every --var written as name=value."
	printf '%s/d/%s?%s\n' "$base_url" "$DASHBOARD_UID" "$query"
}

# --- Argument parsing for a build subcommand ---------------------------------
# parse_time_and_vars reads --from, --to, and (for dashboard) --var pairs from a
# subcommand's arguments, leaving the positional query value for the caller. It
# sets the globals opt_from, opt_to, and the array opt_vars.
opt_from=""
opt_to=""
opt_vars=()
positional=()
parse_options() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--from)
				[ "$#" -ge 2 ] || fail "--from needs a time value." \
					"pass a Grafana time expression, for example --from now-6h." \
					"re-run with a value after --from."
				opt_from="$2"
				shift 2
				;;
			--to)
				[ "$#" -ge 2 ] || fail "--to needs a time value." \
					"pass a Grafana time expression, for example --to now." \
					"re-run with a value after --to."
				opt_to="$2"
				shift 2
				;;
			--var)
				[ "$#" -ge 2 ] || fail "--var needs a name=value pair." \
					"pass a template variable, for example --var agent=claude-code." \
					"re-run with a name=value after --var."
				opt_vars+=("$2")
				shift 2
				;;
			--)
				shift
				while [ "$#" -gt 0 ]; do positional+=("$1"); shift; done
				;;
			-*)
				fail "unknown option '$1'." \
					"run 'scripts/deeplink.sh -h' to see the accepted options." \
					"re-run without the unknown option."
				;;
			*)
				positional+=("$1")
				shift
				;;
		esac
	done
}

# --- Self-check --------------------------------------------------------------
# The self-check asserts every link kind resolves to its intended view, using
# only the shell so scripts/mcp.verify.sh and the phase-5 verification can drive
# it. Per kind it asserts three things: the link carries the configured port
# (proving it is not a hard-coded literal); the resource the link targets exists
# and is of the intended type (the dashboard uid, or the datasource of the right
# type); and the rendered page answers 200 when authenticated. Together these
# prove the link opens the intended view rather than an error page.
pass_line() { echo "deeplink: PASS $1"; }

http_status_auth() {
	curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
		-u "${grafana_user}:${grafana_password}" "$1" || true
}

assert_carries_port() {
	local url="$1" kind="$2"
	case "$url" in
		"http://localhost:${edge_port}/"*) ;;
		*)
			fail "the ${kind} link does not carry the configured port ${edge_port}." \
				"the link host must be derived from EDGE_PORT; confirm EDGE_PORT and .env, then re-run." \
				"re-run 'scripts/deeplink.sh --self-check' and confirm the ${kind} link contains ':${edge_port}/'."
			;;
	esac
}

assert_datasource() {
	local uid="$1" want_type="$2" body code
	code="$(http_status_auth "${base_url}/api/datasources/uid/${uid}")"
	if [ "$code" != "200" ]; then
		fail "the '${uid}' datasource does not resolve in Grafana (status ${code})." \
			"start the stack with 'scripts/stack.up.sh' and confirm '${uid}' is provisioned in stack/grafana/provisioning/datasources/datasources.yaml." \
			"re-run 'scripts/deeplink.sh --self-check' and confirm the '${uid}' datasource resolves."
	fi
	body="$(curl -s --max-time 10 -u "${grafana_user}:${grafana_password}" "${base_url}/api/datasources/uid/${uid}" || true)"
	if ! printf '%s' "$body" | grep -q "\"type\":\"${want_type}\""; then
		fail "the '${uid}' datasource is not of the expected type '${want_type}'." \
			"confirm datasources.yaml types uid '${uid}' as '${want_type}'." \
			"re-run 'scripts/deeplink.sh --self-check' and confirm the '${uid}' type is '${want_type}'."
	fi
}

assert_page_resolves() {
	local url="$1" kind="$2" code
	code="$(http_status_auth "$url")"
	if [ "$code" != "200" ]; then
		fail "the ${kind} link did not resolve to a page (status ${code}) through port ${edge_port}." \
			"confirm the stack is running with 'scripts/stack.verify.sh' and that GRAFANA_USER and GRAFANA_PASSWORD are correct (default admin and admin)." \
			"re-run 'scripts/deeplink.sh --self-check' and confirm the ${kind} link returns 200."
	fi
}

self_check() {
	local url code

	# Dashboard: the provisioned dashboard uid must resolve, and the link must
	# carry the range and a variable.
	# $__all is Grafana's literal all-token, passed through unexpanded on purpose.
	# shellcheck disable=SC2016
	url="$(build_dashboard_url now-6h now agent=claude-code 'model=$__all')"
	assert_carries_port "$url" dashboard
	case "$url" in
		*"/d/${DASHBOARD_UID}?"*"var-agent=claude-code"*) ;;
		*) fail "the dashboard link is missing its uid or a variable." \
			"confirm DASHBOARD_UID is '${DASHBOARD_UID}' and the builder emits var- parameters." \
			"re-run 'scripts/deeplink.sh --self-check' and inspect the dashboard link." ;;
	esac
	code="$(http_status_auth "${base_url}/api/dashboards/uid/${DASHBOARD_UID}")"
	if [ "$code" != "200" ]; then
		fail "the provisioned dashboard '${DASHBOARD_UID}' does not resolve (status ${code})." \
			"start the stack with 'scripts/stack.up.sh' and confirm the dashboard is provisioned." \
			"re-run 'scripts/deeplink.sh --self-check' and confirm the dashboard resolves."
	fi
	assert_page_resolves "$url" dashboard
	pass_line "dashboard link resolves to the provisioned dashboard with its variables and range."

	# Metrics: Mimir datasource of type prometheus, Explore page resolves.
	url="$(build_explore_url metrics mimir 'sum(rate(gen_ai_client_token_usage_tokens_sum[5m]))' now-1h now)"
	assert_carries_port "$url" metrics
	assert_datasource mimir prometheus
	assert_page_resolves "$url" metrics
	pass_line "metrics link resolves to an Explore view against the mimir datasource."

	# Logs: Loki datasource of type loki, Explore page resolves.
	url="$(build_explore_url logs loki '{service_name="claude-code"}' now-1h now)"
	assert_carries_port "$url" logs
	assert_datasource loki loki
	assert_page_resolves "$url" logs
	pass_line "logs link resolves to an Explore view against the loki datasource."

	# Trace: Tempo datasource of type tempo, Explore page resolves.
	url="$(build_explore_url trace tempo 0123456789abcdef0123456789abcdef now-1h now)"
	assert_carries_port "$url" trace
	assert_datasource tempo tempo
	assert_page_resolves "$url" trace
	pass_line "trace link resolves to an Explore view against the tempo datasource."

	echo "deeplink: self-check PASS (all four link kinds resolve to their intended view on port ${edge_port})"
}

# --- Dispatch ----------------------------------------------------------------
subcommand="${1:-}"
case "$subcommand" in
	-h | --help)
		usage
		exit 0
		;;
	--self-check)
		[ "$#" -eq 1 ] || fail "--self-check takes no other argument." \
			"run 'scripts/deeplink.sh --self-check' on its own." \
			"re-run without the extra argument."
		self_check
		;;
	dashboard)
		shift
		parse_options "$@"
		[ "${#positional[@]}" -eq 0 ] || fail "dashboard takes no positional argument (got '${positional[0]}')." \
			"set variables with --var name=value and the range with --from and --to." \
			"re-run 'scripts/deeplink.sh dashboard --var agent=claude-code'."
		build_dashboard_url "${opt_from:-now-6h}" "${opt_to:-now}" "${opt_vars[@]}"
		;;
	metrics | logs | trace)
		shift
		parse_options "$@"
		if [ "${#positional[@]}" -ne 1 ]; then
			label="a PromQL query"
			[ "$subcommand" = logs ] && label="a LogQL selector"
			[ "$subcommand" = trace ] && label="a trace identifier"
			fail "${subcommand} needs exactly one positional value (${label})." \
				"pass the value in quotes, for example scripts/deeplink.sh ${subcommand} '<value>'." \
				"re-run 'scripts/deeplink.sh ${subcommand} <value>' with a single quoted value."
		fi
		case "$subcommand" in
			metrics) build_explore_url metrics mimir "${positional[0]}" "${opt_from:-now-1h}" "${opt_to:-now}" ;;
			logs) build_explore_url logs loki "${positional[0]}" "${opt_from:-now-1h}" "${opt_to:-now}" ;;
			trace) build_explore_url trace tempo "${positional[0]}" "${opt_from:-now-1h}" "${opt_to:-now}" ;;
		esac
		;;
	"")
		usage >&2
		fail "no subcommand given." \
			"run one of dashboard, metrics, logs, trace, or --self-check; see the usage above." \
			"re-run with a subcommand, or '-h' for the full usage."
		;;
	*)
		fail "unknown subcommand '${subcommand}'." \
			"run one of dashboard, metrics, logs, trace, or --self-check." \
			"re-run 'scripts/deeplink.sh -h' to see the accepted subcommands."
		;;
esac
