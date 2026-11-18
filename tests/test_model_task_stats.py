#!/usr/bin/env python3
"""Unit and integration tests for model-task-stats."""
import importlib.machinery
import importlib.util
import json
import os
import subprocess
import tempfile
import unittest

PLUGIN_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT_PATH = os.path.join(PLUGIN_DIR, "scripts", "inject-model.sh")
HOOKS_PATH = os.path.join(PLUGIN_DIR, "hooks.json")
PLUGIN_JSON_PATH = os.path.join(PLUGIN_DIR, "plugin.json")
AGENTS_MD_PATH = os.path.join(PLUGIN_DIR, "rules", "AGENTS.md")
SKILL_MD_PATH = os.path.join(PLUGIN_DIR, "skills", "model-task-stats", "SKILL.md")


def load_script_module():
    loader = importlib.machinery.SourceFileLoader("inject_model", SCRIPT_PATH)
    spec = importlib.util.spec_from_loader("inject_model", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


class TestModelTaskStats(unittest.TestCase):
    def test_manifest_hooks_and_skill_exist(self):
        with open(PLUGIN_JSON_PATH, encoding="utf-8") as f:
            pjson = json.load(f)
        self.assertEqual(pjson["version"], "1.4.0")

        with open(HOOKS_PATH, encoding="utf-8") as f:
            hjson = json.load(f)
        hook_cfg = hjson["model-task-stats"]
        self.assertNotIn("SessionStart", hook_cfg)
        self.assertEqual(hook_cfg["PreInvocation"][0]["command"], "./scripts/inject-model.sh")
        self.assertTrue(os.path.isfile(SKILL_MD_PATH))

    def test_rate_tiers_and_date_cutoffs(self):
        mod = load_script_module()
        self.assertEqual(mod.get_rates("Gemini 4 Neon", "2026-11-18"), (3.00, 0.15, 15.00))
        self.assertEqual(mod.get_rates("Orchestrator (Neon)", "2026-11-18"), (3.00, 0.15, 15.00))
        self.assertEqual(mod.get_rates("Gemini 4 Hydrogen", "2026-11-13"), (1.50, 0.075, 7.50))
        self.assertEqual(mod.get_rates("Gemini 4 Hydrogen", "2027-01-01"), (1.50, 0.075, 7.50))
        self.assertEqual(mod.get_rates("Orchestrator (Carbon)", "2026-11-30"), (2.00, 0.10, 10.00))
        self.assertEqual(mod.get_rates("Orchestrator (Carbon)", "2026-12-01"), (4.00, 0.20, 20.00))
        self.assertEqual(mod.get_rates("Orchestrator (Argon)", "2026-11-30"), (2.00, 0.10, 10.00))
        self.assertEqual(mod.get_rates("Orchestrator (Argon)", "2026-12-01"), (4.00, 0.20, 20.00))
        self.assertEqual(mod.get_rates("Gemini 4 Argon", "2026-11-30"), (2.00, 0.10, 10.00))
        self.assertEqual(mod.get_rates("Gemini 4 Argon", "2026-12-01"), (4.00, 0.20, 20.00))
        self.assertEqual(mod.get_rates("Gemini 4 Carbon", "2026-11-30"), (2.00, 0.10, 10.00))
        self.assertEqual(mod.get_rates("Gemini 4 Carbon", "2026-12-01"), (4.00, 0.20, 20.00))
        self.assertEqual(mod.get_rates("Gemini 3.8 Flash", "2026-12-31"), (0.75, 0.075, 3.75))
        self.assertEqual(mod.get_rates("Gemini 3.8 Flash", "2027-01-01"), (1.50, 0.15, 7.50))
        self.assertEqual(mod.get_rates("Gemini 3.5 Flash-Lite", "2027-05-01"), (0.30, 0.03, 2.50))
        self.assertEqual(mod.get_rates("Claude Opus 5.5", "2026-11-11"), (4.00, 0.20, 20.00))
        self.assertEqual(mod.get_rates("Claude Sonnet 5.5", "2026-11-11"), (2.00, 0.10, 10.00))
        self.assertEqual(mod.get_rates("GPT-OSS 120B", "2026-11-11"), (0.15, 0.075, 0.60))

    def test_slug_parsing_without_settings_change_banner(self):
        cases = [
            ("gemini-4-neon-low", 'MainModel="Gemini 4 Neon" Thinking="Low"'),
            ("gemini-4-neon-medium", 'MainModel="Gemini 4 Neon" Thinking="Medium"'),
            ("gemini-4-neon-high", 'MainModel="Gemini 4 Neon" Thinking="High"'),
            ("gemini-4-neon-xhigh", 'MainModel="Gemini 4 Neon" Thinking="XHigh"'),
            ("gemini-pro-orchestrator-neon", 'MainModel="Orchestrator (Neon)" Thinking="High"'),
            ("gemini-4-hydrogen-low", 'MainModel="Gemini 4 Hydrogen" Thinking="Low"'),
            ("gemini-4-hydrogen-medium", 'MainModel="Gemini 4 Hydrogen" Thinking="Medium"'),
            ("gemini-4-hydrogen-high", 'MainModel="Gemini 4 Hydrogen" Thinking="High"'),
            ("gemini-4-hydrogen-xhigh", 'MainModel="Gemini 4 Hydrogen" Thinking="XHigh"'),
            ("gemini-pro-orchestrator", 'MainModel="Orchestrator (Carbon)" Thinking="High"'),
            ("gemini-pro-orchestrator-argon", 'MainModel="Orchestrator (Argon)" Thinking="High"'),
            ("gemini-4-carbon-medium", 'MainModel="Gemini 4 Carbon" Thinking="Medium"'),
            ("gemini-4-argon-low", 'MainModel="Gemini 4 Argon" Thinking="Low"'),
            ("gemini-3.8-flash-high", 'MainModel="Gemini 3.8 Flash" Thinking="High"'),
            ("claude-opus-5-5-high", 'MainModel="Claude Opus 5.5" Thinking="High"'),
            ("claude-sonnet-5-5-low", 'MainModel="Claude Sonnet 5.5" Thinking="Low"'),
            ("gpt-oss-120b-medium", 'MainModel="GPT-OSS 120B" Thinking="Medium"'),
        ]
        with tempfile.TemporaryDirectory() as tmp:
            tpath = os.path.join(tmp, "transcript.jsonl")
            with open(tpath, "w", encoding="utf-8") as f:
                f.write(json.dumps({"type": "USER_INPUT", "content": "Hello"}) + "\n")

            for slug, expected in cases:
                payload = json.dumps({"modelName": slug, "transcriptPath": tpath})
                res = subprocess.run(
                    ["./scripts/inject-model.sh"],
                    cwd=PLUGIN_DIR,
                    input=payload,
                    text=True,
                    capture_output=True,
                    check=True,
                )
                out = json.loads(res.stdout)
                msg = out["injectSteps"][0]["systemMessage"]["systemMessage"]
                self.assertIn(expected, msg, f"Failed slug {slug}: got {msg}")

    def test_parallel_subagent_fifo_tracking(self):
        with tempfile.TemporaryDirectory() as tmp:
            sub1 = os.path.join(tmp, "sub1.jsonl")
            sub2 = os.path.join(tmp, "sub2.jsonl")
            main_t = os.path.join(tmp, "transcript.jsonl")

            with open(sub1, "w", encoding="utf-8") as f:
                f.write(json.dumps({
                    "type": "PLANNER_RESPONSE",
                    "input_tokens": 10000,
                    "cache_read_tokens": 20000,
                    "output_tokens": 1000,
                    "tool_calls": [{"name": "read_file"}, {"name": "read_file"}],
                }) + "\n")
                f.write(json.dumps({
                    "type": "PLANNER_RESPONSE",
                    "input_tokens": 2000,
                    "cache_read_tokens": 30000,
                    "output_tokens": 500,
                    "content": "Subagent 1 done",
                }) + "\n")

            with open(sub2, "w", encoding="utf-8") as f:
                f.write(json.dumps({
                    "type": "PLANNER_RESPONSE",
                    "input_tokens": 20000,
                    "cache_read_tokens": 0,
                    "output_tokens": 2000,
                    "tool_calls": [{"name": "read_file"}, {"name": "read_file"}, {"name": "read_file"}],
                }) + "\n")
                f.write(json.dumps({
                    "type": "PLANNER_RESPONSE",
                    "input_tokens": 5000,
                    "cache_read_tokens": 20000,
                    "output_tokens": 1000,
                    "content": "Subagent 2 done",
                }) + "\n")

            steps = [
                {"type": "USER_INPUT", "content": "Run parallel subagents"},
                {
                    "type": "PLANNER_RESPONSE",
                    "input_tokens": 10000,
                    "cache_read_tokens": 0,
                    "output_tokens": 500,
                    "tool_calls": [
                        {"name": "invoke_subagent", "args": {"TypeName": "research", "Model": "flash"}},
                        {"name": "invoke_subagent", "args": {"TypeName": "architect", "Model": "inherit"}},
                    ],
                },
                {
                    "type": "GENERIC",
                    "content": f'Created the following subagent:\n{{\n  "conversationId": "s1",\n  "logAbsoluteUri": "file://{sub1}"\n}}',
                },
                {
                    "type": "GENERIC",
                    "content": f'Created the following subagent:\n{{\n  "conversationId": "s2",\n  "logAbsoluteUri": "file://{sub2}"\n}}',
                },
            ]
            with open(main_t, "w", encoding="utf-8") as f:
                for st in steps:
                    f.write(json.dumps(st) + "\n")

            payload = json.dumps({"modelName": "gemini-4-hydrogen-medium", "transcriptPath": main_t})
            res = subprocess.run(
                ["./scripts/inject-model.sh"],
                cwd=PLUGIN_DIR,
                input=payload,
                text=True,
                capture_output=True,
                check=True,
            )
            msg = json.loads(res.stdout)["injectSteps"][0]["systemMessage"]["systemMessage"]
            self.assertIn("Gemini Flash (Subagent): 2 tool calls, 1 resp", msg)
            self.assertIn("Gemini 4 Hydrogen (Subagent): 3 tool calls, 1 resp", msg)

    def test_rules_agents_md_documents_all_models(self):
        with open(AGENTS_MD_PATH, encoding="utf-8") as f:
            txt = f.read()
        for model_name in [
            "Gemini 4 Neon",
            "Gemini 4 Hydrogen",
            "Gemini 4 Argon",
            "Gemini 4 Carbon",
            "Orchestrator (Neon)",
            "Orchestrator (Carbon)",
            "Orchestrator (Argon)",
            "Claude Opus 5.5",
            "Claude Sonnet 5.5",
            "GPT-OSS 120B",
            "XHigh",
        ]:
            self.assertIn(model_name, txt)


if __name__ == "__main__":
    unittest.main()
