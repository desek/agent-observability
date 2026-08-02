#!/usr/bin/env bash
#
# transcript.import.sh
#
# @agents-index Resolves the edge port and a Python interpreter, then runs the transcript importer that writes the redacted session transcripts into Mimir, Loki, and Tempo through the single edge port.
#
# Purpose: keep the shell concerns (port resolution, preconditions, argument
# pass-through) out of the importer itself, which is a program rather than a
# pipeline and is therefore written in Python. The work, and the reasoning behind
# the timeline compression and the computed cost, is documented in
# scripts/transcript.import.py.
#
# The importer reads only .transcripts/, the gitignored output of
# scripts/transcript.redact.sh. It never reads the original session files, so
# identity and secrets are removed before anything reaches the stack.
#
# Usage:
#   scripts/transcript.import.sh               Import every redacted transcript.
#   scripts/transcript.import.sh --span 5400   Compress onto this many seconds.
#   scripts/transcript.import.sh --dry-run     Report what would be written.
#   scripts/transcript.import.sh -h            Print this usage and exit 0.
#
# Parameters:
#   -h, --help    Print usage and exit 0.
#   --span N      Seconds of wall clock to compress the real span onto.
#   --dry-run     Parse and report without writing to the stack.
#
# Environment:
#   EDGE_PORT     Loopback host port the edge proxy publishes. Read from the
#                 shell first, then from .env, then defaults to 24317.
#
# Exit status: 0 on success; non-zero on the first failure, with a message that
# names what failed, the fix, and what to check after.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

usage() { sed -n '3,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

case "${1:-}" in
	-h | --help)
		usage
		exit 0
		;;
esac

cd "$repo_root"

command -v python3 >/dev/null 2>&1 || {
	echo "import: FAIL python3 is not installed." >&2
	echo "  Fix: install python3; the importer is a program rather than a pipeline and is written in Python." >&2
	echo "  After: re-run 'scripts/transcript.import.sh' once python3 is on PATH." >&2
	exit 1
}

# Port resolution: the shell environment wins, then .env, then the default. This
# matches how docker compose resolves EDGE_PORT, so the script and the stack
# never disagree about which port to use.
resolve_edge_port() {
	local port="${EDGE_PORT:-}"
	if [ -z "$port" ] && [ -f "$repo_root/.env" ]; then
		port="$(grep -E '^[[:space:]]*EDGE_PORT[[:space:]]*=' "$repo_root/.env" | tail -n1 | cut -d= -f2 | tr -d '[:space:]')"
	fi
	printf '%s' "${port:-24317}"
}

EDGE_PORT="$(resolve_edge_port)"
export EDGE_PORT

exec python3 "$script_dir/transcript.import.py" --repo-root "$repo_root" "$@"
