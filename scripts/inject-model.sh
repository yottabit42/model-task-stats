#!/usr/bin/env python3
"""Antigravity PreInvocation hook for model-task-stats (v1.3.0).

Reads transcript.jsonl (and any referenced subagent transcripts) to compute
exact token usage and date-aware retail API cost for both the current request
and the cumulative conversation session.
"""
import collections
import datetime
import json
import os
import re
import sys


SLUG_THINKING_RE = re.compile(r"^(.*?)-(xhigh|high|medium|low|minimal)$", re.IGNORECASE)
PAREN_MODEL_RE = re.compile(r"^(.*?)\s*\(([^)]+)\)$")
SETTINGS_CHANGE_RE = re.compile(
    r"changed setting `Model Selection` from .+? to ((?:[^\n.]|\.(?=\d))+)"
)
SUBAGENT_URI_RE = re.compile(r'"logAbsoluteUri":\s*"([^"]+)"')


def parse_model_selection(raw_value: str, default_thinking: str = "High"):
    """Normalizes a runtime modelName slug or UI selection string into (display_name, thinking_level)."""
    val = (raw_value or "").strip()
    if not val or val.lower() == "auto":
        return ("Gemini 4 Argon", default_thinking)

    paren = PAREN_MODEL_RE.match(val)
    if paren:
        return (paren.group(1).strip(), paren.group(2).strip())

    thinking = default_thinking
    base = val
    slug_m = SLUG_THINKING_RE.match(val)
    if slug_m:
        base = slug_m.group(1).strip()
        raw_t = slug_m.group(2).lower()
        thinking = "XHigh" if raw_t == "xhigh" else raw_t.capitalize()

    s = base.lower()
    if s in ("gemini-4-argon", "gemini 4 argon"):
        return ("Gemini 4 Argon", thinking)
    if s in ("gemini-4-carbon", "gemini 4 carbon"):
        return ("Gemini 4 Carbon", thinking)
    if s in ("gemini-4-hydrogen", "gemini 4 hydrogen"):
        return ("Gemini 4 Hydrogen", thinking)
    if s in ("gemini-pro-orchestrator", "orchestrator (carbon)"):
        return ("Orchestrator (Carbon)", thinking)
    if s in ("gemini-pro-orchestrator-argon", "orchestrator (argon)"):
        return ("Orchestrator (Argon)", thinking)

    m_flite = re.match(r"^gemini-(\d+(?:\.\d+)?)-flash[-_]lite$", s)
    if m_flite:
        return (f"Gemini {m_flite.group(1)} Flash-Lite", thinking)

    m_flash = re.match(r"^gemini-(\d+(?:\.\d+)?)-flash$", s)
    if m_flash:
        return (f"Gemini {m_flash.group(1)} Flash", thinking)

    m_claude = re.match(r"^claude-(opus|sonnet|haiku)-(\d+)-(\d+)$", s)
    if m_claude:
        tier = m_claude.group(1).capitalize()
        return (f"Claude {tier} {m_claude.group(2)}.{m_claude.group(3)}", thinking)

    m_gpt_oss = re.match(r"^gpt-oss-(\d+b)$", s)
    if m_gpt_oss:
        return (f"GPT-OSS {m_gpt_oss.group(1).upper()}", thinking)

    if any(ch.isupper() for ch in base):
        return (base, thinking)
    return (" ".join(part.capitalize() for part in base.split("-")), thinking)


def get_rates(model_label: str, date_str: str):
    """Returns (uncached_input_per_1m, cached_input_per_1m, output_per_1m) in USD."""
    m = model_label.lower()
    if "gpt-oss" in m:
        return (0.15, 0.075, 0.60)
    if "hydrogen" in m:
        return (1.50, 0.075, 7.50)
    if "claude" in m and "opus" in m:
        return (4.00, 0.20, 20.00)
    if "claude" in m and ("sonnet" in m or "haiku" in m):
        return (2.00, 0.10, 10.00)
    if "flash-lite" in m or "flash_lite" in m:
        return (0.30, 0.03, 2.50)
    if "flash" in m:
        # Introductory pricing through 2026-12-31
        if date_str <= "2026-12-31":
            return (0.75, 0.075, 3.75)
        return (1.50, 0.15, 7.50)
    # Default / Flagship (Gemini 4 Argon, Gemini 4 Carbon, Gemini Pro)
    # Introductory pricing through 2026-11-30
    if date_str <= "2026-11-30":
        return (2.00, 0.10, 10.00)
    return (4.00, 0.20, 20.00)


def compute_cost(in_tok: int, cache_tok: int, out_tok: int, model_label: str, date_str: str) -> float:
    r_in, r_cache, r_out = get_rates(model_label, date_str)
    return (in_tok * r_in + cache_tok * r_cache + out_tok * r_out) / 1_000_000.0


def parse_subagent_transcript(uri_or_path: str, sub_model_label: str, date_str: str) -> dict:
    path = uri_or_path.replace("file://", "")
    stats = {"tool_calls": 0, "responses": 0, "in": 0, "cache": 0, "out": 0, "cost": 0.0}
    if not os.path.isfile(path):
        return stats
    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                if not line.strip():
                    continue
                step = json.loads(line)
                if step.get("type") == "PLANNER_RESPONSE":
                    in_t = int(step.get("input_tokens", 0) or 0)
                    cache_t = int(step.get("cache_read_tokens", 0) or 0)
                    out_t = int(step.get("output_tokens", 0) or 0)
                    tcs = step.get("tool_calls") or []
                    stats["in"] += in_t
                    stats["cache"] += cache_t
                    stats["out"] += out_t
                    stats["tool_calls"] += len(tcs)
                    if not tcs and step.get("content"):
                        stats["responses"] += 1
        if stats["responses"] == 0 and (stats["in"] > 0 or stats["tool_calls"] > 0):
            stats["responses"] = 1
        stats["cost"] = compute_cost(stats["in"], stats["cache"], stats["out"], sub_model_label, date_str)
    except Exception:
        pass
    return stats


def main():
    raw = ""
    if not sys.stdin.isatty():
        try:
            raw = sys.stdin.read()
        except Exception:
            raw = ""

    hook_data = {}
    if raw.strip():
        try:
            hook_data = json.loads(raw)
        except Exception:
            hook_data = {}

    runtime_model = str(hook_data.get("modelName", "")).strip()
    transcript_path = str(hook_data.get("transcriptPath", "")).strip()
    today_str = datetime.date.today().isoformat()

    active_model, active_thinking = parse_model_selection(runtime_model, "High")

    if not transcript_path or not os.path.isfile(transcript_path):
        if runtime_model and runtime_model.lower() != "auto":
            msg = f'[Session Model Info: MainModel="{active_model}" Thinking="{active_thinking}"]'
            print(json.dumps({"injectSteps": [{"systemMessage": {"systemMessage": msg}}]}))
        else:
            print("{}")
        return

    steps = []
    try:
        with open(transcript_path, "r", encoding="utf-8") as f:
            for line in f:
                if line.strip():
                    steps.append(json.loads(line))
    except Exception:
        print("{}")
        return

    initial_model = active_model
    last_user_idx = 0
    for idx, st in enumerate(steps):
        if st.get("type") == "USER_INPUT":
            last_user_idx = idx
            content = st.get("content", "")
            m = SETTINGS_CHANGE_RE.search(content)
            if m:
                active_model, active_thinking = parse_model_selection(m.group(1), active_thinking)

    def summarize_slice(slice_steps, start_model):
        cur_model = start_model
        main_stats = {"tool_calls": 0, "responses": 0, "in": 0, "cache": 0, "out": 0, "cost": 0.0}
        subagents = {}
        pending_sub_models = collections.deque()
        seen_sub_uris = set()
        last_step_context = 0

        for st in slice_steps:
            if st.get("type") == "USER_INPUT":
                m = SETTINGS_CHANGE_RE.search(st.get("content", ""))
                if m:
                    cur_model, _ = parse_model_selection(m.group(1))
            elif st.get("type") == "PLANNER_RESPONSE":
                in_t = int(st.get("input_tokens", 0) or 0)
                cache_t = int(st.get("cache_read_tokens", 0) or 0)
                out_t = int(st.get("output_tokens", 0) or 0)
                if in_t + cache_t > 0:
                    last_step_context = in_t + cache_t
                tcs = st.get("tool_calls") or []
                main_stats["in"] += in_t
                main_stats["cache"] += cache_t
                main_stats["out"] += out_t
                main_stats["tool_calls"] += len(tcs)
                if not tcs and st.get("content"):
                    main_stats["responses"] += 1
                main_stats["cost"] += compute_cost(in_t, cache_t, out_t, cur_model, today_str)

                for tc in tcs:
                    if tc.get("name") == "invoke_subagent":
                        args = tc.get("args") or {}
                        mod_arg = str(args.get("Model", "inherit")).strip('"')
                        tname = str(args.get("TypeName", "")).strip('"')
                        if mod_arg == "flash" or tname.endswith("-flash"):
                            pending_sub_models.append("Gemini Flash (Subagent)")
                        elif mod_arg == "flash_lite" or "flash_lite" in tname or "flash-lite" in tname:
                            pending_sub_models.append("Gemini Flash-Lite (Subagent)")
                        elif mod_arg == "pro":
                            pending_sub_models.append("Gemini Pro (Subagent)")
                        else:
                            pending_sub_models.append(f"{cur_model} (Subagent)")
            elif st.get("type") == "GENERIC" and pending_sub_models:
                content = st.get("content", "")
                if "Created the following subagent:" in content or '"conversationId"' in content:
                    uri_m = SUBAGENT_URI_RE.search(content)
                    if uri_m:
                        sub_model = pending_sub_models.popleft()
                        uri = uri_m.group(1)
                        if uri not in seen_sub_uris:
                            seen_sub_uris.add(uri)
                            sub_s = parse_subagent_transcript(uri, sub_model, today_str)
                            if sub_model not in subagents:
                                subagents[sub_model] = {
                                    "tool_calls": 0,
                                    "responses": 0,
                                    "in": 0,
                                    "cache": 0,
                                    "out": 0,
                                    "cost": 0.0,
                                }
                            for k in subagents[sub_model]:
                                subagents[sub_model][k] += sub_s[k]

        return main_stats, subagents, last_step_context, cur_model

    prior_main, prior_subs, prior_ctx, model_after_prior = summarize_slice(
        steps[:last_user_idx], initial_model
    )
    req_main, req_subs, req_ctx, _ = summarize_slice(
        steps[last_user_idx:], model_after_prior
    )

    baseline_ctx = req_ctx if req_ctx > 0 else (prior_ctx if prior_ctx > 0 else 25000)
    est_final_step_cost = compute_cost(1500, baseline_ctx, 450, active_model, today_str)

    req_main_est_cost = req_main["cost"] + est_final_step_cost
    req_sub_cost = sum(v["cost"] for v in req_subs.values())
    req_total_est_cost = req_main_est_cost + req_sub_cost

    prior_sub_cost = sum(v["cost"] for v in prior_subs.values())
    prior_total_cost = prior_main["cost"] + prior_sub_cost
    prior_total_tc = prior_main["tool_calls"] + sum(v["tool_calls"] for v in prior_subs.values())
    prior_total_resp = prior_main["responses"] + sum(v["responses"] for v in prior_subs.values())

    session_est_cost = prior_total_cost + req_total_est_cost

    sub_parts = []
    for k, v in req_subs.items():
        tc_cnt = v["tool_calls"]
        resp_cnt = v["responses"]
        c_val = v["cost"]
        sub_parts.append(f"{k}: {tc_cnt} tool calls, {resp_cnt} resp, cost=${c_val:.4f}")
    sub_str = "; ".join(sub_parts) if sub_parts else "none"

    req_tc = req_main["tool_calls"]
    req_c_done = req_main["cost"]

    msg = (
        f"[Model Task & Cost Telemetry (Date={today_str}) | "
        f'MainModel="{active_model}" Thinking="{active_thinking}" | '
        f"CurrentRequestMain: tool_calls_so_far={req_tc}, "
        f"cost_completed_steps=${req_c_done:.4f}, "
        f"est_cost_including_this_final_response=${req_main_est_cost:.4f} | "
        f"CurrentRequestSubagents: {sub_str} | "
        f"CurrentRequestTotalEstCost=${req_total_est_cost:.4f} | "
        f"SessionPriorRequests: tool_calls={prior_total_tc}, responses={prior_total_resp}, cost=${prior_total_cost:.4f} | "
        f"SessionAggregateEstCost=${session_est_cost:.4f}]"
    )

    print(json.dumps({"injectSteps": [{"systemMessage": {"systemMessage": msg}}]}))


if __name__ == "__main__":
    main()
