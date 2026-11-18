---
name: model-task-stats
description: "Use when installing, verifying, troubleshooting, or customizing per-request model, thinking-level, and retail token cost reporting in Antigravity, or when calculating run costs without active hook telemetry."
---

# Model Task & Cost Stats (`model-task-stats`)

## Overview

Provides per-request and session-aggregate token cost and task-count visibility in Antigravity (`agy`) via:
1. **`PreInvocation` hook** (`hooks.json` + `scripts/inject-model.sh`) — reads `transcript.jsonl` and any spawned subagent transcripts, computes date-aware retail API costs, and injects a `[Model Task & Cost Telemetry ...]` system message before each model call.
2. **Always-on rule** (`rules/AGENTS.md`) — instructs the agent to append a 4-column Markdown summary table (`Model | Thinking Level | Tasks Performed | Est. Retail Cost`, plus **Request Total** and **Session Aggregate**) at the end of every completed user request.

## Installation (Global Plugin)

Clone or install into `~/.gemini/config/plugins/model-task-stats/` and ensure `scripts/inject-model.sh` is executable:

```bash
git clone https://github.com/yottabit42/model-task-stats.git \
  "$HOME/.gemini/config/plugins/model-task-stats"
chmod +x "$HOME/.gemini/config/plugins/model-task-stats/scripts/inject-model.sh"
agy plugin validate "$HOME/.gemini/config/plugins/model-task-stats"
```

Start a new Antigravity session so `rules/AGENTS.md` is loaded into the active rule set.

## Supported Models & Retail Rates (per 1M Tokens)

| Model | Uncached Input | Cached Input | Output (incl. thinking) |
| :--- | :--- | :--- | :--- |
| **Gemini 4 Neon / Orchestrator (Neon)** | `$3.00` | `$0.15` | `$15.00` |
| **Gemini 4 Hydrogen** | `$1.50` | `$0.075` | `$7.50` |
| **Gemini 4 Argon / Carbon / Orchestrator** *(through 2026-11-30)* | `$2.00` | `$0.10` | `$10.00` |
| **Gemini 4 Argon / Carbon / Orchestrator** *(from 2026-12-01)* | `$4.00` | `$0.20` | `$20.00` |
| **Gemini 3.8 / 3.6 Flash** *(through 2026-12-31)* | `$0.75` | `$0.075` | `$3.75` |
| **Gemini 3.8 / 3.6 Flash** *(from 2027-01-01)* | `$1.50` | `$0.15` | `$7.50` |
| **Gemini 3.5 Flash-Lite** | `$0.30` | `$0.03` | `$2.50` |
| **Claude Opus 5.5** | `$4.00` | `$0.20` | `$20.00` |
| **Claude Sonnet 5.5** | `$2.00` | `$0.10` | `$10.00` |
| **GPT-OSS 120B** | `$0.15` | `$0.075` | `$0.60` |

## Troubleshooting

- **No telemetry injected**: Run `agy plugin list` and verify `model-task-stats` is enabled and `scripts/inject-model.sh` has `+x` permissions.
- **Model shows raw slug or wrong tier**: Check `parse_model_selection()` and `get_rates()` in `scripts/inject-model.sh` for the incoming `modelName` slug.
- **Formatting breaks KaTeX**: Always escape dollar signs in Markdown tables as `~\$0.0123` so multiple `$` characters in a paragraph are not parsed as inline math.
