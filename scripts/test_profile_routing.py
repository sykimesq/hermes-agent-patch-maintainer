#!/usr/bin/env python3
"""
Integration test: delegate_task with agent profile routing.

Verifies that each subagent in a batch uses its designated profile's
model, NOT the parent's model or the base delegation config.

Usage:
    python test_profile_routing.py

Exit code: 0 = all passed, 1 = any failed
"""
import json
import sys
import unittest
from unittest.mock import MagicMock, patch

# ── Hermes repo path ──────────────────────────────────────────────────────
HERMES_REPO = r"C:\Users\sykim\AppData\Local\hermes\hermes-agent"
if HERMES_REPO not in sys.path:
    sys.path.insert(0, HERMES_REPO)


class TestLiveProfileRouting(unittest.TestCase):
    """Verify that delegate_task routes each subagent to its profile's model."""

    PARENT_MODEL = "anthropic/claude-sonnet-4"
    PARENT_PROVIDER = "openrouter"

    PROFILES = {
        "mira": {"provider": "openrouter", "model": "nvidia/nemotron-3-super-120b-a12b:free"},
        "rumi": {"provider": "openrouter", "model": "poolside/laguna-xs-2.1:free"},
        "zoe":  {"provider": "openrouter", "model": "cohere/north-mini-code:free"},
    }

    def setUp(self):
        from tools.delegate_tool import _resolve_delegation_credentials

        self.parent = MagicMock()
        self.parent.base_url = "https://openrouter.ai/api/v1"
        self.parent.api_key = "sk-or-v1-xxx"
        self.parent.provider = self.PARENT_PROVIDER
        self.parent.api_mode = "chat_completions"
        self.parent.model = self.PARENT_MODEL
        self.parent.platform = "cli"
        self.parent.providers_allowed = None
        self.parent.providers_ignored = None
        self.parent.providers_order = None
        self.parent.provider_sort = None
        self.parent._session_db = None
        self.parent._delegate_depth = 0
        self.parent._delegate_spinner = None
        self.parent._active_children = []
        self.parent._active_children_lock = None
        self.parent._memory_manager = None
        self.parent.session_estimated_cost_usd = 0.0
        self.parent.session_cost_source = "none"
        self.parent.session_cost_status = "unknown"
        self.parent._print_fn = None
        self.parent._current_turn_id = "test-turn"
        self.parent.session_id = "parent-session-id"
        self.parent._fallback_chain = None
        self.parent.reasoning_config = None
        self.parent.max_tokens = None
        self.parent.acp_command = None
        self.parent.acp_args = None
        self.parent.request_overrides = None
        self.parent.openrouter_min_coding_score = None
        self.parent.provider_require_parameters = False
        self.parent.provider_data_collection = ""
        self.parent.enabled_toolsets = None
        self.parent.valid_tool_names = ["terminal", "file", "web_search", "read_file", "write_file", "patch", "search_files", "browser_navigate", "delegate_task"]
        self.parent.tool_progress_callback = None
        self.parent._subagent_id = None
        self.parent._delegate_saved_tool_names = []

        # Capture what model each child was built with
        self.child_models = []

    def _capture_child_build(self, **kwargs):
        """Mock _build_child_agent: record model, return a mock child."""
        self.child_models.append({
            "task_index": kwargs.get("task_index"),
            "goal": kwargs.get("goal"),
            "model": kwargs.get("model"),
            "provider": kwargs.get("override_provider"),
        })
        child = MagicMock()
        child.session_id = f"child-{kwargs.get('task_index', 0)}"
        child._delegate_saved_tool_names = []
        child._delegate_role = kwargs.get("role", "leaf")
        child.tool_progress_callback = None
        child._live_transcript_path = None
        return child

    def test_three_profiles_use_correct_models(self):
        """Batch with mira/rumi/zoe: each child must use its profile's model."""
        from tools.delegate_tool import delegate_task

        self.child_models.clear()

        # Mock _resolve_delegation_credentials to return per-profile models
        # based on the profile parameter it receives.
        profile_model_map = {
            "mira": "nvidia/nemotron-3-super-120b-a12b:free",
            "rumi": "poolside/laguna-xs-2.1:free",
            "zoe":  "cohere/north-mini-code:free",
        }

        def _mock_resolve(cfg, parent_agent, profile=None):
            model = profile_model_map.get(profile, self.PARENT_MODEL)
            return {
                "model": model,
                "provider": "openrouter",
                "base_url": "https://openrouter.ai/api/v1",
                "api_key": "sk-or-v1-xxx",
                "api_mode": "chat_completions",
                "request_overrides": None,
                "max_output_tokens": None,
                "command": None,
                "args": [],
            }

        with patch("tools.delegate_tool._build_child_agent", self._capture_child_build):
            with patch("tools.delegate_tool._load_config") as mock_cfg:
                mock_cfg.return_value = {
                    "agent_profiles": self.PROFILES,
                }
                with patch("tools.delegate_tool._resolve_delegation_credentials", _mock_resolve):
                    with patch("tools.delegate_tool._run_single_child") as mock_run:
                        mock_run.side_effect = [
                            {"task_index": 0, "status": "completed", "summary": "Plan done", "api_calls": 1, "duration_seconds": 1.0},
                            {"task_index": 1, "status": "completed", "summary": "Impl done", "api_calls": 1, "duration_seconds": 1.0},
                            {"task_index": 2, "status": "completed", "summary": "Verify done", "api_calls": 1, "duration_seconds": 1.0},
                        ]
                        result = json.loads(delegate_task(
                            tasks=[
                                {"goal": "Plan the approach", "agent": "mira"},
                                {"goal": "Implement the plan", "agent": "rumi"},
                                {"goal": "Verify the result", "agent": "zoe"},
                            ],
                            parent_agent=self.parent,
                        ))

        # Verify results came back
        self.assertIn("results", result)
        self.assertEqual(len(result["results"]), 3)

        # Verify each child got the correct model from its profile
        self.assertEqual(len(self.child_models), 3)

        for i, (agent_name, expected) in enumerate(self.PROFILES.items()):
            child_info = self.child_models[i]
            self.assertEqual(
                child_info["model"], expected["model"],
                f"Child {i} ({agent_name}): expected model={expected['model']}, "
                f"got model={child_info['model']} (parent model={self.PARENT_MODEL})"
            )
            self.assertEqual(
                child_info["provider"], expected["provider"],
                f"Child {i} ({agent_name}): expected provider={expected['provider']}, "
                f"got provider={child_info['provider']}"
            )
            print(f"  ✅ {agent_name}: model={child_info['model']}, provider={child_info['provider']}")

    def test_without_profile_inherits_parent_model(self):
        """Without agent/profile, children must inherit the parent model."""
        from tools.delegate_tool import delegate_task

        self.child_models.clear()

        with patch("tools.delegate_tool._build_child_agent", self._capture_child_build):
            with patch("tools.delegate_tool._load_config") as mock_cfg:
                mock_cfg.return_value = {}
                with patch("tools.delegate_tool._resolve_delegation_credentials") as mock_resolve:
                    mock_resolve.return_value = {
                        "model": self.PARENT_MODEL,
                        "provider": self.PARENT_PROVIDER,
                        "base_url": "https://openrouter.ai/api/v1",
                        "api_key": "sk-or-v1-xxx",
                        "api_mode": "chat_completions",
                        "request_overrides": None,
                        "max_output_tokens": None,
                        "command": None,
                        "args": [],
                    }
                    with patch("tools.delegate_tool._run_single_child") as mock_run:
                        mock_run.side_effect = [
                            {"task_index": 0, "status": "completed", "summary": "A", "api_calls": 1, "duration_seconds": 1.0},
                            {"task_index": 1, "status": "completed", "summary": "B", "api_calls": 1, "duration_seconds": 1.0},
                        ]
                        result = json.loads(delegate_task(
                            tasks=[
                                {"goal": "Task A"},
                                {"goal": "Task B"},
                            ],
                            parent_agent=self.parent,
                        ))

        self.assertIn("results", result)
        for child_info in self.child_models:
            self.assertEqual(
                child_info["model"], self.PARENT_MODEL,
                f"Child without profile should inherit parent model; "
                f"got {child_info['model']}"
            )
        print(f"  ✅ Both children inherited parent model: {self.PARENT_MODEL}")

    def test_unknown_profile_falls_back_to_parent(self):
        """Unknown profile name must fall back to parent model (not crash)."""
        from tools.delegate_tool import delegate_task

        self.child_models.clear()

        with patch("tools.delegate_tool._build_child_agent", self._capture_child_build):
            with patch("tools.delegate_tool._load_config") as mock_cfg:
                mock_cfg.return_value = {
                    "agent_profiles": {"mira": {"provider": "openrouter", "model": "haiku"}},
                }
                with patch("tools.delegate_tool._resolve_delegation_credentials") as mock_resolve:
                    mock_resolve.return_value = {
                        "model": self.PARENT_MODEL,
                        "provider": self.PARENT_PROVIDER,
                        "base_url": "https://openrouter.ai/api/v1",
                        "api_key": "sk-or-v1-xxx",
                        "api_mode": "chat_completions",
                        "request_overrides": None,
                        "max_output_tokens": None,
                        "command": None,
                        "args": [],
                    }
                    with patch("tools.delegate_tool._run_single_child") as mock_run:
                        mock_run.return_value = {"task_index": 0, "status": "completed", "summary": "Fallback", "api_calls": 1, "duration_seconds": 1.0}
                        result = json.loads(delegate_task(
                            goal="Test unknown profile",
                            agent="nonexistent",
                            parent_agent=self.parent,
                        ))

        self.assertIn("results", result)
        child_info = self.child_models[0]
        self.assertEqual(
            child_info["model"], self.PARENT_MODEL,
            f"Unknown profile should fall back to parent model; "
            f"got {child_info['model']}"
        )
        print(f"  ✅ Unknown profile fell back to parent model: {child_info['model']}")


if __name__ == "__main__":
    print("=" * 60)
    print("  Agent Profile Routing — Live Integration Test")
    print("=" * 60)
    print()
    print(f"  Parent model: {TestLiveProfileRouting.PARENT_MODEL}")
    print(f"  Profiles:")
    for name, cfg in TestLiveProfileRouting.PROFILES.items():
        print(f"    {name}: {cfg['provider']}/{cfg['model']}")
    print()
    print("─" * 60)

    suite = unittest.TestLoader().loadTestsFromTestCase(TestLiveProfileRouting)
    runner = unittest.TextTestRunner(verbosity=2)
    result = runner.run(suite)

    print()
    print("─" * 60)
    if result.wasSuccessful():
        print("  ✅ ALL TESTS PASSED — profile routing works correctly!")
        sys.exit(0)
    else:
        print(f"  ❌ {len(result.failures) + len(result.errors)} test(s) FAILED")
        sys.exit(1)
