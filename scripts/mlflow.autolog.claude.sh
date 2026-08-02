#!/usr/bin/env bash
#
# mlflow.autolog.claude.sh
#
# @agents-index Opt-in enable and disable path for Claude Code conversation tracing against this stack: it resolves an MLflow client through mlflow.autolog.hook.sh, refuses any client below 3.14 because only that release ships the plugin runtime, discloses that prompts, responses, and tool input and output are stored locally, then configures through the client's own `mlflow autolog claude` command into the directory's local settings file.
#
# Purpose: turn Claude Code conversation tracing on or off with one command, and
# do it through the MLflow client's own `mlflow autolog claude` command rather
# than by hand-editing a settings file. From MLflow 3.14 that command installs a
# marketplace plugin into Claude Code and writes MLflow configuration; the plugin
# runtime then produces a trace from the transcript when a `claude` turn ends. So
# this script does not write settings itself and does not install a hook of its
# own. It resolves a client, checks its version, discloses what will be stored,
# asks for confirmation, and calls the client's command with the stack's tracking
# address and the claude-code experiment.
#
# Why the version gate: a client below 3.14 has the old in-process stop-hook and
# no plugin, so configuring it writes settings the plugin runtime never reads and
# yields no trace. Detecting the version before any change and refusing a client
# below 3.14 is what stops a silent no-op, so the script checks the version first
# and refuses with the version found and the command that provides a newer client.
#
# Why the local settings file: the client's `--local` flag writes the
# configuration into `.claude/settings.local.json`, which is kept out of version
# control by default. A content-bearing choice belongs there so a committed
# `.claude/settings.json` never enables the recording of another person's prompts
# by inheritance. The directory is stated explicitly rather than relying on the
# command's default of the current directory.
#
# Why resolve through the hook: mlflow.autolog.hook.sh already resolves an MLflow
# client in the documented preference order (a client on PATH, then an ephemeral
# `uv`-run client), so the resolution logic lives in one place instead of being
# duplicated here. This script asks it for the resolved invocation with `--which`
# and runs the client's `--version` and `autolog claude` subcommands through it.
#
# Usage:
#   scripts/mlflow.autolog.claude.sh            Enable tracing in the current
#                                               directory after an interactive
#                                               confirmation.
#   scripts/mlflow.autolog.claude.sh -d DIR     Enable tracing in DIR instead of
#                                               the current directory.
#   scripts/mlflow.autolog.claude.sh --yes      Enable without the interactive
#                                               prompt, for an automated caller.
#                                               The disclosure is still printed.
#   scripts/mlflow.autolog.claude.sh --disable  Disable tracing (clears the
#                                               configuration from both settings
#                                               files, through the client).
#   scripts/mlflow.autolog.claude.sh -h         Print this usage and exit 0.
#
# Parameters:
#   -h, --help             Print usage and exit 0.
#   -d, --directory DIR    Directory to configure (default: current directory).
#                          Stated in the disclosure before any change is made.
#   -y, --yes              Skip the interactive confirmation but NOT the
#                          disclosure. For the agent-driven installation path,
#                          which is required to make the same disclosure itself.
#   --disable              Disable tracing through the client's own `--disable`,
#                          which removes the configuration from both the shared
#                          and the local settings files.
#
# Environment:
#   EDGE_PORT  Loopback host port the edge proxy publishes. Read from the shell
#              first, then from .env, then defaults to 24317. The tracking address
#              is derived from it as http://127.0.0.1:PORT/mlflow, so the port is
#              never hard-coded.
#
# Exit status: 0 on success or when the configuration is already in place;
# non-zero when no client resolves, when the resolved client is below 3.14, or
# when the client's own command fails.

set -euo pipefail

# --- Location ----------------------------------------------------------------
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
hook="$script_dir/mlflow.autolog.hook.sh"

# --- Constants ---------------------------------------------------------------
# The plugin runtime that produces traces exists only from this MLflow release.
MIN_MAJOR=3
MIN_MINOR=14
# The claude-code experiment provisioned by mlflow.provision.sh (Phase 1) has
# this identifier. Traces from Claude Code land in it.
CLAUDE_EXPERIMENT_ID=1

# --- Usage -------------------------------------------------------------------
usage() {
	sed -n '3,62p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# --- Address resolution ------------------------------------------------------
# Derive the edge port from EDGE_PORT the same way the rest of the stack does:
# shell, then .env, then the default. The port is never hard-coded here.
resolve_edge_port() {
	local port="${EDGE_PORT:-}"
	if [ -z "$port" ] && [ -f "$repo_root/.env" ]; then
		port="$(grep -E '^[[:space:]]*EDGE_PORT[[:space:]]*=' "$repo_root/.env" | tail -n1 | cut -d= -f2 | tr -d '[:space:]')"
	fi
	printf '%s' "${port:-24317}"
}

# --- Argument parsing --------------------------------------------------------
directory="$(pwd)"
assume_yes=0
mode="enable"
while [ "$#" -gt 0 ]; do
	case "$1" in
	-h | --help)
		usage
		exit 0
		;;
	-d | --directory)
		if [ "$#" -lt 2 ]; then
			echo "claude-autolog: FAIL the -d/--directory option needs a directory argument." >&2
			echo "  Fix: pass a path, for example 'scripts/mlflow.autolog.claude.sh -d .'." >&2
			echo "  After: re-run and confirm the disclosure names the directory you intended." >&2
			exit 2
		fi
		directory="$2"
		shift 2
		;;
	-y | --yes | --non-interactive)
		assume_yes=1
		shift
		;;
	--disable)
		mode="disable"
		shift
		;;
	*)
		echo "claude-autolog: FAIL unknown argument '$1'." >&2
		echo "  Fix: run 'scripts/mlflow.autolog.claude.sh -h' for the accepted options." >&2
		echo "  After: re-run with a recognised option." >&2
		exit 2
		;;
	esac
done

# Resolve the directory to an absolute path so the disclosure and the client both
# name the same place, never a relative path that depends on the caller's cwd.
if ! directory="$(cd "$directory" 2>/dev/null && pwd)"; then
	echo "claude-autolog: FAIL the target directory does not exist or is not reachable." >&2
	echo "  Fix: create the directory first, or pass an existing one with -d/--directory." >&2
	echo "  After: re-run and confirm the disclosure names the directory you intended." >&2
	exit 1
fi
settings_file="$directory/.claude/settings.local.json"

# --- Client resolution -------------------------------------------------------
# Ask the hook for the resolved client invocation. On failure the hook prints its
# own actionable missing-client message to stderr, which reaches the terminal
# through the command substitution, so this branch only has to propagate the exit.
if ! which_out="$("$hook" --which)"; then
	exit 1
fi
# The hook prints: "hook: resolved client [branch]: <argv...>". Take the argv.
invocation="$(printf '%s\n' "$which_out" | sed -E 's/^hook: resolved client \[[^]]*\]: //')"
read -r -a client_argv <<<"$invocation"
if [ "${#client_argv[@]}" -eq 0 ]; then
	echo "claude-autolog: FAIL could not parse the client invocation from the hook." >&2
	echo "  Fix: run 'scripts/mlflow.autolog.hook.sh --which' and confirm it prints a resolved client line." >&2
	echo "  After: re-run this script once the hook resolves a client." >&2
	exit 1
fi

# --- Version gate ------------------------------------------------------------
# Read the client version before changing anything. A client below 3.14 has no
# plugin runtime, so configuring it produces settings that never yield a trace.
ver_raw="$("${client_argv[@]}" --version 2>&1 || true)"
version="$(printf '%s\n' "$ver_raw" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
if [ -z "$version" ]; then
	echo "claude-autolog: FAIL could not read the version of the resolved MLflow client." >&2
	echo "  The client was '${client_argv[*]}' and 'mlflow --version' did not print a version." >&2
	echo "  Fix: run '${client_argv[*]} --version' by hand and confirm it prints a version, then re-run." >&2
	echo "  After: confirm the printed version is $MIN_MAJOR.$MIN_MINOR or later." >&2
	exit 1
fi
ver_major="$(printf '%s' "$version" | cut -d. -f1)"
ver_minor="$(printf '%s' "$version" | cut -d. -f2)"
if [ "$ver_major" -lt "$MIN_MAJOR" ] || { [ "$ver_major" -eq "$MIN_MAJOR" ] && [ "$ver_minor" -lt "$MIN_MINOR" ]; }; then
	port="$(resolve_edge_port)"
	echo "claude-autolog: FAIL the resolved MLflow client is version $version, below the required $MIN_MAJOR.$MIN_MINOR." >&2
	echo "  Conversation tracing needs the plugin runtime, which exists only from MLflow $MIN_MAJOR.$MIN_MINOR. A client below it would write settings that never produce a trace, so this script refuses rather than configuring it." >&2
	echo "  The resolved client was '${client_argv[*]}'." >&2
	echo "  Fix, any one of:" >&2
	echo "    1. Upgrade the client on your PATH, for example 'pipx upgrade mlflow' or 'pip install -U \"mlflow>=$MIN_MAJOR.$MIN_MINOR\"'." >&2
	echo "    2. Run a newer client without a permanent install: remove the older 'mlflow' from PATH so the hook falls through to its ephemeral branch, which resolves 'mlflow>=$MIN_MAJOR.$MIN_MINOR' through uv." >&2
	echo "  After: run 'scripts/mlflow.autolog.hook.sh --which' then '<that client> --version' and confirm it reports $MIN_MAJOR.$MIN_MINOR or later, then re-run this script." >&2
	echo "  Tracking address, for reference: http://127.0.0.1:${port}/mlflow" >&2
	exit 1
fi

# --- Disable path ------------------------------------------------------------
# Use the client's own --disable, which clears the configuration from both the
# shared and the local settings files. Reimplementing removal is not attempted.
if [ "$mode" = "disable" ]; then
	echo "claude-autolog: disabling Claude Code conversation tracing in ${directory}"
	echo "  This clears the tracing configuration from both ${directory}/.claude/settings.json and ${directory}/.claude/settings.local.json through the client's own --disable."
	echo "  Already-stored conversations are not deleted by this; the README MLflow section states how to remove them."
	if ! "${client_argv[@]}" autolog claude --disable -d "$directory"; then
		echo "claude-autolog: FAIL the client's --disable command returned an error." >&2
		echo "  Fix: run '${client_argv[*]} autolog claude --status -d \"$directory\"' to see the current state, then re-run --disable." >&2
		echo "  After: confirm the status reports tracing is not enabled." >&2
		exit 1
	fi
	echo "claude-autolog: done. Confirm with '${client_argv[*]} autolog claude --status -d \"$directory\"'."
	exit 0
fi

# --- Enable path -------------------------------------------------------------
tracking_uri="http://127.0.0.1:$(resolve_edge_port)/mlflow"

# Idempotency: if tracing is already enabled in this directory, say so and change
# nothing, so a second enable neither duplicates configuration nor churns the file.
status_out="$("${client_argv[@]}" autolog claude --status -d "$directory" 2>&1 || true)"
if ! printf '%s\n' "$status_out" | grep -q 'is not enabled' && printf '%s\n' "$status_out" | grep -q 'is enabled'; then
	echo "claude-autolog: Claude Code conversation tracing is already enabled in ${directory}; nothing to do."
	echo "  Configuration file: ${settings_file}"
	printf '%s\n' "$status_out" | sed 's/^/  /'
	echo "  To change the tracking address or experiment, run '--disable' first, then enable again."
	exit 0
fi

# Disclosure, printed before any write and regardless of --yes, because the effect
# is to store conversation content locally and that decision must be visible.
echo "claude-autolog: about to enable Claude Code conversation tracing."
echo
echo "  Directory it will configure : ${directory}"
echo "  File it will write          : ${settings_file}"
echo "                                (the local settings file, kept out of version control by default,"
echo "                                 so a committed settings.json never enables this by inheritance)"
echo "  Tracking address            : ${tracking_uri}"
echo "  Experiment                  : claude-code (id ${CLAUDE_EXPERIMENT_ID})"
echo
echo "  What this stores: once enabled, every Claude Code turn in this directory sends the whole"
echo "  conversation to the local MLflow tracking server. That is every prompt, every response, and"
echo "  every tool input and output. The data stays on this machine, in the stack's own volume."
echo "  Turn it off later with: scripts/mlflow.autolog.claude.sh --disable -d \"${directory}\""
echo

# Confirmation, unless an automated caller passed --yes. The disclosure above is
# never skipped, only this prompt is.
if [ "$assume_yes" -eq 0 ]; then
	printf '  Type "yes" to enable conversation tracing, anything else to cancel: '
	read -r reply
	if [ "$reply" != "yes" ]; then
		echo "claude-autolog: cancelled; no change was made."
		exit 0
	fi
fi

# Configure through the client's own command. --local targets settings.local.json,
# -d states the directory explicitly, -u carries the derived tracking address, -e
# targets the claude-code experiment, -y skips the client's own prompt.
if ! "${client_argv[@]}" autolog claude -d "$directory" --local -u "$tracking_uri" -e "$CLAUDE_EXPERIMENT_ID" -y; then
	echo "claude-autolog: FAIL the client's 'autolog claude' setup command returned an error." >&2
	echo "  No usable configuration was written. The resolved client was '${client_argv[*]}'." >&2
	echo "  Fix: confirm the client runs with '${client_argv[*]} autolog claude --status -d \"$directory\"', then re-run this script." >&2
	echo "  After: confirm ${settings_file} exists and that the status reports tracing is enabled." >&2
	exit 1
fi

echo
echo "claude-autolog: done. Conversation tracing is enabled in ${directory}."
echo "  Configuration file : ${settings_file}"
echo "  Traces will appear at: ${tracking_uri} in the claude-code experiment after a Claude Code turn ends."
echo "  Disable later with   : scripts/mlflow.autolog.claude.sh --disable -d \"${directory}\""
