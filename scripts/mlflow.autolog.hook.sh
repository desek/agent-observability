#!/usr/bin/env bash
#
# mlflow.autolog.hook.sh
#
# @agents-index Client-resolution wrapper the Claude Code end-of-turn hook invokes: it picks an MLflow client at run time in a documented preference order (client on PATH, then an ephemeral uv-run client) and runs the stop-hook through it, forwarding the hook JSON on stdin.
#
# Purpose: keep the choice of MLflow client out of the user's Claude Code
# settings file. The end-of-turn Stop hook that the enable path installs points
# at this script instead of a bare `mlflow autolog claude stop-hook`, so the
# client can change with the user's environment without editing the settings
# file. Claude Code runs the hook after a turn ends and pipes a JSON object
# ({"session_id":..., "transcript_path":...}) to this script's stdin; the
# script resolves a client and execs it, which inherits that stdin unchanged,
# so the client reads the same hook input the settings-frozen command would
# have. Because the resolution happens here in one readable place, a later
# install or removal of a Python environment does not silently break tracing.
#
# The preference order, resolved fresh on every invocation:
#   1. An `mlflow` client already on PATH. Forwarded exactly as installed, so
#      the user's own client version is respected.
#   2. An ephemeral client run through a Python tool runner (`uvx`, else
#      `uv tool run`), when one is installed. No permanent MLflow install is
#      required. The version is pinned by MLFLOW_HOOK_UVX_SPEC (see below).
#
# The stack's own MLflow container is deliberately NOT a branch. It was tested
# and does not work: the running stack container mounts only its data volume,
# so it cannot read a transcript that lives on the host filesystem; the stack
# image no longer processes the transcript in-process, since the stop-hook has
# moved to a separate marketplace plugin runtime and only prints a migration
# notice; and the standard client's Host header is rejected by the tracking
# server (HTTP 403) on every address a container can reach. A branch that reads
# nothing and writes nothing is worse than a named, actionable absence, so the
# container fallback is omitted and the missing-client message names the two
# working ways to provide a client instead.
#
# A resolution failure exits non-zero with a message that names every way to
# provide a client and what to check after applying one, so the user is not
# left with tracing that silently does nothing at the end of each turn.
#
# Usage:
#   scripts/mlflow.autolog.hook.sh          Resolve a client and run the Claude
#                                           Code stop-hook, reading the hook
#                                           JSON on stdin. This is the form the
#                                           installed Stop hook invokes.
#   scripts/mlflow.autolog.hook.sh --which  Resolve a client, print the chosen
#                                           invocation, and exit without running
#                                           the hook. Use it to confirm a client
#                                           resolves after installing one.
#   scripts/mlflow.autolog.hook.sh -h       Print this usage and exit 0.
#   scripts/mlflow.autolog.hook.sh ARGS...  Run the resolved client with ARGS
#                                           instead of the default subcommand
#                                           (for testing and override).
#
# Parameters:
#   -h, --help  Print usage and exit 0.
#   --which     Resolve the client, print the invocation, and exit 0; exit
#               non-zero with the missing-client message when none resolves.
#   ARGS...     Passed to the resolved client in place of the default
#               `autolog claude stop-hook` subcommand.
#
# Environment:
#   MLFLOW_HOOK_UVX_SPEC  pip requirement specifier for the ephemeral branch,
#                         default `mlflow>=3.14`. The 3.14 release moved the
#                         in-process stop-hook to a marketplace plugin, and the
#                         `mlflow autolog claude` setup command from that release
#                         installs the plugin and writes the settings the plugin
#                         runtime reads. The enable path (mlflow.autolog.claude.sh)
#                         needs a client at 3.14 or later so that setup command is
#                         present, so the ephemeral branch is pinned to it.
#                         Override to move the pin without editing the resolution
#                         logic.
#   EDGE_PORT             Loopback host port the edge proxy publishes. Read from
#                         the shell first, then from .env, then defaults to
#                         24317. Used only to name the tracking address in the
#                         missing-client message, so the port is never
#                         hard-coded.

set -euo pipefail

# --- Location ----------------------------------------------------------------
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

# --- Usage -------------------------------------------------------------------
usage() {
	sed -n '3,74p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# --- Configuration -----------------------------------------------------------
# The ephemeral branch pins the client version to 3.14 or later because that is
# the release whose `mlflow autolog claude` setup command installs the marketplace
# plugin and writes the settings the plugin runtime reads. The enable path
# (mlflow.autolog.claude.sh) requires that command, so an ephemeral client older
# than 3.14 would be unusable for setup.
uvx_spec="${MLFLOW_HOOK_UVX_SPEC:-mlflow>=3.14}"

# The subcommand the installed Stop hook is meant to run. Explicit arguments on
# the command line replace it, which is what makes --which and testing possible
# without triggering a real trace write.
default_args=(autolog claude stop-hook)

# --- Address resolution ------------------------------------------------------
# Derive the tracking address from EDGE_PORT the same way the rest of the stack
# does: shell, then .env, then the default. Used only to name the address in the
# missing-client message, so the port is never hard-coded here.
resolve_edge_port() {
	local port="${EDGE_PORT:-}"
	if [ -z "$port" ] && [ -f "$repo_root/.env" ]; then
		port="$(grep -E '^[[:space:]]*EDGE_PORT[[:space:]]*=' "$repo_root/.env" | tail -n1 | cut -d= -f2 | tr -d '[:space:]')"
	fi
	printf '%s' "${port:-24317}"
}

# --- Client resolution -------------------------------------------------------
# Resolve the first available client in the preference order and record its
# invocation in the client_argv array and a short label in client_branch.
# Returns 0 when a client was resolved, non-zero when none is available.
client_argv=()
client_branch=""
resolve_client() {
	if command -v mlflow >/dev/null 2>&1; then
		client_argv=(mlflow)
		client_branch="path"
		return 0
	fi
	if command -v uvx >/dev/null 2>&1; then
		client_argv=(uvx --from "$uvx_spec" mlflow)
		client_branch="ephemeral-uvx"
		return 0
	fi
	if command -v uv >/dev/null 2>&1; then
		client_argv=(uv tool run --from "$uvx_spec" mlflow)
		client_branch="ephemeral-uv"
		return 0
	fi
	return 1
}

# --- Missing-client report ---------------------------------------------------
# Print the actionable message for the case where no client resolves. It names
# every way to provide a client and what to check after applying one, so the
# silent-no-op failure mode has a visible, followable fix.
report_no_client() {
	local port
	port="$(resolve_edge_port)"
	echo "hook: FAIL no MLflow client could be resolved to run the Claude Code stop-hook." >&2
	echo "  The end-of-turn trace was not written, because no client was found on this machine." >&2
	echo "  Provide a client in any one of these ways, then complete another Claude Code turn:" >&2
	echo "    1. Install the MLflow client on your PATH so 'mlflow' resolves, for example 'pipx install mlflow' or 'pip install mlflow'." >&2
	echo "    2. Install the uv Python tool runner so an ephemeral client can run with no permanent install, for example 'brew install uv' or 'curl -LsSf https://astral.sh/uv/install.sh | sh'." >&2
	echo "  The stack's MLflow container is not offered here on purpose: its image no longer processes the transcript in-process (the stop-hook moved to a marketplace plugin) and it cannot read the host transcript without remounting the running container." >&2
	echo "  After applying one: run 'scripts/mlflow.autolog.hook.sh --which' to confirm a client resolves, then complete a turn and confirm a trace appears in the 'claude-code' experiment at http://127.0.0.1:${port}/mlflow." >&2
}

# --- Argument parsing --------------------------------------------------------
mode="run"
case "${1:-}" in
	-h | --help)
		usage
		exit 0
		;;
	--which)
		mode="which"
		shift
		;;
esac

# Any remaining arguments replace the default subcommand.
if [ "$#" -gt 0 ]; then
	run_args=("$@")
else
	run_args=("${default_args[@]}")
fi

# --- Run ---------------------------------------------------------------------
if ! resolve_client; then
	report_no_client
	exit 1
fi

if [ "$mode" = "which" ]; then
	echo "hook: resolved client [${client_branch}]: ${client_argv[*]}"
	exit 0
fi

# exec so the resolved client inherits this script's stdin (the hook JSON that
# Claude Code piped in) and its exit status becomes the hook's exit status.
exec "${client_argv[@]}" "${run_args[@]}"
