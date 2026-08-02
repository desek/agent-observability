#!/usr/bin/env bash
#
# transcript.redact.sh
#
# @agents-index Copies this repository's coding-agent session transcripts into a gitignored folder with secrets and identity removed, drops tool output by default, and refuses the whole run if gitleaks still finds a secret in what it produced.
#
# Purpose: make a session transcript safe to read, share, or import into the
# stack. A transcript is a faithful record of everything an agent did, which
# means it carries whatever passed through the session: prompts, responses, file
# contents, and the output of every command that ran. That output is where a
# secret is most likely to appear, because it arrives from somewhere nobody was
# thinking about. A credential echoed inside a shell error message reached a
# transcript in this repository exactly that way.
#
# The redaction is layered, and the layers are ordered from the most reliable to
# the least:
#
#   1. Tool output is dropped. The stdout and stderr of every tool call are
#      replaced with a marker. This is the largest surface, the least
#      predictable, and the least useful: the shape of a session needs to know
#      that a command ran and whether it failed, not what it printed. Pass
#      --with-tool-output to keep it, and read the warning that prints.
#   2. Known identity is replaced by name. The home path, the git author email,
#      and any address in the transcript become fixed placeholders, so a reader
#      sees that a value was there without seeing the value.
#   3. Known secret shapes are replaced by pattern. These are the formats a
#      token announces itself with, such as an npm access token prefix.
#   4. What remains is scanned by gitleaks, whose rule set is maintained by
#      people who follow credential formats for a living, which a hand-written
#      list in this repository would not be.
#
# The fourth layer decides the run. If gitleaks finds a secret in the redacted
# output, the whole run is refused and the output is removed. Redaction that
# silently lets one through is worse than none, because it manufactures a
# confidence nobody checked. A refusal costs a re-run; a leak cannot be undone,
# and this stack has no delete interface for anything it has ingested.
#
# Usage:
#   scripts/transcript.redact.sh                 Redact every transcript for this repository.
#   scripts/transcript.redact.sh --source DIR    Redact the transcripts under DIR instead.
#   scripts/transcript.redact.sh --with-tool-output
#                                                Keep tool stdout and stderr. Riskier.
#   scripts/transcript.redact.sh --selftest      Plant a secret, prove the run is refused.
#   scripts/transcript.redact.sh -h              Print this usage and exit 0.
#
# Parameters:
#   -h, --help            Print usage and exit 0.
#   --source DIR          Read transcripts from DIR rather than the default set.
#   --out DIR             Write to DIR rather than the default gitignored folder.
#   --with-tool-output    Keep tool stdout and stderr in the output.
#   --selftest            Run the negative test and exit.
#
# Output: .transcripts/ at the repository root, which .gitignore excludes. The
# folder is emptied at the start of each run so a refused run leaves nothing
# behind and a successful run is never a mixture of two.
#
# Exit status: 0 on success; non-zero on the first failure, with a message that
# names what failed, the fix, and what to check after.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

usage() { sed -n '3,60p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

info() { echo "redact: $1"; }
pass() { echo "redact: PASS $1"; }
fail() {
	local what="$1" fix="$2" after="$3"
	echo "redact: FAIL $what" >&2
	echo "  Fix: $fix" >&2
	echo "  After: $after" >&2
	exit 1
}

# --- Arguments ----------------------------------------------------------------
source_dir=""
out_dir=""
keep_tool_output="no"
selftest="no"

while [ $# -gt 0 ]; do
	case "$1" in
		-h | --help) usage; exit 0 ;;
		--source) source_dir="${2:-}"; shift 2 ;;
		--out) out_dir="${2:-}"; shift 2 ;;
		--with-tool-output) keep_tool_output="yes"; shift ;;
		--selftest) selftest="yes"; shift ;;
		*)
			echo "redact: FAIL unknown argument '$1'." >&2
			echo "  Fix: run with --source, --out, --with-tool-output, --selftest, or -h." >&2
			echo "  After: re-run with a supported argument." >&2
			exit 2
			;;
	esac
done

cd "$repo_root"
out_dir="${out_dir:-$repo_root/.transcripts}"

# --- Preconditions ------------------------------------------------------------
for tool in jq gitleaks; do
	command -v "$tool" >/dev/null 2>&1 || fail \
		"the required tool '$tool' is not installed." \
		"install it, for example 'brew install $tool'. gitleaks is the layer that decides whether a run is safe, so this script does not run without it." \
		"re-run 'scripts/transcript.redact.sh' once '$tool' is on PATH."
done

# --- What counts as identity in this repository -------------------------------
# Derived rather than hard-coded, so a different clone or a different author
# redacts their own values instead of these.
home_path="$HOME"
git_email="$(git config user.email 2>/dev/null || true)"
# The distinctive part of the author's mail domain, redacted on its own as well
# as inside a full address. A transcript records the commands that ran, and a
# command that greps for an identity carries that identity as a bare word which
# no address pattern matches. Observed: three files held the domain this way
# after every address in them had been replaced.
email_domain_root=""
if [ -n "$git_email" ]; then
	email_domain_root="${git_email#*@}"
	email_domain_root="${email_domain_root%%.*}"
fi

# --- The redaction itself -----------------------------------------------------
# Applied to every string value anywhere in the record, by walking the parsed
# JSON rather than by rewriting raw text. Walking means a value is redacted
# wherever it appears, including inside nested tool arguments, and that the
# output is still valid JSON afterwards.
redact_stream() {
	local drop_output="$1"
	jq -c --arg home "$home_path" --arg email "$git_email" --arg edom "$email_domain_root" --argjson drop "$drop_output" '
		def scrub:
			if type == "string" then
				gsub("npm_[A-Za-z0-9]{20,}"; "<REDACTED-NPM-TOKEN>")
				| gsub("(?<u>[A-Za-z0-9._%+-]+)@(?<d>[A-Za-z0-9.-]+\\.[A-Za-z]{2,})"; "<REDACTED-EMAIL>")
				| gsub("gh[pousr]_[A-Za-z0-9]{20,}"; "<REDACTED-GITHUB-TOKEN>")
				| gsub("xox[baprs]-[A-Za-z0-9-]{10,}"; "<REDACTED-SLACK-TOKEN>")
				| gsub("sk_(live|test)_[A-Za-z0-9]{16,}"; "<REDACTED-STRIPE-KEY>")
				| gsub("sk-[A-Za-z0-9_-]{20,}"; "<REDACTED-API-KEY>")
				| gsub("Bearer\\s+[A-Za-z0-9._~+/-]{20,}"; "Bearer <REDACTED>")
				| gsub("eyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}"; "<REDACTED-JWT>")
				| gsub("AIza[A-Za-z0-9_-]{30,}"; "<REDACTED-GCP-KEY>")
				| gsub("SK[0-9a-fA-F]{32}"; "<REDACTED-TWILIO-KEY>")
				| gsub("pypi-[A-Za-z0-9_-]{16,}"; "<REDACTED-PYPI-TOKEN>")
				# Basic-auth credentials passed to curl. These are mostly this
				# stack own documented local Grafana default, which is public,
				# but the pattern is a credential pattern and a transcript from
				# another machine may carry a real one in the same position.
				# Note: no apostrophe appears in these character classes. The jq
				# program is wrapped in single quotes, so an apostrophe inside
				# it ends the shell string and the rest becomes syntax rather
				# than a pattern.
				| gsub("(?<f>-u\\s+)[^\\s\"]+:[^\\s\"]+"; "\(.f)<REDACTED-BASIC-AUTH>")
				| gsub("(?<s>https?://)[^\\s/:@\"]+:[^\\s/@\"]+@"; "\(.s)<REDACTED-BASIC-AUTH>@")
				| (if ($home | length) > 0 then gsub($home; "<HOME>") else . end)
				| (if ($email | length) > 0 then gsub($email; "<REDACTED-EMAIL>") else . end)
				| (if ($edom | length) > 2 then gsub($edom; "<REDACTED-IDENTITY>") else . end)
			else . end;
		# Tool output is dropped before the walk, so a large stdout is never
		# carried through the scrub only to be discarded.
		(if $drop and (.toolUseResult? | type) == "object" then
			.toolUseResult |= (
				(if has("stdout") then .stdout = "<TOOL-OUTPUT-DROPPED>" else . end)
				| (if has("stderr") then .stderr = "<TOOL-OUTPUT-DROPPED>" else . end)
				| (if has("content") then .content = "<TOOL-OUTPUT-DROPPED>" else . end)
				| (if has("originalFile") then .originalFile = "<TOOL-OUTPUT-DROPPED>" else . end)
			)
		else . end)
		| (if $drop then
			(.message?.content? |= (if type == "array" then
				map(if (.type? == "tool_result") then .content = "<TOOL-OUTPUT-DROPPED>" else . end)
			else . end))
		else . end)
		| walk(scrub)
	'
}

# --- The gate: gitleaks over what was produced --------------------------------
# Runs against the output rather than the input, because the question is not
# whether the transcript held a secret, it is whether the redacted copy still
# does.
gate() {
	local dir="$1" report
	report="$(mktemp)"
	if gitleaks detect --no-git --source "$dir" --report-format json --report-path "$report" --redact >/dev/null 2>&1; then
		rm -f "$report"
		return 0
	fi
	local n kept="$repo_root/.transcripts.gitleaks.json"
	n="$(jq 'length' "$report" 2>/dev/null || echo "unknown")"
	echo "redact: rules that still matched, by count:" >&2
	jq -r '[.[].RuleID] | group_by(.) | map("  \(length)x \(.[0])") | .[]' "$report" 2>/dev/null >&2
	# The report is kept even though the output is destroyed. Refusing without
	# saying what matched would leave an operator with nothing to act on, and
	# the report carries rule names and locations rather than secret values,
	# because gitleaks ran with --redact.
	mv "$report" "$kept" 2>/dev/null || rm -f "$report"
	rm -rf "$dir"
	fail "gitleaks found ${n} match(es) still present after redaction, so the output was removed." \
		"read ${kept#"$repo_root"/} for the rule and location of each. Add a rule to the scrub function for any real secret format, and add a gitleaks allowlist entry for any false positive, stating why in a comment. Do not disable the gate." \
		"re-run 'scripts/transcript.redact.sh' and confirm it reports zero findings."
}

# --- Selftest -----------------------------------------------------------------
# Plants a secret gitleaks recognises but the scrub function does not, and
# asserts the run is refused and the output removed. This makes the fail-closed
# behaviour observable rather than assumed.
run_selftest() {
	# Not local: the EXIT trap below runs after this function returns, where a
	# local would be out of scope and set -u would abort on it.
	tmp_out="$(mktemp -d)"
	trap 'rm -rf "$tmp_out"' EXIT

	# The selftest exercises the GATE directly rather than the whole pipeline.
	# An earlier version ran the full pipeline over a planted secret, which made
	# the test depend on the scrub function NOT knowing that format. That premise
	# expired every time a rule was added: a Slack token, then a Twilio key, each
	# stopped reaching the gate as soon as the scrub learned it, and the selftest
	# reported a failure that was really its own design. Worse, every candidate
	# value had to be written down somewhere, which put it into this repository
	# and from there into the transcripts the tool later scans, so the redactor
	# kept flagging its own test data.
	#
	# Testing the gate directly removes both problems. The question the selftest
	# must answer is narrow: when gitleaks finds something, does this script
	# refuse and remove the output? The scrub is irrelevant to that question.
	#
	# The value is generated at run time and never printed, so no fixed literal
	# enters the repository or any transcript.
	local secret
	# openssl terminates on its own. Reading /dev/urandom through head closes
	# the pipe on the reader, and pipefail turns that SIGPIPE into a failure.
	secret="pypi-AgEIcHlwaS5vcmc$(openssl rand -hex 30)"
	printf 'token %s\n' "$secret" >"$tmp_out/planted.txt"
	unset secret

	info "selftest: calling the gate on a directory that holds a secret, expecting refusal"
	local rc=0
	( gate "$tmp_out" ) >/dev/null 2>&1 || rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "the gate accepted a directory that contains a secret." \
			"check that gitleaks runs against the output directory and that its non-zero exit is honoured." \
			"re-run 'scripts/transcript.redact.sh --selftest' and confirm it reports the refusal."
	fi
	if [ -d "$tmp_out" ]; then
		fail "the gate refused but left the output directory in place." \
			"the gate must remove the output when it refuses, so a refused run cannot be mistaken for a safe one." \
			"re-run the selftest and confirm the directory is gone."
	fi
	pass "the gate refuses a directory holding a secret and removes it (negative test)."
	trap - EXIT
	exit 0
}

[ "$selftest" = "yes" ] && run_selftest

# --- Locate the transcripts ---------------------------------------------------
# Claude Code stores a session transcript under a directory named for the
# project path with the separators replaced. Derive it from this repository's
# path rather than hard-coding it, so a different clone finds its own sessions.
default_sources() {
	local base="$HOME/.claude/projects"
	local slug="${repo_root//\//-}"
	[ -d "$base" ] || return 0
	find "$base" -maxdepth 1 -type d -name "*${slug}*" 2>/dev/null
}

mapfile -t sources < <(if [ -n "$source_dir" ]; then echo "$source_dir"; else default_sources; fi)

[ "${#sources[@]}" -gt 0 ] || fail \
	"no transcript directory was found for this repository." \
	"pass --source DIR to name the directory holding the .jsonl session files." \
	"re-run with --source and confirm the file count it reports is not zero."

mapfile -t files < <(find "${sources[@]}" -name '*.jsonl' -type f 2>/dev/null | sort)

[ "${#files[@]}" -gt 0 ] || fail \
	"no .jsonl transcript files were found under: ${sources[*]}" \
	"confirm the directory holds session transcripts, or pass --source DIR to name another." \
	"re-run and confirm the file count it reports is not zero."

# --- Run ----------------------------------------------------------------------
rm -rf "$out_dir"
mkdir -p "$out_dir"

if [ "$keep_tool_output" = "yes" ]; then
	info "WARNING: --with-tool-output keeps tool stdout and stderr, which is where a secret is most likely to appear. The gate still runs, but it can only catch formats it recognises."
	drop_json="false"
else
	drop_json="true"
fi

info "redacting ${#files[@]} transcript file(s) into ${out_dir#"$repo_root"/}"
lines_in=0
for f in "${files[@]}"; do
	name="$(basename "$(dirname "$f")")__$(basename "$f")"
	if ! redact_stream "$drop_json" <"$f" >"$out_dir/$name" 2>/dev/null; then
		fail "a transcript could not be parsed as JSON lines: $f" \
			"confirm the file is a session transcript with one JSON object per line." \
			"re-run once the file parses, or pass --source to select a different directory."
	fi
	lines_in=$(( lines_in + $(wc -l <"$f") ))
done

info "scanning the redacted output with gitleaks $(gitleaks version 2>/dev/null || echo '')"
gate "$out_dir"

pass "${#files[@]} file(s), ${lines_in} records redacted into ${out_dir#"$repo_root"/}; gitleaks found nothing."
info "the folder is gitignored and is never committed. Remove it with: rm -rf ${out_dir#"$repo_root"/}"
