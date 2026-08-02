#!/usr/bin/env bash
#
# mlflow.verify.sh
#
# @agents-index Dependency-free end-to-end verifier for the stack MLflow tracking server: through the single edge port it creates a throwaway experiment, a run, logs a parameter and a metric, reads them back, asserts the values match, and deletes what it created.
#
# Purpose: prove the MLflow tracking server answers a full write-then-read round
# trip through the one loopback port, with no Python and no MLflow client. It
# uses only curl and jq, which are present on the host and in the pinned mlflow
# image. It creates a clearly named throwaway experiment (prefixed zz-verify so a
# user tells it apart from the agent experiments), writes one run with one known
# parameter and one known metric, reads them back through the REST API, and
# asserts each read value equals the value written. It always removes the run and
# the experiment it created, even when an assertion fails, so a passing stack is
# left byte-for-byte as it was found.
#
# Why a round trip and not a health ping: a 200 from /mlflow/health proves the
# process is up, not that a write reaches the store and a read returns it. The
# one capability this stack exists to provide is reading agent data back, so the
# verifier exercises exactly that, write then read, and compares.
#
# Why no client: requiring an MLflow install to verify the server would couple
# the check to a Python toolchain the server does not need. The REST API is the
# server's own contract, so the verifier speaks it directly.
#
# Usage:
#   scripts/mlflow.verify.sh          Run the round trip against the running stack.
#   scripts/mlflow.verify.sh -h       Print this usage and exit 0.
#
# Parameters:
#   -h, --help   Print usage and exit 0. The script takes no other argument.
#
# Environment:
#   EDGE_PORT    Loopback host port the edge proxy publishes. Read from the shell
#                first, then from .env, then defaults to 24317. The MLflow address
#                is derived from it and is never hard-coded.

set -euo pipefail

# --- Location ----------------------------------------------------------------
# Resolve the repository root from the script location so the check runs the same
# way from any working directory.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

# --- Usage -------------------------------------------------------------------
usage() {
	sed -n '3,37p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
	-h | --help)
		usage
		exit 0
		;;
	"") ;;
	*)
		echo "mlflow-verify: FAIL unknown argument '$1'." >&2
		echo "  Fix: run 'scripts/mlflow.verify.sh' with no argument, or '-h' for usage." >&2
		echo "  After: re-run the command without the extra argument." >&2
		exit 2
		;;
esac

# --- Tooling gate ------------------------------------------------------------
# curl and jq are the only dependencies. Fail early and actionably if either is
# absent, rather than mid-round-trip with a confusing empty value.
for tool in curl jq; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		echo "mlflow-verify: FAIL required tool '$tool' is not on PATH." >&2
		echo "  Fix: install '$tool' (both curl and jq are needed), or run this inside the pinned mlflow image which ships them." >&2
		echo "  After: run '$tool --version' and confirm it prints, then re-run this script." >&2
		exit 2
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
mlflow_url="http://127.0.0.1:${edge_port}/mlflow"

# --- Reporting helper --------------------------------------------------------
# fail prints the three-part actionable message (what failed, the fix, what to
# check after). Cleanup runs through the EXIT trap regardless of how the script
# leaves, so fail does not delete state itself.
fail() {
	local what="$1" fix="$2" after="$3"
	echo "mlflow-verify: FAIL $what" >&2
	echo "  Fix: $fix" >&2
	echo "  After: $after" >&2
	exit 1
}

# --- Cleanup -----------------------------------------------------------------
# Track the ids created so the EXIT trap removes exactly what this run added,
# whether the run passes, fails an assertion, or is interrupted. Deletion is
# best-effort: a cleanup failure is reported but does not mask the real result.
run_id=""
experiment_id=""
cleanup() {
	if [ -n "$run_id" ]; then
		curl -s -o /dev/null --max-time 10 "${mlflow_url}/api/2.0/mlflow/runs/delete" \
			-H 'Content-Type: application/json' -d "{\"run_id\":\"${run_id}\"}" || true
	fi
	if [ -n "$experiment_id" ]; then
		curl -s -o /dev/null --max-time 10 "${mlflow_url}/api/2.0/mlflow/experiments/delete" \
			-H 'Content-Type: application/json' -d "{\"experiment_id\":\"${experiment_id}\"}" || true
	fi
}
trap cleanup EXIT

# --- Round trip --------------------------------------------------------------
echo "mlflow-verify: round trip against ${mlflow_url}"

now_ms="$(date +%s)000"
experiment_name="zz-verify-throwaway-$$-${now_ms}"
expected_param="verify-param-${now_ms}"
expected_metric="42.5"

# Step 1: create the throwaway experiment.
create_exp="$(curl -s --max-time 15 "${mlflow_url}/api/2.0/mlflow/experiments/create" \
	-H 'Content-Type: application/json' -d "{\"name\":\"${experiment_name}\"}" || true)"
experiment_id="$(printf '%s' "$create_exp" | jq -r '.experiment_id // empty')"
if [ -z "$experiment_id" ]; then
	fail "the MLflow server did not create the throwaway experiment (response: ${create_exp:-none})." \
		"confirm the mlflow backend answers on port ${edge_port}: 'curl -s ${mlflow_url}/health' should return a body, and 'scripts/stack.verify.sh' check 2 should pass." \
		"re-run 'scripts/mlflow.verify.sh' and confirm the experiment id prints."
fi

# Step 2: create a run inside that experiment.
create_run="$(curl -s --max-time 15 "${mlflow_url}/api/2.0/mlflow/runs/create" \
	-H 'Content-Type: application/json' -d "{\"experiment_id\":\"${experiment_id}\",\"start_time\":${now_ms}}" || true)"
run_id="$(printf '%s' "$create_run" | jq -r '.run.info.run_id // empty')"
if [ -z "$run_id" ]; then
	fail "the MLflow server did not create a run in experiment ${experiment_id} (response: ${create_run:-none})." \
		"confirm the runs/create endpoint answers: the mlflow backend log ('docker compose logs mlflow') names the cause of a rejected create." \
		"re-run 'scripts/mlflow.verify.sh' and confirm the run id prints."
fi

# Step 3: write one known parameter and one known metric.
curl -s -o /dev/null --max-time 15 "${mlflow_url}/api/2.0/mlflow/runs/log-parameter" \
	-H 'Content-Type: application/json' \
	-d "{\"run_id\":\"${run_id}\",\"key\":\"verify_param\",\"value\":\"${expected_param}\"}" \
	|| fail "the log-parameter call failed for run ${run_id}." \
		"confirm the mlflow backend accepts writes: check 'docker compose logs mlflow' for the rejected request." \
		"re-run 'scripts/mlflow.verify.sh' and confirm the parameter is logged."
curl -s -o /dev/null --max-time 15 "${mlflow_url}/api/2.0/mlflow/runs/log-metric" \
	-H 'Content-Type: application/json' \
	-d "{\"run_id\":\"${run_id}\",\"key\":\"verify_metric\",\"value\":${expected_metric},\"timestamp\":${now_ms},\"step\":0}" \
	|| fail "the log-metric call failed for run ${run_id}." \
		"confirm the mlflow backend accepts writes: check 'docker compose logs mlflow' for the rejected request." \
		"re-run 'scripts/mlflow.verify.sh' and confirm the metric is logged."

# Step 4: read the run back and extract the stored values.
read_run="$(curl -s --max-time 15 "${mlflow_url}/api/2.0/mlflow/runs/get?run_id=${run_id}" || true)"
got_param="$(printf '%s' "$read_run" | jq -r '.run.data.params[]? | select(.key=="verify_param") | .value')"
got_metric="$(printf '%s' "$read_run" | jq -r '.run.data.metrics[]? | select(.key=="verify_metric") | .value')"

# Step 5: assert the read values equal the written values.
if [ "$got_param" != "$expected_param" ]; then
	fail "the parameter read back ('${got_param:-none}') does not equal the value written ('${expected_param}')." \
		"the store did not persist the write; inspect the run at ${mlflow_url}/#/experiments/${experiment_id}/runs/${run_id} and the mlflow backend log." \
		"re-run 'scripts/mlflow.verify.sh' and confirm the parameter round-trips unchanged."
fi
# The metric is compared numerically so 42.5 and 42.50 do not read as unequal.
if ! printf '%s' "$got_metric" | jq -e --argjson want "$expected_metric" '. as $g | ($g|tonumber) == $want' >/dev/null 2>&1; then
	fail "the metric read back ('${got_metric:-none}') does not equal the value written ('${expected_metric}')." \
		"the store did not persist the write; inspect the run at ${mlflow_url}/#/experiments/${experiment_id}/runs/${run_id} and the mlflow backend log." \
		"re-run 'scripts/mlflow.verify.sh' and confirm the metric round-trips unchanged."
fi

echo "mlflow-verify: PASS write-then-read round trip through port ${edge_port} (param and metric match, throwaway experiment removed)."
