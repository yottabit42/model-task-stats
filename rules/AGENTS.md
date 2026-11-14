# Per-Request Model, Thinking Level & Retail Token Cost Summary Rule

At the very end of every completed user request (after all tool calls, subagent invocations, and final synthesis for that request are finished), you MUST append a 4-column Markdown summary table reporting the models used, their thinking levels, tasks performed, and approximate retail token cost (plus `**Request Total**` and `**Session Aggregate**` rows).

## 1. When to Include the Summary Table
- **Include**: At the bottom of the final response that completes a user request (including after multi-turn interactive flows such as `/grill-me` or `ask_question` once the final answer or implementation for the request is delivered).
- **Do NOT include**: Inside intermediate `ask_question` tool calls or while pausing mid-request only to wait for a clarifying question answer. Wait until the request or design/implementation turn finishes, or include it at the end of a standalone conversational response.

## 2. How to Count "Tasks Performed"
- Count **every tool invocation** (`read_file`, `edit_file`, `write_file`, `run_command`, `ask_question`, `invoke_subagent`, `search_web`, MCP tools, etc.) executed during the current request as **1 tool call**.
- Count the **final response synthesis** delivered for the request as **1 response**.
- Format the `Tasks Performed` column as:
  `<Total> (<N> tool calls, <M> response)` (using singular `tool call` / `response` when `1`, and `responses` when `> 1`).
  - Example with 4 tool calls and 1 final response: `5 (4 tool calls, 1 response)`
  - Example for a pure Q&A turn with 0 tool calls: `1 (0 tool calls, 1 response)`
- For the `**Session Aggregate**` row, add the current request's tasks (`tool calls` and `responses`) to the `SessionPriorRequests` counts injected by `[Model Task & Cost Telemetry ...]`.

## 3. How to Identify Models and Thinking Levels
- **Model Name**:
  1. Use the human-readable model name from `<USER_SETTINGS_CHANGE>` or `MainModel` in `[Model Task & Cost Telemetry ...]` (e.g., `Gemini 4 Hydrogen`, `Gemini 4 Carbon`, `Gemini 4 Argon`, `Orchestrator (Carbon)`, `Orchestrator (Argon)`, `Gemini 3.8 Flash`, `Claude Opus 5.5`, `Claude Sonnet 5.5`, `GPT-OSS 120B`).
  2. For subagents dispatched via `invoke_subagent`, label the model by its resolved tier/name (e.g., `Gemini Flash *(Subagent)*` when `Model: "flash"` or `TypeName: "*-flash"`, `Gemini Flash-Lite *(Subagent)*` for `flash_lite`, `Gemini Pro *(Subagent)*` for `pro`, or `<Main Model> *(Subagent)*` for `inherit`).
- **Thinking Level**:
  - Read `EFFORT LEVEL: <value>` from your system instructions (and/or `Thinking` in `[Model Task & Cost Telemetry ...]` / `<USER_SETTINGS_CHANGE>`) and format as:
    - `XHigh` (when `Thinking="XHigh"` or `EFFORT LEVEL` is extra-high) -> ``XHigh (`<EFFORT_LEVEL>`)``
    - `1.00` -> ``High (`1.00`)``
    - `0.50` -> ``Medium (`0.50`)``
    - `0.25` -> ``Low (`0.25`)``
    - `0.00` -> ``Minimal (`0.00`)``
    - Any other value `<X>` -> ``Custom (`<X>`)``

## 4. How to Calculate Approximate Retail Token Cost (`Est. Retail Cost`)
- **Primary Source (`PreInvocation` Hook Telemetry)**:
  - Use `est_cost_including_this_final_response`, `CurrentRequestTotalEstCost`, and `SessionAggregateEstCost` injected by `[Model Task & Cost Telemetry ...]`.
- **Fallback Formula (if hook telemetry is unavailable for a step)**:
  - Apply standard retail API Paid Tier pricing (with cached-input discount):
    - **Gemini 4 Hydrogen**:
      - `\$1.50 / 1M` uncached input · `\$0.075 / 1M` cached input · `\$7.50 / 1M` output (incl. thinking)
    - **Gemini 4 Argon, Gemini 4 Carbon, Orchestrator (Argon), Orchestrator (Carbon)**:
      - Through `2026-11-30`: `\$2.00 / 1M` uncached input · `\$0.10 / 1M` cached input · `\$10.00 / 1M` output (incl. thinking)
      - Starting `2026-12-01`: `\$4.00 / 1M` uncached input · `\$0.20 / 1M` cached input · `\$20.00 / 1M` output (incl. thinking)
    - **Gemini 3.8 / 3.6 Flash**:
      - Through `2026-12-31`: `\$0.75 / 1M` uncached input · `\$0.075 / 1M` cached input · `\$3.75 / 1M` output
      - Starting `2027-01-01`: `\$1.50 / 1M` uncached input · `\$0.15 / 1M` cached input · `\$7.50 / 1M` output
    - **Gemini 3.5 Flash-Lite**:
      - `\$0.30 / 1M` uncached input · `\$0.03 / 1M` cached input · `\$2.50 / 1M` output
    - **Claude Opus 5.5**:
      - `\$4.00 / 1M` uncached input · `\$0.20 / 1M` cached input · `\$20.00 / 1M` output
    - **Claude Sonnet 5.5**:
      - `\$2.00 / 1M` uncached input · `\$0.10 / 1M` cached input · `\$10.00 / 1M` output
    - **GPT-OSS 120B**:
      - `\$0.15 / 1M` uncached input · `\$0.075 / 1M` cached input · `\$0.60 / 1M` output
- **Formatting Rule**:
  - Format dollar amounts to 4 decimal places prefixed with `~\$` (e.g., `~\$0.0842`). Always escape the dollar sign as `\$` in Markdown so KaTeX does not interpret multiple dollar signs as inline math.

## 5. Subagent Self-Reporting Contract
- If you are running as a **subagent**, do not render the full Markdown table; instead, append a single line at the very end of your final reply to the parent agent:
  `[Subagent Stats: Model=<model_or_tier> | Thinking=<Level (EFFORT_LEVEL)> | ToolCalls=<N> | Responses=1 | EstCost=~$X.XXXX]`

## 6. Required 4-Column Markdown Table Format

```markdown
---

| Model | Thinking Level | Tasks Performed | Est. Retail Cost |
| :--- | :--- | :--- | :--- |
| <Model Name> | <Level> (`<EFFORT_LEVEL>`) | <Total> (<N> tool calls, <M> response) | ~\$<X.XXXX> |
| **Request Total** | — | **<ReqTotal> (<ReqTC> tool calls, <ReqResp> response)** | **~\$<ReqCost>** |
| **Session Aggregate** | — | **<SessTotal> (<SessTC> tool calls, <SessResp> responses)** | **~\$<SessCost>** |
```
