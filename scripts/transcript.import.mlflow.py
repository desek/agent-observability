"""Write imported agent sessions into MLflow as browsable conversation traces.

@agents-index Reads the session summaries the transcript importer produced and writes each as one MLflow trace, a root conversation span with a turn span per exchange and a tool span beneath it, tagged so it is distinguishable from seeded data.

Purpose: the dashboard, the log view, and the trace view all populate from the
main importer, but the conversation view is MLflow's, and MLflow needs a client
rather than an OTLP push. That client is version-matched and resolved through uv,
the same way the demo seed resolves it, so this runs as a separate step rather
than inside the stdlib-only importer.

Why a separate file: the main importer deliberately depends on nothing outside
the standard library, so it runs anywhere python3 does. Bringing MLflow into it
would put a resolved dependency in the path of the metric, log, and trace write,
which is the part that must not fail for want of a package.

Shape of a written trace, mirroring what live conversation tracing produces:

  root    the conversation, carrying the session identifier and the model
  turn    one span per exchange, with the token counts and computed cost
  tool    one span per tool the turn used, with the call count

Every trace is tagged `session_import=true` and `git.org=session-import`, so it
is selectable and distinguishable from a seeded conversation at a glance.

Usage (invoked by scripts/transcript.import.sh, not directly):
  uv run --python 3.12 --with mlflow==3.14.0 python \
      scripts/transcript.import.mlflow.py SUMMARIES_JSON

Environment:
  MLFLOW_TRACKING_URI   The tracking server, through the single edge port.
"""

import json
import os
import sys

import mlflow

# How many conversations to write. The view is for browsing rather than for
# bulk, and every session already appears in the metric, log, and trace stores,
# so a handful of the richest sessions is the useful shape rather than all of
# them.
MAX_CONVERSATIONS = 8


def main():
    if len(sys.argv) < 2:
        print("import-mlflow: FAIL no summaries file was given.", file=sys.stderr)
        print("  Fix: this script is invoked by scripts/transcript.import.sh, which passes the path.", file=sys.stderr)
        print("  After: run 'scripts/transcript.import.sh' rather than this file directly.", file=sys.stderr)
        sys.exit(2)

    with open(sys.argv[1]) as fh:
        sessions = json.load(fh)

    # Richest first: a conversation with more turns shows more of the shape.
    sessions.sort(key=lambda s: (-s.get("turns", 0), s.get("id", "")))
    sessions = sessions[:MAX_CONVERSATIONS]

    mlflow.set_tracking_uri(os.environ["MLFLOW_TRACKING_URI"])
    mlflow.set_experiment("claude-code")

    written = 0
    for s in sessions:
        prompts = s.get("prompts") or []
        responses = s.get("responses") or []
        if not prompts and not responses:
            continue
        model = s.get("model") or "unknown"
        turns = max(1, min(len(prompts), len(responses)) or 1)
        # Cost and tokens are the session totals, so attribute a proportional
        # share to each turn rather than repeating the whole figure on each one.
        per_turn_cost = (s.get("cost") or 0.0) / turns
        per_turn_in = (s.get("input", 0) + s.get("cacheRead", 0)) // turns
        per_turn_out = (s.get("output", 0)) // turns
        tools = sorted((s.get("tools") or {}).items(), key=lambda kv: -kv[1])

        with mlflow.start_span(name="agent_conversation", span_type="AGENT") as root:
            root.set_inputs({"messages": [{"role": "user", "content": p} for p in prompts[:2]]})
            # session_id is a first-class parameter, not a tag. MLflow stores it
            # as the mlflow.trace.session metadata key, which is what the Sessions
            # view groups on. Writing it as a tag instead leaves that view empty,
            # which is how this importer originally left it.
            mlflow.update_current_trace(
                session_id=s.get("id") or None,
                tags={
                    "session_import": "true",
                    "git.org": "session-import",
                    "git.repo": s.get("repo") or "agent-observability",
                    "model": model,
                },
            )
            for idx in range(turns):
                prompt = prompts[idx] if idx < len(prompts) else ""
                response = responses[idx] if idx < len(responses) else ""
                with mlflow.start_span(name=f"assistant_turn_{idx + 1}", span_type="LLM") as turn:
                    turn.set_inputs({"prompt": prompt})
                    turn.set_attributes(
                        {
                            "model": model,
                            "tokens.input": per_turn_in,
                            "tokens.output": per_turn_out,
                            "cost_usd": round(per_turn_cost, 4),
                        }
                    )
                    # One tool span per turn, cycling through the tools the
                    # session actually used, so the nesting is visible.
                    if tools:
                        name, count = tools[idx % len(tools)]
                        with mlflow.start_span(name=name, span_type="TOOL") as tool:
                            tool.set_inputs({"tool": name})
                            tool.set_outputs({"calls_in_session": count})
                    turn.set_outputs({"response": response})

            # A subagent that ran in this session becomes its own span, because
            # that relationship exists nowhere else in the stack.
            for sub in (s.get("subagents") or [])[:3]:
                with mlflow.start_span(name=f"subagent:{sub['type']}", span_type="AGENT") as sp:
                    sp.set_inputs({"agent_type": sub["type"], "model": sub.get("model")})
                    sp.set_attributes(
                        {
                            "duration_s": round((sub.get("ms") or 0) / 1000.0, 1),
                            "tokens.total": sub.get("tokens") or 0,
                            "tool_uses": sub.get("tool_uses") or 0,
                        }
                    )
                    sp.set_outputs({"status": sub.get("status")})

            root.set_outputs(
                {"messages": [{"role": "assistant", "content": r} for r in responses[:2]]}
            )
        written += 1

    print(f"import-mlflow: wrote {written} conversation trace(s)")


if __name__ == "__main__":
    main()
