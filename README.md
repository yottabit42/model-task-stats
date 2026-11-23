# model-task-stats

An Antigravity (`agy`) plugin and skill that automatically tracks per-request and session-aggregate token usage, thinking levels, tool/response counts, and estimated retail API costs, appending a 4-column Markdown summary table to the end of every completed response.

## How It Works

`model-task-stats` combines three Antigravity customization primitives:

1. **Lifecycle Hook (`hooks.json` + `scripts/inject-model.sh`)**
   - Registers a `PreInvocation` command hook (`./scripts/inject-model.sh`) that runs before each model call.
   - Reads the active conversation's `transcript.jsonl` (provided via `transcriptPath` on `stdin`), splits it at the most recent `USER_INPUT` into **prior session requests** and the **current request**, and walks `PLANNER_RESPONSE` steps using each step's recorded `"model"` (accurately capturing `Orchestrator` per-step routing such as `gemini-pro-orchestrator-neon` vs. `gemini-flash-worker-agy`) to sum `input_tokens`, `cache_read_tokens`, `output_tokens`, tool calls, and responses.
   - Tracks `invoke_subagent` calls in a FIFO queue (`collections.deque`) matched to `logAbsoluteUri` subagent transcripts, and discovers `/swarm` workers (including non-Gemini models like `Claude Opus 5.5`, `Claude Sonnet 5.5`, and `GPT-OSS 120B`, as well as nested helper workers and mid-run model switches) from `.system_generated/swarm/members.json`.
   - Resolves the active model and thinking level from `<USER_SETTINGS_CHANGE>` banners or the runtime `modelName` slug (e.g. `gemini-4-hydrogen-medium`, `gemini-4-hydrogen-xhigh`, `claude-opus-5-5-high`, `gemini-pro-orchestrator`).
   - Computes date-aware retail API costs (including upcoming December 2026 / January 2027 rate transitions), aggregates cumulative per-model totals across the session (`SessionAggregateByModel`), and injects a `[Model Task & Cost Telemetry ...]` `<SYSTEM_MESSAGE>` into the prompt context.

2. **Always-On Rule (`rules/AGENTS.md`)**
   - Loaded automatically when the plugin is active.
   - Instructs the main agent to append a 4-column Markdown summary table (`Model | Thinking Level | Tasks Performed | Est. Retail Cost`, with **Request Total**, per-model `*<Model Name> (Session)*` aggregates, and **Session Aggregate** rows) at the end of every completed user request, using the injected hook telemetry (or the documented fallback rate table if telemetry is unavailable).
   - Instructs subagents to append a compact single-line `[Subagent Stats: ...]` footer instead of a full table.

3. **On-Demand Skill (`skills/model-task-stats/SKILL.md`)**
   - Provides quick-reference installation, rate-table, and troubleshooting instructions when invoked or referenced.

---

## Supported Models & Retail Pricing (per 1M Tokens)

| Model | Uncached Input | Cached Input | Output (incl. thinking) |
| :--- | :--- | :--- | :--- |
| **Gemini 4 Neon, Orchestrator (Neon)** | `$3.00` | `$0.15` | `$15.00` |
| **Gemini 4 Hydrogen** | `$1.50` | `$0.075` | `$7.50` |
| **Gemini 4 Argon, Gemini 4 Carbon, Orchestrator (Argon / Carbon)** *(through 2026-11-30)* | `$2.00` | `$0.10` | `$10.00` |
| **Gemini 4 Argon, Gemini 4 Carbon, Orchestrator (Argon / Carbon)** *(starting 2026-12-01)* | `$4.00` | `$0.20` | `$20.00` |
| **Gemini 3.8 / 3.6 Flash** *(through 2026-12-31)* | `$0.75` | `$0.075` | `$3.75` |
| **Gemini 3.8 / 3.6 Flash** *(starting 2027-01-01)* | `$1.50` | `$0.15` | `$7.50` |
| **Gemini 3.5 Flash-Lite** | `$0.30` | `$0.03` | `$2.50` |
| **Claude Opus 5.5** | `$4.00` | `$0.20` | `$20.00` |
| **Claude Sonnet 5.5** | `$2.00` | `$0.10` | `$10.00` |
| **GPT-OSS 120B** | `$0.15` | `$0.075` | `$0.60` |

---

## Installation

### Option 1: Install as a Global Antigravity Plugin (Recommended)

Clone this repository directly into your global Antigravity plugins directory (`~/.gemini/config/plugins/model-task-stats`):

```bash
git clone https://github.com/yottabit42/model-task-stats.git \
  "$HOME/.gemini/config/plugins/model-task-stats"
chmod +x "$HOME/.gemini/config/plugins/model-task-stats/scripts/inject-model.sh"
agy plugin validate "$HOME/.gemini/config/plugins/model-task-stats" --strict
```

### Option 2: Install as a Workspace-Scoped Plugin

To share the plugin with a specific repository/team:

```bash
git clone https://github.com/yottabit42/model-task-stats.git \
  ".agents/plugins/model-task-stats"
chmod +x ".agents/plugins/model-task-stats/scripts/inject-model.sh"
```

### Option 3: Install Only the Skill

If you only want the `model-task-stats` skill (without the automatic `PreInvocation` hook and always-on rule):

```bash
mkdir -p "$HOME/.gemini/config/skills/model-task-stats"
curl -fsSL https://raw.githubusercontent.com/yottabit42/model-task-stats/main/skills/model-task-stats/SKILL.md \
  -o "$HOME/.gemini/config/skills/model-task-stats/SKILL.md"
```

> **Note:** `PreInvocation` hooks take effect immediately, while `rules/AGENTS.md` is loaded at session start—start a new Antigravity conversation after installing.

---

## Verification

Run the included unit and integration test suite:

```bash
python3 "$HOME/.gemini/config/plugins/model-task-stats/tests/test_model_task_stats.py" -v
```
