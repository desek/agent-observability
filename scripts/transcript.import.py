"""Import redacted coding-agent session transcripts into the running stack.

@agents-index Reads the redacted transcripts under .transcripts/ and writes them
into Mimir, Loki, Tempo, and MLflow through the single edge port, compressing the
real timeline into the window every backend accepts and computing cost from a
pinned price table rather than inventing a rate.

Purpose: a transcript is the only complete record of what an agent actually did,
and it holds detail the live telemetry never captured, most notably the per
subagent breakdown of duration, tokens, and tool calls. This turns that record
into the same signals the live agents emit, so the dashboard, the log view, the
trace view, and the conversation view all populate from work that really
happened rather than from invented values.

What it reads and what it derives:

  tokens        message.usage, split into the four types the dashboard groups by
  cost          computed: tokens times the per-model rate in stack/pricing
  sessions      one series per distinct sessionId
  active time   the span from a session's first record to its last
  tools         tool_use blocks, counted by name; tool_result.is_error for the
                failure count
  lines         structuredPatch oldLines and newLines on Edit and Write results
  commits       Bash commands that invoke git commit
  subagents     the Agent tool result carries agentType, resolvedModel, status,
                totalDurationMs, totalTokens, and totalToolUseCount

Three constraints shape the timeline, each measured against this stack rather
than assumed (see the iteration ledger under docs/cr):

  Loki   refuses an entry older than about two hours, governed by max_chunk_age.
  Mimir  accepts far more, but a span under twelve hours is served from the
         ingester and so is visible immediately rather than after the bucket
         store synchronises.
  Tempo  does not surface a back-dated trace at all, so spans are written at the
         present moment while keeping their real durations.

The real span is therefore compressed linearly onto a window ending now. The
shape of the activity survives; the absolute times do not.

Cost is computed, never invented. A transcript records tokens and a model but no
price, so the rate comes from stack/pricing/claude.json, extracted from the
LiteLLM price table. A model with no entry contributes no cost and is reported,
rather than being priced by guesswork.

Usage:
  scripts/transcript.import.sh                Import every redacted transcript.
  scripts/transcript.import.sh --span 5400    Compress onto this many seconds.
  scripts/transcript.import.sh --dry-run      Report what would be written.

Environment:
  EDGE_PORT   Loopback host port the edge proxy publishes.
"""

import argparse
import glob
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

# --- Constants ---------------------------------------------------------------
# The marker stamped on every series and stream this importer writes. Distinct
# from the demo seed's marker because the data is different in kind: the seed is
# invented, this is real work with identity and secrets removed. Anything that
# decides what is safe to publish must be able to tell the two apart.
IMPORT_ORG = "session-import"
SERVICE_NAME = "claude-code"
NS = "claude_code"
DEFAULT_SPAN_SECONDS = 5400  # one and a half hours; see the timeline note above


def fail(what, fix, after):
    print(f"import: FAIL {what}", file=sys.stderr)
    print(f"  Fix: {fix}", file=sys.stderr)
    print(f"  After: {after}", file=sys.stderr)
    sys.exit(1)


def info(msg):
    print(f"import: {msg}")


def load_pricing(repo_root):
    """Return {model: {input, output, cache_read, cache_write}} in dollars per token."""
    path = os.path.join(repo_root, "stack", "pricing", "claude.json")
    if not os.path.exists(path):
        fail(
            f"the price table is missing at {path}.",
            "restore stack/pricing/claude.json, which is extracted from the LiteLLM "
            "price table. Cost is computed from it rather than invented, so the import "
            "does not run without it.",
            "re-run once the file is present.",
        )
    with open(path) as fh:
        return json.load(fh)


def read_records(transcript_dir):
    """Yield every parsed record from every redacted transcript."""
    files = sorted(glob.glob(os.path.join(transcript_dir, "*.jsonl")))
    if not files:
        fail(
            f"no redacted transcripts were found under {transcript_dir}.",
            "run 'scripts/transcript.redact.sh' first. This importer reads only the "
            "redacted copies, never the originals, so that identity and secrets are "
            "removed before anything reaches the stack.",
            "re-run 'scripts/transcript.import.sh' once .transcripts holds files.",
        )
    for path in files:
        with open(path) as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    yield json.loads(line)
                except json.JSONDecodeError:
                    continue
    return


def parse_ts(value):
    """ISO 8601 with a trailing Z to epoch seconds; None when unparseable."""
    if not isinstance(value, str):
        return None
    try:
        return time.mktime(time.strptime(value[:19], "%Y-%m-%dT%H:%M:%S")) - time.timezone
    except (ValueError, OverflowError):
        return None


GIT_COMMIT_RE = re.compile(r"\bgit\s+commit\b")
PR_RE = re.compile(r"\bgh\s+pr\s+create\b")


def build_sessions(records):
    """Fold the record stream into one summary per session.

    Returns {session_id: summary}. Each summary carries the token totals, the
    model, the first and last timestamp, the tool counts, the failure count, the
    line counts, the commit and pull-request counts, and the subagent list.
    """
    sessions = {}
    for rec in records:
        sid = rec.get("sessionId")
        if not sid:
            continue
        s = sessions.setdefault(
            sid,
            {
                "id": sid,
                "model": None,
                "branch": rec.get("gitBranch") or "main",
                "first": None,
                "last": None,
                "input": 0,
                "output": 0,
                "cacheRead": 0,
                "cacheCreation": 0,
                "turns": 0,
                "tools": {},
                "tool_errors": 0,
                "tool_ok": 0,
                "lines_added": 0,
                "lines_removed": 0,
                "commits": 0,
                "prs": 0,
                "subagents": [],
                "prompts": [],
                "responses": [],
            },
        )

        ts = parse_ts(rec.get("timestamp"))
        if ts is not None:
            s["first"] = ts if s["first"] is None else min(s["first"], ts)
            s["last"] = ts if s["last"] is None else max(s["last"], ts)

        if rec.get("type") == "assistant":
            s["turns"] += 1
            msg = rec.get("message") or {}
            s["model"] = msg.get("model") or s["model"]
            usage = msg.get("usage") or {}
            s["input"] += usage.get("input_tokens") or 0
            s["output"] += usage.get("output_tokens") or 0
            s["cacheRead"] += usage.get("cache_read_input_tokens") or 0
            s["cacheCreation"] += usage.get("cache_creation_input_tokens") or 0
            for block in msg.get("content") or []:
                if not isinstance(block, dict):
                    continue
                if block.get("type") == "tool_use":
                    name = block.get("name") or "unknown"
                    s["tools"][name] = s["tools"].get(name, 0) + 1
                    cmd = (block.get("input") or {}).get("command")
                    if isinstance(cmd, str):
                        if GIT_COMMIT_RE.search(cmd):
                            s["commits"] += 1
                        if PR_RE.search(cmd):
                            s["prs"] += 1
                elif block.get("type") == "text" and len(s["responses"]) < 4:
                    text = (block.get("text") or "").strip()
                    if text:
                        s["responses"].append(text[:400])

        if rec.get("type") == "user":
            msg = rec.get("message") or {}
            content = msg.get("content")
            if isinstance(content, str) and content.strip() and len(s["prompts"]) < 4:
                s["prompts"].append(content.strip()[:400])
            for block in content if isinstance(content, list) else []:
                if not isinstance(block, dict):
                    continue
                if block.get("type") == "tool_result":
                    if block.get("is_error") is True:
                        s["tool_errors"] += 1
                    elif block.get("is_error") is False:
                        s["tool_ok"] += 1
                elif block.get("type") == "text" and len(s["prompts"]) < 4:
                    text = (block.get("text") or "").strip()
                    if text:
                        s["prompts"].append(text[:400])

        result = rec.get("toolUseResult")
        if isinstance(result, dict):
            for patch in result.get("structuredPatch") or []:
                if isinstance(patch, dict):
                    s["lines_removed"] += patch.get("oldLines") or 0
                    s["lines_added"] += patch.get("newLines") or 0
            if result.get("agentId"):
                s["subagents"].append(
                    {
                        "type": result.get("agentType") or "unknown",
                        "model": result.get("resolvedModel") or "unknown",
                        "status": result.get("status") or "unknown",
                        "ms": result.get("totalDurationMs") or 0,
                        "tokens": result.get("totalTokens") or 0,
                        "tool_uses": result.get("totalToolUseCount") or 0,
                    }
                )

    return sessions


def session_cost(summary, pricing, unpriced):
    """Dollars for one session, computed from the pinned rate table."""
    model = summary["model"]
    rate = pricing.get(model)
    if rate is None:
        if model:
            unpriced.add(model)
        return 0.0
    return (
        summary["input"] * rate["input"]
        + summary["output"] * rate["output"]
        + summary["cacheRead"] * rate["cache_read"]
        + summary["cacheCreation"] * rate["cache_write"]
    )


def compress(value, real_lo, real_hi, out_lo, out_hi):
    """Map a real timestamp linearly onto the output window."""
    if real_hi <= real_lo:
        return out_hi
    frac = (value - real_lo) / (real_hi - real_lo)
    return out_lo + frac * (out_hi - out_lo)


# --- OTLP emission -----------------------------------------------------------
def resource_attrs(repo, branch):
    return [
        {"key": "service.name", "value": {"stringValue": SERVICE_NAME}},
        {"key": "git.org", "value": {"stringValue": IMPORT_ORG}},
        {"key": "git.repo", "value": {"stringValue": repo}},
        {"key": "git.branch", "value": {"stringValue": branch}},
        {"key": "git.path", "value": {"stringValue": f"/{repo}"}},
    ]


def post(base_url, path, payload, dry_run):
    if dry_run:
        return 200
    data = json.dumps(payload).encode()
    req = urllib.request.Request(
        base_url + path, data=data, headers={"Content-Type": "application/json"}
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status
    except urllib.error.HTTPError as exc:
        return exc.code
    except urllib.error.URLError as exc:
        fail(
            f"the stack did not answer at {base_url}{path} ({exc.reason}).",
            "start the stack with 'scripts/stack.up.sh' and confirm it is healthy "
            "with 'scripts/stack.verify.sh'.",
            "re-run 'scripts/transcript.import.sh' once the stack answers.",
        )


def metric(name, kind, value, attrs, ts_ns):
    point = {kind: value, "timeUnixNano": str(ts_ns), "startTimeUnixNano": str(ts_ns)}
    if attrs:
        point["attributes"] = attrs
    return {
        "name": name,
        "sum": {
            "aggregationTemporality": 2,
            "isMonotonic": True,
            "dataPoints": [point],
        },
    }


def attr(key, value):
    return {"key": key, "value": {"stringValue": str(value)}}


def emit_metrics(base_url, summary, cost, ts_ns, repo, dry_run):
    """Write every metric family the dashboard reads, plus the subagent series."""
    sid = attr("session.id", summary["id"])
    # The live Claude Code exporter stamps the model on the token metric, and the
    # dashboard's stat panels filter on it. A session-level metric emitted without
    # it is silently excluded whenever the model variable resolves to a concrete
    # list, which reads as a zero rather than as a missing label.
    mdl = attr("model", summary["model"] or "unknown")
    metrics = [
        metric(f"{NS}.session.count", "asInt", 1, [sid], ts_ns),
        metric(
            f"{NS}.cost.usage.USD",
            "asDouble",
            round(cost, 6),
            [attr("model", summary["model"] or "unknown"), sid],
            ts_ns,
        ),
        metric(
            f"{NS}.active_time.seconds",
            "asDouble",
            max(0.0, (summary["last"] or 0) - (summary["first"] or 0)),
            [mdl, sid],
            ts_ns,
        ),
        metric(f"{NS}.commit.count", "asInt", summary["commits"], [sid], ts_ns),
        metric(f"{NS}.pull_request.count", "asInt", summary["prs"], [sid], ts_ns),
    ]
    for kind in ("input", "output", "cacheRead", "cacheCreation"):
        metrics.append(
            metric(
                f"{NS}.token.usage.tokens",
                "asInt",
                summary[kind],
                [attr("type", kind), mdl, sid],
                ts_ns,
            )
        )
    for label, key in (("added", "lines_added"), ("removed", "lines_removed")):
        metrics.append(
            metric(
                f"{NS}.lines_of_code.count",
                "asInt",
                summary[key],
                [attr("type", label), sid],
                ts_ns,
            )
        )
    # The transcript records whether a tool call succeeded, which is the closest
    # honest analogue of the live accept/reject decision metric.
    for label, key in (("accept", "tool_ok"), ("reject", "tool_errors")):
        metrics.append(
            metric(
                f"{NS}.code_edit_tool.decision",
                "asInt",
                summary[key],
                [attr("decision", label), sid],
                ts_ns,
            )
        )
    # Per-subagent series. Nothing in the live telemetry carries this, which is
    # the single largest thing the transcripts add.
    by_type = {}
    for sub in summary["subagents"]:
        agg = by_type.setdefault(sub["type"], {"ms": 0, "tokens": 0, "tool_uses": 0, "n": 0})
        agg["ms"] += sub["ms"]
        agg["tokens"] += sub["tokens"]
        agg["tool_uses"] += sub["tool_uses"]
        agg["n"] += 1
    for agent_type, agg in by_type.items():
        a = [attr("agent_type", agent_type), sid]
        metrics.extend(
            [
                metric(f"{NS}.subagent.count", "asInt", agg["n"], a, ts_ns),
                metric(
                    f"{NS}.subagent.duration.seconds",
                    "asDouble",
                    round(agg["ms"] / 1000.0, 3),
                    a,
                    ts_ns,
                ),
                metric(f"{NS}.subagent.token.usage.tokens", "asInt", agg["tokens"], a, ts_ns),
                metric(f"{NS}.subagent.tool_use.count", "asInt", agg["tool_uses"], a, ts_ns),
            ]
        )
    for name, count in summary["tools"].items():
        metrics.append(
            metric(
                f"{NS}.tool.use.count",
                "asInt",
                count,
                [attr("tool", name), sid],
                ts_ns,
            )
        )

    payload = {
        "resourceMetrics": [
            {
                "resource": {"attributes": resource_attrs(repo, summary["branch"])},
                "scopeMetrics": [{"metrics": metrics}],
            }
        ]
    }
    return post(base_url, "/v1/metrics", payload, dry_run)


def emit_logs(base_url, summary, cost, ts_ns, repo, dry_run):
    """Write readable one-line events in the same shape the live pipeline produces."""
    records = []

    def line(body, attrs):
        records.append(
            {
                "timeUnixNano": str(ts_ns),
                "observedTimeUnixNano": str(ts_ns),
                "body": {"stringValue": body},
                "severityText": "INFO",
                "attributes": [attr(k, v) for k, v in attrs.items()],
            }
        )

    for prompt in summary["prompts"][:2]:
        line(f"[user_prompt] {prompt}", {"event.name": f"{NS}.user_prompt", "session.id": summary["id"]})
    for response in summary["responses"][:2]:
        line(
            f"[assistant_response] {response}",
            {"event.name": f"{NS}.assistant_response", "session.id": summary["id"]},
        )
    line(
        f"[api_request] model={summary['model']} input={summary['input']} "
        f"output={summary['output']} cacheRead={summary['cacheRead']} cost_usd={cost:.4f}",
        {"event.name": f"{NS}.api_request", "session.id": summary["id"]},
    )
    for name, count in sorted(summary["tools"].items(), key=lambda kv: -kv[1])[:6]:
        line(
            f"[tool_decision] tool={name} calls={count}",
            {"event.name": f"{NS}.tool_decision", "session.id": summary["id"], "tool": name},
        )
    for sub in summary["subagents"][:4]:
        line(
            f"[subagent] type={sub['type']} status={sub['status']} "
            f"duration_s={sub['ms'] / 1000:.1f} tokens={sub['tokens']} tools={sub['tool_uses']}",
            {"event.name": f"{NS}.subagent", "session.id": summary["id"], "agent_type": sub["type"]},
        )
    if summary["tool_errors"]:
        records.append(
            {
                "timeUnixNano": str(ts_ns),
                "observedTimeUnixNano": str(ts_ns),
                "body": {"stringValue": f"[tool_error] {summary['tool_errors']} tool call(s) failed"},
                "severityText": "ERROR",
                "attributes": [attr("event.name", f"{NS}.tool_error"), attr("session.id", summary["id"])],
            }
        )

    payload = {
        "resourceLogs": [
            {
                "resource": {"attributes": resource_attrs(repo, summary["branch"])},
                "scopeLogs": [{"logRecords": records}],
            }
        ]
    }
    return post(base_url, "/v1/logs", payload, dry_run)


def hexid(seed, width):
    """Deterministic hex identifier of the given width, derived from a seed string."""
    value = 0
    for ch in seed:
        value = (value * 131 + ord(ch)) & ((1 << 128) - 1)
    return f"{value:0{width}x}"[:width]


def emit_trace(base_url, summary, repo, dry_run):
    """One trace per session: a root span with a child per tool, plus subagents.

    Written at the present moment rather than at the session's own time, because
    Tempo accepts a back-dated trace and then never surfaces it.
    """
    now_ns = int(time.time() * 1_000_000_000)
    trace_id = hexid("t" + summary["id"], 32)
    root_id = hexid("r" + summary["id"], 16)
    real_ms = max(1, int(((summary["last"] or 0) - (summary["first"] or 0)) * 1000))
    span_ns = min(real_ms, 600_000) * 1_000_000  # cap the drawn span at ten minutes
    spans = [
        {
            "traceId": trace_id,
            "spanId": root_id,
            "name": "claude_code.session",
            "kind": 1,
            "startTimeUnixNano": str(now_ns - span_ns),
            "endTimeUnixNano": str(now_ns),
            "attributes": [
                attr("session.id", summary["id"]),
                attr("model", summary["model"] or "unknown"),
                attr("turns", summary["turns"]),
            ],
        }
    ]
    offset = span_ns
    for idx, (name, count) in enumerate(sorted(summary["tools"].items(), key=lambda kv: -kv[1])[:8]):
        child_ns = max(1_000_000, span_ns // 12)
        start = now_ns - offset + idx * (child_ns // 2)
        spans.append(
            {
                "traceId": trace_id,
                "spanId": hexid(f"c{summary['id']}{name}", 16),
                "parentSpanId": root_id,
                "name": f"claude_code.tool.{name}",
                "kind": 1,
                "startTimeUnixNano": str(start),
                "endTimeUnixNano": str(start + child_ns),
                "attributes": [attr("tool", name), attr("calls", count)],
            }
        )
    for idx, sub in enumerate(summary["subagents"][:6]):
        child_ns = max(1_000_000, min(sub["ms"], 120_000) * 1_000_000)
        start = now_ns - span_ns + idx * (child_ns // 3)
        spans.append(
            {
                "traceId": trace_id,
                "spanId": hexid(f"s{summary['id']}{sub['type']}{idx}", 16),
                "parentSpanId": root_id,
                "name": f"claude_code.subagent.{sub['type']}",
                "kind": 1,
                "startTimeUnixNano": str(start),
                "endTimeUnixNano": str(start + child_ns),
                "attributes": [
                    attr("agent_type", sub["type"]),
                    attr("agent_model", sub["model"]),
                    attr("status", sub["status"]),
                    attr("tokens", sub["tokens"]),
                    attr("tool_uses", sub["tool_uses"]),
                ],
            }
        )

    payload = {
        "resourceSpans": [
            {
                "resource": {"attributes": resource_attrs(repo, summary["branch"])},
                "scopeSpans": [{"spans": spans}],
            }
        ]
    }
    return post(base_url, "/v1/traces", payload, dry_run)


def main():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--span", type=int, default=DEFAULT_SPAN_SECONDS)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--transcripts", default=None)
    parser.add_argument("--repo-root", default=None)
    # Written for the MLflow step, which runs under a resolved client rather
    # than in this stdlib-only process. See transcript.import.mlflow.py.
    parser.add_argument("--summaries-out", default=None)
    args = parser.parse_args()

    repo_root = args.repo_root or os.getcwd()
    transcript_dir = args.transcripts or os.path.join(repo_root, ".transcripts")
    edge_port = os.environ.get("EDGE_PORT", "24317")
    base_url = f"http://127.0.0.1:{edge_port}"
    repo_name = os.path.basename(repo_root)

    pricing = load_pricing(repo_root)
    info(f"reading redacted transcripts from {os.path.relpath(transcript_dir, repo_root)}")
    sessions = build_sessions(read_records(transcript_dir))
    sessions = {k: v for k, v in sessions.items() if v["first"] is not None}
    if not sessions:
        fail(
            "the transcripts held no timestamped sessions.",
            "confirm .transcripts holds redacted session files with a sessionId and a timestamp.",
            "re-run once the redaction output is populated.",
        )

    real_lo = min(s["first"] for s in sessions.values())
    real_hi = max(s["last"] or s["first"] for s in sessions.values())
    now = time.time()
    out_hi = now - 60
    out_lo = out_hi - args.span
    real_hours = (real_hi - real_lo) / 3600.0

    unpriced = set()
    total_cost = 0.0
    ordered = sorted(sessions.values(), key=lambda s: s["first"])
    info(
        f"{len(ordered)} session(s) spanning {real_hours:.1f}h of real time, "
        f"compressed onto the last {args.span / 3600:.1f}h"
    )
    if args.dry_run:
        info("dry run: nothing will be written")

    written = 0
    for summary in ordered:
        cost = session_cost(summary, pricing, unpriced)
        total_cost += cost
        ts = compress(summary["first"], real_lo, real_hi, out_lo, out_hi)
        ts_ns = int(ts * 1_000_000_000)
        for label, code in (
            ("metrics", emit_metrics(base_url, summary, cost, ts_ns, repo_name, args.dry_run)),
            ("logs", emit_logs(base_url, summary, cost, ts_ns, repo_name, args.dry_run)),
        ):
            if code != 200:
                fail(
                    f"the OTLP {label} endpoint returned {code} for session {summary['id'][:8]}.",
                    "confirm the stack is healthy with 'scripts/stack.verify.sh' and that "
                    f"port {edge_port} reaches /v1/{label}.",
                    "re-run 'scripts/transcript.import.sh' once the endpoint answers 200.",
                )
        emit_trace(base_url, summary, repo_name, args.dry_run)
        written += 1

    if args.summaries_out:
        payload = []
        for s in ordered:
            row = dict(s)
            row["cost"] = session_cost(s, pricing, set())
            row["repo"] = repo_name
            payload.append(row)
        with open(args.summaries_out, "w") as fh:
            json.dump(payload, fh)

    subagent_total = sum(len(s["subagents"]) for s in ordered)
    tool_total = sum(sum(s["tools"].values()) for s in ordered)
    info(
        f"wrote {written} session(s): {tool_total} tool calls, {subagent_total} subagents, "
        f"${total_cost:.2f} computed cost"
    )
    if unpriced:
        info(
            "no price entry for: " + ", ".join(sorted(unpriced)) +
            " — those sessions contributed no cost rather than a guessed one"
        )
    print(f"import: PASS marker git_org={IMPORT_ORG}")


if __name__ == "__main__":
    main()
