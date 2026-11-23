#!/usr/bin/env python3
"""Antigravity PreInvocation hook for model-task-stats (v1.6.0).

Reads transcript.jsonl, referenced subagent transcripts, and /swarm worker
transcripts (including Claude, GPT-OSS, and Gemini models) to compute exact
token usage and date-aware retail API cost for the current request, per-model
session aggregates, and the cumulative conversation session.
"""
import collections
import datetime
import json
import os
import re
import sys


SLUG_THINKING_RE = re.compile(r"^(.*?)-(xhigh|high|medium|low|minimal)$", re.IGNORECASE)
PAREN_MODEL_RE = re.compile(r"^(.*?)\s*\((xhigh|high|medium|low|minimal)\)$", re.IGNORECASE)
SETTINGS_CHANGE_RE = re.compile(
    r"changed setting `Model Selection` from .+? to ((?:[^\n.]|\.(?=\d))+)"
)
SUBAGENT_URI_RE = re.compile(r'"logAbsoluteUri":\s*"([^"]+)"')


def _empty_stats():
    return {"tool_calls": 0, "responses": 0, "in": 0, "cache": 0, "out": 0, "cost": 0.0}


def _add_stats(dest, src):
    for k in dest:
        dest[k] += src[k]


def _normalize_thinking(raw_t: str) -> str:
    t = raw_t.strip().lower()
    return "XHigh" if t == "xhigh" else t.capitalize()


def parse_model_selection(raw_value: str, default_thinking: str = "High"):
    """Normalizes a runtime modelName slug or UI selection string into (display_name, thinking_level)."""
    val = (raw_value or "").strip()
    if not val or val.lower() == "auto":
        return ("Gemini 4 Argon", default_thinking)

    paren = PAREN_MODEL_RE.match(val)
    if paren:
        return (paren.group(1).strip(), _normalize_thinking(paren.group(2)))

    thinking = default_thinking
    base = val
    slug_m = SLUG_THINKING_RE.match(val)
    if slug_m:
        base = slug_m.group(1).strip()
        thinking = _normalize_thinking(slug_m.group(2))

    s = base.lower()
    if s in ("gemini-4-argon", "gemini 4 argon"):
        return ("Gemini 4 Argon", thinking)
    if s in ("gemini-4-carbon", "gemini 4 carbon"):
        return ("Gemini 4 Carbon", thinking)
    if s in ("gemini-4-hydrogen", "gemini 4 hydrogen"):
        return ("Gemini 4 Hydrogen", thinking)
    if s in ("gemini-4-neon", "gemini 4 neon"):
        return ("Gemini 4 Neon", thinking)
    if s in ("gemini-pro-orchestrator", "orchestrator (carbon)"):
        return ("Orchestrator (Carbon)", thinking)
    if s in ("gemini-pro-orchestrator-argon", "orchestrator (argon)"):
        return ("Orchestrator (Argon)", thinking)
    if s in ("gemini-pro-orchestrator-neon", "orchestrator (neon)"):
        return ("Orchestrator (Neon)", thinking)
    if s.startswith("gemini-flash-worker"):
        return ("Gemini Flash", thinking)

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
    if "neon" in m:
        return (3.00, 0.15, 15.00)
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
    # Default / Flagship (Gemini 4 Argon, Gemini 4 Carbon, Orchestrator)
    # Introductory pricing through 2026-11-30
    if date_str <= "2026-11-30":
        return (2.00, 0.10, 10.00)
    return (4.00, 0.20, 20.00)


def compute_cost(in_tok: int, cache_tok: int, out_tok: int, model_label: str, date_str: str) -> float:
    r_in, r_cache, r_out = get_rates(model_label, date_str)
    return (in_tok * r_in + cache_tok * r_cache + out_tok * r_out) / 1_000_000.0


def _with_suffix(label: str, suffix: str) -> str:
    if not suffix or label.endswith(suffix):
        return label
    return f"{label} {suffix}"


def parse_child_transcript(uri_or_path: str, default_model_label: str, date_str: str, label_suffix: str) -> dict:
    """Parses a subagent or swarm worker transcript, attributing each PLANNER_RESPONSE by its per-step model."""
    path = uri_or_path.replace("file://", "")
    by_model = {}
    if not os.path.isfile(path):
        return by_model
    last_label = None
    total_resp = 0
    total_activity = 0
    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                if not line.strip():
                    continue
                step = json.loads(line)
                if step.get("type") == "PLANNER_RESPONSE":
                    raw_step_model = str(step.get("model") or "").strip()
                    if raw_step_model and raw_step_model.lower() != "auto":
                        step_model_name, _ = parse_model_selection(raw_step_model)
                        label = _with_suffix(step_model_name, label_suffix)
                    else:
                        label = _with_suffix(default_model_label, label_suffix)
                    in_t = int(step.get("input_tokens", 0) or 0)
                    cache_t = int(step.get("cache_read_tokens", 0) or 0)
                    out_t = int(step.get("output_tokens", 0) or 0)
                    tcs = step.get("tool_calls") or []
                    is_resp = 1 if (not tcs and step.get("content")) else 0
                    step_stats = {
                        "tool_calls": len(tcs),
                        "responses": is_resp,
                        "in": in_t,
                        "cache": cache_t,
                        "out": out_t,
                        "cost": compute_cost(in_t, cache_t, out_t, label, date_str),
                    }
                    _add_stats(by_model.setdefault(label, _empty_stats()), step_stats)
                    last_label = label
                    total_resp += is_resp
                    total_activity += in_t + len(tcs)
        if total_resp == 0 and total_activity > 0 and last_label:
            by_model[last_label]["responses"] += 1
    except Exception:
        pass
    return by_model


def discover_swarm_workers(transcript_path: str, fallback_model: str, date_str: str, seen_paths: set) -> dict:
    """Discovers /swarm workers from .system_generated/swarm/members.json and parses their transcripts."""
    swarm_by_model = {}
    abs_t = os.path.abspath(transcript_path)
    logs_dir = os.path.dirname(abs_t)
    sysgen_dir = os.path.dirname(logs_dir)
    if os.path.basename(logs_dir) != "logs" or os.path.basename(sysgen_dir) != ".system_generated":
        return swarm_by_model

    conv_dir = os.path.dirname(sysgen_dir)
    brain_root = os.path.dirname(conv_dir)
    root_conv_id = os.path.basename(conv_dir)

    queue = collections.deque([root_conv_id])
    seen_conv_ids = {root_conv_id}

    while queue:
        cid = queue.popleft()
        members_path = os.path.join(brain_root, cid, ".system_generated", "swarm", "members.json")
        if not os.path.isfile(members_path):
            continue
        try:
            with open(members_path, "r", encoding="utf-8") as f:
                data = json.load(f)
        except Exception:
            continue

        members = data.get("members") or {}
        if not isinstance(members, dict):
            continue
        for member in members.values():
            if not isinstance(member, dict):
                continue
            w_cid = str(member.get("conversation_id") or "").strip()
            if not w_cid or w_cid in seen_conv_ids or member.get("role") == "coordinator":
                continue
            seen_conv_ids.add(w_cid)
            queue.append(w_cid)

            w_transcript = os.path.join(brain_root, w_cid, ".system_generated", "logs", "transcript.jsonl")
            if w_transcript in seen_paths:
                continue
            seen_paths.add(w_transcript)

            raw_w_model = str(member.get("applied_model") or member.get("desired_model") or fallback_model)
            w_model_name, _ = parse_model_selection(raw_w_model)
            worker_stats = parse_child_transcript(w_transcript, w_model_name, date_str, "(Swarm)")
            for k, v in worker_stats.items():
                _add_stats(swarm_by_model.setdefault(k, _empty_stats()), v)

    return swarm_by_model


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

    seen_child_paths = {os.path.abspath(transcript_path)}

    def summarize_slice(slice_steps, start_model):
        cur_model = start_model
        main_stats = _empty_stats()
        main_by_model = {}
        subagents = {}
        pending_sub_models = collections.deque()
        last_step_context = 0

        for st in slice_steps:
            if st.get("type") == "USER_INPUT":
                m = SETTINGS_CHANGE_RE.search(st.get("content", ""))
                if m:
                    cur_model, _ = parse_model_selection(m.group(1))
            elif st.get("type") == "PLANNER_RESPONSE":
                raw_step_model = str(st.get("model") or "").strip()
                if raw_step_model and raw_step_model.lower() != "auto":
                    step_model, _ = parse_model_selection(raw_step_model)
                else:
                    step_model = cur_model
                in_t = int(st.get("input_tokens", 0) or 0)
                cache_t = int(st.get("cache_read_tokens", 0) or 0)
                out_t = int(st.get("output_tokens", 0) or 0)
                if in_t + cache_t > 0:
                    last_step_context = in_t + cache_t
                tcs = st.get("tool_calls") or []
                is_resp = 1 if (not tcs and st.get("content")) else 0
                step_cost = compute_cost(in_t, cache_t, out_t, step_model, today_str)
                step_stats = {
                    "tool_calls": len(tcs),
                    "responses": is_resp,
                    "in": in_t,
                    "cache": cache_t,
                    "out": out_t,
                    "cost": step_cost,
                }
                _add_stats(main_stats, step_stats)
                _add_stats(main_by_model.setdefault(step_model, _empty_stats()), step_stats)

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
                        abs_sub = os.path.abspath(uri.replace("file://", ""))
                        if abs_sub not in seen_child_paths:
                            seen_child_paths.add(abs_sub)
                            sub_by_m = parse_child_transcript(uri, sub_model, today_str, "(Subagent)")
                            for k, v in sub_by_m.items():
                                _add_stats(subagents.setdefault(k, _empty_stats()), v)

        return main_stats, main_by_model, subagents, last_step_context, cur_model

    prior_main, prior_main_by_model, prior_subs, prior_ctx, model_after_prior = summarize_slice(
        steps[:last_user_idx], initial_model
    )
    req_main, req_main_by_model, req_subs, req_ctx, _ = summarize_slice(
        steps[last_user_idx:], model_after_prior
    )

    swarm_by_model = discover_swarm_workers(transcript_path, active_model, today_str, seen_child_paths)

    baseline_ctx = req_ctx if req_ctx > 0 else (prior_ctx if prior_ctx > 0 else 25000)
    est_final_step_cost = compute_cost(1500, baseline_ctx, 450, active_model, today_str)

    req_main_est_cost = req_main["cost"] + est_final_step_cost
    req_sub_cost = sum(v["cost"] for v in req_subs.values())
    req_total_est_cost = req_main_est_cost + req_sub_cost

    prior_sub_cost = sum(v["cost"] for v in prior_subs.values())
    prior_total_cost = prior_main["cost"] + prior_sub_cost
    prior_total_tc = prior_main["tool_calls"] + sum(v["tool_calls"] for v in prior_subs.values())
    prior_total_resp = prior_main["responses"] + sum(v["responses"] for v in prior_subs.values())

    swarm_total_cost = sum(v["cost"] for v in swarm_by_model.values())
    session_est_cost = prior_total_cost + req_total_est_cost + swarm_total_cost

    session_by_model = {}
    for source in (prior_main_by_model, prior_subs, req_main_by_model, req_subs, swarm_by_model):
        for k, v in source.items():
            _add_stats(session_by_model.setdefault(k, _empty_stats()), v)
    active_sess = session_by_model.setdefault(active_model, _empty_stats())
    active_sess["responses"] += 1
    active_sess["cost"] += est_final_step_cost

    sess_total_tc = sum(v["tool_calls"] for v in session_by_model.values())
    sess_total_resp = sum(v["responses"] for v in session_by_model.values())

    def _fmt_map(m: dict) -> str:
        if not m:
            return "none"
        return "; ".join(
            f"{k}: {v['tool_calls']} tool calls, {v['responses']} resp, cost=${v['cost']:.4f}"
            for k, v in m.items()
        )

    sub_str = _fmt_map(req_subs)
    swarm_str = _fmt_map(swarm_by_model)
    sess_model_str = _fmt_map(session_by_model)

    req_tc = req_main["tool_calls"]
    req_c_done = req_main["cost"]

    msg = (
        f"[Model Task & Cost Telemetry (Date={today_str}) | "
        f'MainModel="{active_model}" Thinking="{active_thinking}" | '
        f"CurrentRequestMain: tool_calls_so_far={req_tc}, "
        f"cost_completed_steps=${req_c_done:.4f}, "
        f"est_cost_including_this_final_response=${req_main_est_cost:.4f} | "
        f"CurrentRequestSubagents: {sub_str} | "
        f"SwarmWorkers: {swarm_str} | "
        f"CurrentRequestTotalEstCost=${req_total_est_cost:.4f} | "
        f"SessionPriorRequests: tool_calls={prior_total_tc}, responses={prior_total_resp}, cost=${prior_total_cost:.4f} | "
        f"SessionAggregateByModel: {sess_model_str} | "
        f"SessionAggregateTotals: tool_calls={sess_total_tc}, responses={sess_total_resp} | "
        f"SessionAggregateEstCost=${session_est_cost:.4f}]"
    )

    print(json.dumps({"injectSteps": [{"systemMessage": {"systemMessage": msg}}]}))


if __name__ == "__main__":
    main()
