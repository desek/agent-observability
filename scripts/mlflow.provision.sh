#!/usr/bin/env bash
#
# mlflow.provision.sh
#
# @agents-index Idempotent MLflow experiment provisioner that creates the claude-code and pi experiments through the tracking REST interface, never overwriting an existing one, and never blocking stack startup.
#
# Purpose: give a user who opens MLflow immediately after starting the stack a
# named experiment for each coding agent instead of a blank page. It creates two
# experiments if they are absent, one for Claude Code conversations and one
# reserved for pi, by calling the tracking server's own REST interface over the
# network. It never touches the backend database directly, never modifies or
# replaces an experiment that already exists, and is safe to run any number of
# times: a second run reports the same identifiers and changes nothing.
#
# The stack runs this once MLflow reports healthy, as a one-shot compose service
# (see compose.yaml, service `mlflow-provision`) on which nothing depends. That
# is what makes it non-blocking: because no other service and no health gate
# waits for this container, a failure here leaves every real service running and
# `docker compose up -d` still succeeds. The failure is reported to the container
# log, where `docker compose logs mlflow-provision` surfaces it, and to this
# script's non-zero exit.
#
# Transport is chosen at runtime so the same script runs on the host (where curl
# and jq are present) and inside the pinned mlflow image (where only bash and
# python3 are present): it prefers curl, then python3, for HTTP, and jq, then
# python3, for JSON. Every request carries `Host: localhost` because MLflow's
# default host-validation middleware rejects the compose service name.
#
# Usage:
#   scripts/mlflow.provision.sh        Ensure both agent experiments exist.
#   scripts/mlflow.provision.sh -h     Print this usage and exit 0.
#
# Parameters:
#   -h, --help  Print usage and exit 0.
#
# Environment:
#   MLFLOW_PROVISION_URL  Full MLflow base URL including the /mlflow prefix, for
#                         example http://mlflow:5000/mlflow. The compose service
#                         sets this to the internal service address, where the
#                         published edge port is not the reachable surface. When
#                         unset, the address is derived from EDGE_PORT.
#   EDGE_PORT             Loopback host port the edge proxy publishes. Read from
#                         the shell first, then from .env, then defaults to
#                         24317. Used only when MLFLOW_PROVISION_URL is unset, so
#                         the port is never hard-coded.

set -euo pipefail

# --- Location ----------------------------------------------------------------
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

# --- Usage -------------------------------------------------------------------
usage() {
	sed -n '3,46p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
	-h | --help)
		usage
		exit 0
		;;
	"") ;;
	*)
		echo "provision: FAIL unexpected argument '$1'." >&2
		echo "  Fix: run this script with no arguments, or with -h for usage." >&2
		echo "  After: re-run 'scripts/mlflow.provision.sh' and confirm it ensures both experiments." >&2
		exit 2
		;;
esac

# The experiments this stack provisions. claude-code holds Claude Code
# conversation traces; pi is reserved so a pi run has a named home once its
# integration exists (that integration is out of scope here).
experiments=(claude-code pi)

# Connectivity retry budget: the compose service starts only after MLflow is
# healthy, so the server should answer at once, but a short retry absorbs the
# gap between the health gate and the REST surface accepting requests.
readonly HTTP_TIMEOUT=10
readonly WAIT_RETRIES=15
readonly WAIT_SLEEP=2

# --- Address resolution ------------------------------------------------------
# An explicit MLFLOW_PROVISION_URL wins (the compose service passes the internal
# service address). Otherwise derive the address from EDGE_PORT the same way the
# rest of the stack does: shell, then .env, then the default, so changing the
# published port does not silently break provisioning and no port is literal.
resolve_edge_port() {
	local port="${EDGE_PORT:-}"
	if [ -z "$port" ] && [ -f "$repo_root/.env" ]; then
		port="$(grep -E '^[[:space:]]*EDGE_PORT[[:space:]]*=' "$repo_root/.env" | tail -n1 | cut -d= -f2 | tr -d '[:space:]')"
	fi
	printf '%s' "${port:-24317}"
}

if [ -n "${MLFLOW_PROVISION_URL:-}" ]; then
	mlflow_url="${MLFLOW_PROVISION_URL%/}"
else
	mlflow_url="http://127.0.0.1:$(resolve_edge_port)/mlflow"
fi

# --- Transport selection -----------------------------------------------------
# Choose an HTTP client and a JSON reader from what the runtime provides.
if command -v curl >/dev/null 2>&1; then
	http_tool=curl
elif command -v python3 >/dev/null 2>&1; then
	http_tool=python3
else
	echo "provision: FAIL no HTTP client is available (need curl or python3)." >&2
	echo "  Fix: run this inside the pinned mlflow image, which ships python3, or on a host with curl installed." >&2
	echo "  After: re-run 'scripts/mlflow.provision.sh' and confirm it reaches ${mlflow_url}/health." >&2
	exit 1
fi

if command -v jq >/dev/null 2>&1; then
	json_tool=jq
elif command -v python3 >/dev/null 2>&1; then
	json_tool=python3
else
	echo "provision: FAIL no JSON reader is available (need jq or python3)." >&2
	echo "  Fix: run this inside the pinned mlflow image, which ships python3, or install jq on the host." >&2
	echo "  After: re-run 'scripts/mlflow.provision.sh' and confirm it reports each experiment identifier." >&2
	exit 1
fi

# --- HTTP --------------------------------------------------------------------
# http_call METHOD PATH [BODY]
# Emits the response body on stdout. Returns 0 whenever the server answered,
# including 4xx (MLflow returns a JSON error body there, which the caller reads),
# and non-zero only when the server could not be reached. Every request carries
# Host: localhost so MLflow's host-validation middleware accepts it.
http_call() {
	local method="$1" path="$2" body="${3:-}"
	local url="${mlflow_url}/${path}"
	case "$http_tool" in
		curl)
			if [ "$method" = GET ]; then
				curl -sS --max-time "$HTTP_TIMEOUT" -H 'Host: localhost' "$url"
			else
				curl -sS --max-time "$HTTP_TIMEOUT" \
					-H 'Host: localhost' -H 'Content-Type: application/json' \
					-X POST -d "$body" "$url"
			fi
			;;
		python3)
			# The env var carrying the timeout must not be named HTTP_TIMEOUT:
			# that global is readonly, and a command-prefix assignment to a
			# readonly name fails, so python would never receive it.
			REQ_METHOD="$method" REQ_URL="$url" REQ_BODY="$body" REQ_TIMEOUT="$HTTP_TIMEOUT" \
				python3 - <<'PY'
import os, sys, urllib.request, urllib.error
method = os.environ["REQ_METHOD"]
url = os.environ["REQ_URL"]
body = os.environ.get("REQ_BODY", "")
timeout = float(os.environ["REQ_TIMEOUT"])
headers = {"Host": "localhost"}
data = None
if method != "GET":
    data = body.encode()
    headers["Content-Type"] = "application/json"
req = urllib.request.Request(url, data=data, headers=headers, method=method)
try:
    with urllib.request.urlopen(req, timeout=timeout) as r:
        sys.stdout.write(r.read().decode())
except urllib.error.HTTPError as e:
    # The server answered with a 4xx/5xx and a JSON error body; hand it back.
    sys.stdout.write(e.read().decode())
except Exception as e:  # connection refused, DNS failure, timeout
    sys.stderr.write(str(e) + "\n")
    sys.exit(1)
PY
			;;
	esac
}

# --- JSON --------------------------------------------------------------------
# json_field JSON id     -> the experiment_id from either the get-by-name shape
#                           ({"experiment":{"experiment_id":...}}) or the create
#                           shape ({"experiment_id":...}); empty when absent.
# json_field JSON error  -> the error_code; empty when absent.
json_field() {
	local json="$1" which="$2"
	case "$json_tool" in
		jq)
			if [ "$which" = id ]; then
				printf '%s' "$json" | jq -r '.experiment.experiment_id // .experiment_id // empty'
			else
				printf '%s' "$json" | jq -r '.error_code // empty'
			fi
			;;
		python3)
			JSON_INPUT="$json" JSON_WHICH="$which" python3 - <<'PY'
import os, json
try:
    d = json.loads(os.environ.get("JSON_INPUT") or "{}")
except ValueError:
    d = {}
which = os.environ["JSON_WHICH"]
if which == "id":
    exp = d.get("experiment") or {}
    print(exp.get("experiment_id") or d.get("experiment_id") or "")
else:
    print(d.get("error_code") or "")
PY
			;;
	esac
}

# --- Reachability ------------------------------------------------------------
# Block until the tracking REST surface answers or the retry budget is spent.
wait_for_server() {
	local attempt=1
	while [ "$attempt" -le "$WAIT_RETRIES" ]; do
		if http_call GET health >/dev/null 2>&1; then
			return 0
		fi
		echo "provision: waiting for MLflow at ${mlflow_url} (attempt ${attempt}/${WAIT_RETRIES})"
		sleep "$WAIT_SLEEP"
		attempt=$((attempt + 1))
	done
	return 1
}

# --- Ensure one experiment ---------------------------------------------------
# ensure_experiment NAME
# Returns 0 when the experiment exists after the call (whether it was already
# present or was created), 2 when the server could not be reached, and 3 when the
# server answered but in an unexpected way.
ensure_experiment() {
	local name="$1" resp id err cresp cid cerr
	if ! resp="$(http_call GET "api/2.0/mlflow/experiments/get-by-name?experiment_name=${name}")"; then
		return 2
	fi

	id="$(json_field "$resp" id)"
	if [ -n "$id" ]; then
		echo "provision: experiment '${name}' already exists (id ${id}); left unchanged."
		return 0
	fi

	err="$(json_field "$resp" error)"
	if [ "$err" != "RESOURCE_DOES_NOT_EXIST" ]; then
		echo "provision: unexpected response resolving '${name}': ${resp}" >&2
		return 3
	fi

	if ! cresp="$(http_call POST "api/2.0/mlflow/experiments/create" "{\"name\":\"${name}\"}")"; then
		return 2
	fi
	cid="$(json_field "$cresp" id)"
	if [ -n "$cid" ]; then
		echo "provision: experiment '${name}' created (id ${cid})."
		return 0
	fi

	# A concurrent create is not a failure: the experiment exists, which is the
	# goal, so treat RESOURCE_ALREADY_EXISTS as success.
	cerr="$(json_field "$cresp" error)"
	if [ "$cerr" = "RESOURCE_ALREADY_EXISTS" ]; then
		echo "provision: experiment '${name}' created concurrently; left unchanged."
		return 0
	fi

	echo "provision: unexpected response creating '${name}': ${cresp}" >&2
	return 3
}

# --- Run ---------------------------------------------------------------------
echo "provision: ensuring experiments [${experiments[*]}] at ${mlflow_url}"

if ! wait_for_server; then
	echo "provision: FAIL MLflow did not answer at ${mlflow_url} within $((WAIT_RETRIES * WAIT_SLEEP))s." >&2
	echo "  Fix: confirm the mlflow service is healthy with 'docker compose ps mlflow', or set MLFLOW_PROVISION_URL to the tracking address including the /mlflow prefix." >&2
	echo "  After: re-run 'scripts/mlflow.provision.sh' and confirm it reports an identifier for each experiment." >&2
	exit 1
fi

failed=0
for name in "${experiments[@]}"; do
	if ! ensure_experiment "$name"; then
		failed=1
		echo "provision: could not ensure experiment '${name}'." >&2
	fi
done

if [ "$failed" -ne 0 ]; then
	echo "provision: FAIL one or more experiments could not be ensured at ${mlflow_url}." >&2
	echo "  Fix: read the response above, confirm the tracking server is healthy with 'docker compose logs mlflow', then re-run this script. Because nothing depends on this step, the rest of the stack keeps running while you fix it." >&2
	echo "  After: run the experiments/search REST call and confirm both '${experiments[*]}' are listed." >&2
	exit 1
fi

echo "provision: PASS all experiments [${experiments[*]}] exist at ${mlflow_url}"
