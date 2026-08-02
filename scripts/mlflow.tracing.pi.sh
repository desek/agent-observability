#!/usr/bin/env bash
#
# mlflow.tracing.pi.sh
#
# @agents-index Opt-in enable and disable path for pi conversation tracing against this stack: it discloses that prompts, responses, and tool input and output will be stored, names the directory and the experiment it will configure and the destination the traces will reach, waits for confirmation, then writes a directory-local switch file (.pi/mlflow-tracing.env) the pi @desek/pi-mlflow-tracing extension reads through the environment; disable removes that file and reverses the change.
#
# Purpose: turn pi conversation tracing on or off with one command, the way the
# neighbouring mlflow.autolog.claude.sh does for Claude Code, but through the
# mechanism pi actually uses. pi's @desek/pi-mlflow-tracing extension reads its
# master switch and its destination from the environment (PI_MLFLOW_ENABLE and
# the PI_MLFLOW_* / EDGE_PORT variables). pi does not itself load a dotenv file,
# so this script writes a small, self-describing switch file that a user sources
# into the shell before launching pi. Enabling records conversation content, so
# the script discloses exactly what will be stored and where before it writes
# anything and makes no change until the user confirms.
#
# Why a directory-local switch file, not a hand-edited shared file: the file this
# script owns entirely lives at <directory>/.pi/mlflow-tracing.env, inside pi's
# own project config directory. Because the script owns the whole file, disable
# is an unambiguous, complete reversal: it removes the file (and the .pi
# directory when this script created it and left it empty). A content-bearing
# choice therefore never lingers in a shared, committed file where it would
# enable the recording of another person's prompts by inheritance. The directory
# is stated explicitly in the disclosure rather than left implicit.
#
# Why the switch file carries the resolved destination: the default destination
# is built from the edge port, never hard-coded. In the local case the file
# carries EDGE_PORT so the extension derives the same local endpoint and tracking
# address it derives everywhere else, keeping one derivation path. A configured
# remote endpoint is written explicitly and, when its host is not loopback, is
# named in the disclosure as a destination off this machine, because that is the
# one case where conversation content leaves the machine.
#
# How pi picks it up: after enabling, source the switch file, then launch pi:
#   set -a && . <directory>/.pi/mlflow-tracing.env && set +a
#   pi -p "say hi"
# The extension then reconstructs each agent loop as an MLflow trace. Turn it off
# again with the --disable path, which removes the switch file.
#
# Usage:
#   scripts/mlflow.tracing.pi.sh              Enable tracing in the current
#                                             directory after an interactive
#                                             confirmation.
#   scripts/mlflow.tracing.pi.sh -d DIR       Enable tracing in DIR instead of
#                                             the current directory.
#   scripts/mlflow.tracing.pi.sh --yes        Enable without the interactive
#                                             prompt, for an automated caller.
#                                             The disclosure is still printed.
#   scripts/mlflow.tracing.pi.sh --endpoint URL [--tracking-uri URL]
#                                             Point tracing at a tracking server
#                                             other than the local stack. A
#                                             non-loopback host is named in the
#                                             disclosure as a destination off
#                                             this machine.
#   scripts/mlflow.tracing.pi.sh --experiment NAME
#                                             Write to an experiment other than
#                                             the default 'pi'.
#   scripts/mlflow.tracing.pi.sh --disable    Disable tracing (removes the switch
#                                             file, reversing the change).
#   scripts/mlflow.tracing.pi.sh -h           Print this usage and exit 0.
#
# Parameters:
#   -h, --help             Print usage and exit 0.
#   -d, --directory DIR    Directory to configure (default: current directory).
#                          Stated in the disclosure before any change is made.
#   -y, --yes              Skip the interactive confirmation but NOT the
#                          disclosure. For an agent-driven path, which is
#                          required to make the same disclosure itself.
#   --endpoint URL         The full OTLP trace ingest endpoint. Must be an
#                          absolute URL. Defaults to the local stack built from
#                          the edge port.
#   --tracking-uri URL     The MLflow tracking address the experiment name is
#                          resolved against. Must be an absolute URL. Defaults to
#                          the local stack built from the edge port. Only useful
#                          alongside --endpoint for a remote server.
#   --experiment NAME      The experiment traces land in. Default 'pi'.
#   --disable              Disable tracing by removing the switch file.
#
# Environment:
#   EDGE_PORT  Loopback host port the edge proxy publishes. Read from the shell
#              first, then from .env, then defaults to 24317. The default
#              destination is derived from it, so the port is never hard-coded.
#
# Exit status: 0 on success or when there was nothing to change; non-zero when
# the directory is unreachable, when a configured endpoint is not a valid
# absolute URL, or when the switch file cannot be written or removed.

set -euo pipefail

# --- Location ----------------------------------------------------------------
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

# --- Constants ---------------------------------------------------------------
# pi's project config directory (CONFIG_DIR_NAME in pi), and the switch file this
# script owns inside it. The extension reads its configuration from the
# environment; this file is what a user sources into that environment.
PI_CONFIG_DIR=".pi"
SWITCH_BASENAME="mlflow-tracing.env"
DEFAULT_EXPERIMENT="pi"
# The prefixed path the edge proxy routes to MLflow's OpenTelemetry ingest
# endpoint (added in Phase 1). Kept in step with the extension's INGEST_PATH.
INGEST_PATH="/mlflow-otlp/v1/traces"
# The static prefix MLflow's REST API is served under through the edge proxy.
TRACKING_PREFIX="/mlflow"

# --- Usage -------------------------------------------------------------------
usage() {
	sed -n '3,86p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# --- Address resolution ------------------------------------------------------
# Derive the edge port the same way the rest of the stack does: shell, then
# .env, then the default. The port is never hard-coded here.
resolve_edge_port() {
	local port="${EDGE_PORT:-}"
	if [ -z "$port" ] && [ -f "$repo_root/.env" ]; then
		port="$(grep -E '^[[:space:]]*EDGE_PORT[[:space:]]*=' "$repo_root/.env" | tail -n1 | cut -d= -f2 | tr -d '[:space:]')"
	fi
	printf '%s' "${port:-24317}"
}

# Extract the host from an absolute URL, without a URL parser: strip the scheme,
# strip any userinfo, take the authority up to the first '/', drop a trailing
# ':port', and strip IPv6 brackets. Enough to classify loopback versus remote.
url_host() {
	local url="$1" authority host
	authority="${url#*://}"
	authority="${authority%%/*}"
	authority="${authority##*@}"
	host="${authority%:*}"
	# A bare "[::1]" authority has no ':port' to strip via %:*, so handle brackets.
	host="${host#[}"
	host="${host%]}"
	printf '%s' "$host"
}

# Whether a host stays on this machine: localhost, any 127.x, or IPv6 ::1.
is_loopback_host() {
	local host
	host="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
	case "$host" in
	localhost | ::1 | 127.*) return 0 ;;
	*) return 1 ;;
	esac
}

# Validate a value as an absolute URL (scheme://host...). Actionable on failure.
require_absolute_url() {
	local what="$1" value="$2"
	case "$value" in
	http://* | https://*)
		if [ -n "$(url_host "$value")" ]; then
			return 0
		fi
		;;
	esac
	echo "pi-tracing: FAIL the ${what} \"${value}\" is not a valid absolute URL." >&2
	echo "  Expected an absolute URL of the form http://host:port/path, for example" >&2
	echo "  http://localhost:$(resolve_edge_port)${INGEST_PATH} for the local stack." >&2
	echo "  Fix: pass ${what} as such a URL, or omit it to use the local default built from EDGE_PORT." >&2
	echo "  After: re-run and confirm the disclosure names the destination you intended." >&2
	exit 1
}

# --- Argument parsing --------------------------------------------------------
directory="$(pwd)"
assume_yes=0
mode="enable"
endpoint_arg=""
tracking_arg=""
experiment="$DEFAULT_EXPERIMENT"
while [ "$#" -gt 0 ]; do
	case "$1" in
	-h | --help)
		usage
		exit 0
		;;
	-d | --directory)
		if [ "$#" -lt 2 ]; then
			echo "pi-tracing: FAIL the -d/--directory option needs a directory argument." >&2
			echo "  Fix: pass a path, for example 'scripts/mlflow.tracing.pi.sh -d .'." >&2
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
	--endpoint)
		if [ "$#" -lt 2 ]; then
			echo "pi-tracing: FAIL the --endpoint option needs a URL argument." >&2
			echo "  Fix: pass an absolute URL, or omit --endpoint to use the local default." >&2
			echo "  After: re-run and confirm the disclosure names the destination you intended." >&2
			exit 2
		fi
		endpoint_arg="$2"
		shift 2
		;;
	--tracking-uri)
		if [ "$#" -lt 2 ]; then
			echo "pi-tracing: FAIL the --tracking-uri option needs a URL argument." >&2
			echo "  Fix: pass an absolute URL, or omit --tracking-uri to use the local default." >&2
			echo "  After: re-run and confirm the disclosure names the destination you intended." >&2
			exit 2
		fi
		tracking_arg="$2"
		shift 2
		;;
	--experiment)
		if [ "$#" -lt 2 ]; then
			echo "pi-tracing: FAIL the --experiment option needs a name argument." >&2
			echo "  Fix: pass an experiment name, or omit --experiment to use the default '${DEFAULT_EXPERIMENT}'." >&2
			echo "  After: re-run and confirm the disclosure names the experiment you intended." >&2
			exit 2
		fi
		experiment="$2"
		shift 2
		;;
	--disable)
		mode="disable"
		shift
		;;
	*)
		echo "pi-tracing: FAIL unknown argument '$1'." >&2
		echo "  Fix: run 'scripts/mlflow.tracing.pi.sh -h' for the accepted options." >&2
		echo "  After: re-run with a recognised option." >&2
		exit 2
		;;
	esac
done

# Resolve the directory to an absolute path so the disclosure and the switch file
# both name the same place, never a relative path that depends on the caller's cwd.
if ! directory="$(cd "$directory" 2>/dev/null && pwd)"; then
	echo "pi-tracing: FAIL the target directory does not exist or is not reachable." >&2
	echo "  Fix: create the directory first, or pass an existing one with -d/--directory." >&2
	echo "  After: re-run and confirm the disclosure names the directory you intended." >&2
	exit 1
fi
config_dir="$directory/$PI_CONFIG_DIR"
switch_file="$config_dir/$SWITCH_BASENAME"

# --- Disable path ------------------------------------------------------------
# Remove the switch file, reversing the change completely. Also remove the .pi
# directory when this script's file was the only thing in it, so no empty
# residue is left behind. Already-stored traces are not deleted here.
if [ "$mode" = "disable" ]; then
	echo "pi-tracing: disabling pi conversation tracing in ${directory}"
	echo "  This removes the switch file ${switch_file}."
	echo "  With that file gone and no PI_MLFLOW_ENABLE in your environment, the extension"
	echo "  registers no handler and no further pi turn produces a trace."
	echo "  Already-stored conversations are not deleted by this; the README MLflow section states how to remove them."
	if [ ! -f "$switch_file" ]; then
		echo "pi-tracing: nothing to remove; ${switch_file} does not exist. Tracing is already off in ${directory}."
		exit 0
	fi
	if ! rm -f "$switch_file"; then
		echo "pi-tracing: FAIL could not remove the switch file ${switch_file}." >&2
		echo "  Fix: check the file's permissions and remove it by hand with 'rm ${switch_file}'." >&2
		echo "  After: confirm the file is gone with 'ls ${switch_file}'." >&2
		exit 1
	fi
	# Remove the .pi directory only when it is now empty, so a directory pi or the
	# user populated for another reason is never deleted.
	if [ -d "$config_dir" ] && [ -z "$(ls -A "$config_dir" 2>/dev/null)" ]; then
		rmdir "$config_dir" 2>/dev/null || true
	fi
	echo
	echo "pi-tracing: done. Tracing is off in ${directory}; a subsequent pi turn produces no trace."
	echo "  If this shell already sourced the switch file, unset the switch: unset PI_MLFLOW_ENABLE"
	exit 0
fi

# --- Enable path: resolve the destination ------------------------------------
edge_port="$(resolve_edge_port)"
# Validate any configured URLs before disclosing, so a bad value fails loudly and
# early rather than being written into the switch file.
if [ -n "$endpoint_arg" ]; then
	require_absolute_url "--endpoint" "$endpoint_arg"
fi
if [ -n "$tracking_arg" ]; then
	require_absolute_url "--tracking-uri" "$tracking_arg"
fi

# The destination shown in the disclosure. A configured endpoint wins; otherwise
# the local default is built from the edge port.
if [ -n "$endpoint_arg" ]; then
	display_endpoint="$endpoint_arg"
else
	display_endpoint="http://localhost:${edge_port}${INGEST_PATH}"
fi
if [ -n "$tracking_arg" ]; then
	display_tracking="$tracking_arg"
else
	display_tracking="http://localhost:${edge_port}${TRACKING_PREFIX}"
fi
endpoint_host="$(url_host "$display_endpoint")"
remote_note=""
if ! is_loopback_host "$endpoint_host"; then
	remote_note="$endpoint_host"
fi

# --- Disclosure --------------------------------------------------------------
# Printed before any write and regardless of --yes, because the effect is to
# store conversation content and that decision must be visible.
echo "pi-tracing: about to enable pi conversation tracing."
echo
echo "  Directory it will configure : ${directory}"
echo "  File it will write          : ${switch_file}"
echo "                                (pi's project config directory; source it into your shell before"
echo "                                 launching pi, and it stays out of any shared, committed file)"
echo "  Switch it will set          : PI_MLFLOW_ENABLE=1 (the master switch the extension reads)"
echo "  Experiment                  : ${experiment}"
echo "  Ingest endpoint             : ${display_endpoint}"
echo "  Tracking address            : ${display_tracking}"
echo
echo "  What this stores: once enabled and sourced, every pi turn in this directory sends the whole"
echo "  conversation to the tracking server above. That is every prompt, every response, and every"
echo "  tool input and tool result."
if [ -n "$remote_note" ]; then
	echo
	echo "  OFF-MACHINE DESTINATION: the endpoint host '${remote_note}' is not a loopback address, so"
	echo "  enabling this sends your conversation content OFF this machine to that host. Only proceed if"
	echo "  you intend that. Omit --endpoint to keep all content on this machine (the local stack)."
else
	echo "  The data stays on this machine, in the local stack's own volume."
fi
echo "  Turn it off later with: scripts/mlflow.tracing.pi.sh --disable -d \"${directory}\""
echo

# --- Confirmation ------------------------------------------------------------
# Unless an automated caller passed --yes. The disclosure above is never skipped.
if [ "$assume_yes" -eq 0 ]; then
	printf '  Type "yes" to enable conversation tracing, anything else to cancel: '
	read -r reply
	if [ "$reply" != "yes" ]; then
		echo "pi-tracing: cancelled; no change was made."
		exit 0
	fi
fi

# --- Write the switch file ---------------------------------------------------
if ! mkdir -p "$config_dir"; then
	echo "pi-tracing: FAIL could not create the config directory ${config_dir}." >&2
	echo "  Fix: check the parent directory's permissions, or choose another directory with -d/--directory." >&2
	echo "  After: confirm the directory exists with 'ls -d ${config_dir}'." >&2
	exit 1
fi

# Build the file body. In the local case, carry EDGE_PORT so the extension
# derives the same local endpoint and tracking address it derives everywhere,
# keeping one derivation path and never hard-coding a destination. In the
# configured case, carry the explicit endpoint and tracking address.
{
	echo "# @generated by scripts/mlflow.tracing.pi.sh -- the pi conversation-tracing switch."
	echo "# Source this file into your shell before launching pi, then run pi as usual:"
	echo "#   set -a && . ${PI_CONFIG_DIR}/${SWITCH_BASENAME} && set +a"
	echo "#   pi -p \"say hi\""
	echo "# Turn tracing off with: scripts/mlflow.tracing.pi.sh --disable -d \"${directory}\""
	echo "PI_MLFLOW_ENABLE=1"
	echo "PI_MLFLOW_EXPERIMENT=${experiment}"
	if [ -n "$endpoint_arg" ]; then
		echo "PI_MLFLOW_ENDPOINT=${endpoint_arg}"
	fi
	if [ -n "$tracking_arg" ]; then
		echo "PI_MLFLOW_TRACKING_URI=${tracking_arg}"
	fi
	if [ -z "$endpoint_arg" ] || [ -z "$tracking_arg" ]; then
		# The local default for whichever of endpoint or tracking was not set
		# explicitly is derived from the edge port at source time.
		echo "EDGE_PORT=${edge_port}"
	fi
} >"$switch_file"

echo
echo "pi-tracing: done. Conversation tracing is configured in ${directory}."
echo "  Switch file      : ${switch_file}"
echo "  To take effect, source it and launch pi:"
echo "    set -a && . \"${switch_file}\" && set +a"
echo "    pi -p \"say hi\""
echo "  Traces will appear at: ${display_tracking} in the '${experiment}' experiment after a pi turn ends."
echo "  Disable later with   : scripts/mlflow.tracing.pi.sh --disable -d \"${directory}\""
