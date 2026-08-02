<!-- Purpose: the document a reader opens when the stack does not behave. One table,
     one row per observed symptom, each naming the cause and the fix, so a reader
     matches what they see rather than reading a narrative to find their case.
     @agents-index: Troubleshooting document: one row per symptom with its cause and its fix, covering port conflicts, empty panels, temporality, settings precedence, the pi endpoint default, and the tracing enable script. -->

# Troubleshooting

[Back to the front page](../README.md)

| Symptom | Cause | Fix |
|---------|-------|-----|
| The stack fails to start and the log names a port already in use. | Another program holds the edge port `24317`. | Copy `.env.example` to `.env`, set `EDGE_PORT` to a free port, and run `docker compose up -d` again. |
| The stack runs but every panel is empty. | No sender has exported yet, so the stores hold nothing. | Run `./scripts/demo.seed.sh` to populate every view, or wire an agent and drive one turn. |
| Logs arrive but the metric panels stay empty. | The metrics exporter is sending cumulative-versus-delta temporality the store rejects. | Set `OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=cumulative` on the sender and restart it; the install skill lists this key as required. |
| An agent is configured but nothing appears. | A settings `env` block outranks the shell, or the endpoint points elsewhere. | Confirm the settings file sets `OTEL_EXPORTER_OTLP_ENDPOINT` to the edge port, or pass `--settings` on the command line; then drive one turn. |
| The pi extension sends nothing to this stack. | The package defaults its OTLP endpoint to the standard port 4317, not the edge port. | Set `OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:24317` before launching pi. |
| The tracing enable script refuses the client. | It found an MLflow client below version 3.14, which lacks the plugin runtime that produces traces. | Upgrade the client to 3.14 or later, or point the script at a newer one, then enable again. |
| The tracing enable script reports no client. | No MLflow client and no Python tool runner is on the path. | Install an MLflow client, or a runner such as `uv`, then run the enable step again. |

When the stack itself is the suspect rather than one sender, run the outside-in
check, which names the first thing that is wrong:

```bash
./scripts/stack.verify.sh
```

## Next

* [Install](install.md), the start and verify commands.
* [Architecture](architecture.md), what each service answers.
