import json
import tempfile
import unittest
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "hooks"))
import hud_tracker  # noqa: E402


class HudTrackerTest(unittest.TestCase):
    def test_lifecycle_and_task_checklist_progress(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            data_dir = root / "plugin_data"
            art_dir = root / "brain" / "conv-1234"
            art_dir.mkdir(parents=True)

            (art_dir / "task.md").write_text(
                "# Tasks\n"
                "- [x] Create plugin manifest\n"
                "- [x] Implement lifecycle hooks\n"
                "- [/] Compile Swift NSPanel HUD\n"
                "- [ ] Verify installation\n",
                encoding="utf-8",
            )

            # 1. PreInvocation starts turn
            hud_tracker.process_hook_payload(
                {
                    "hookEventName": "PreInvocation",
                    "conversationId": "conv-1234",
                    "workspacePaths": ["/workspace/agy-floating-hud"],
                    "artifactDirectoryPath": str(art_dir),
                    "modelName": "agy/gemini-4-carbon:high",
                    "lastUserInput": "<USER_REQUEST>\n做一个桌面悬浮窗插件\n</USER_REQUEST>\n<ADDITIONAL_METADATA>now</ADDITIONAL_METADATA>",
                },
                data_dir,
            )

            state = json.loads((data_dir / "hud_state.json").read_text(encoding="utf-8"))
            s1 = state["sessions"]["conv-1234"]
            self.assertEqual(s1["workspaceName"], "agy-floating-hud")
            self.assertEqual(s1["phase"], "thinking")
            self.assertEqual(s1["lastUserInput"], "做一个桌面悬浮窗插件")
            self.assertEqual(s1["taskStats"]["done"], 2)
            self.assertEqual(s1["taskStats"]["total"], 4)
            self.assertEqual(s1["taskStats"]["percent"], 50)
            self.assertEqual(s1["taskStats"]["currentItem"], "Compile Swift NSPanel HUD")
            started_at = s1["turnStartedAt"]
            self.assertTrue(started_at)

            # 2. PostToolUse preserves turnStartedAt and records tool summary
            hud_tracker.process_hook_payload(
                {
                    "hookEventName": "PostToolUse",
                    "conversationId": "conv-1234",
                    "stepIdx": 6,
                    "toolCall": {
                        "name": "run_command",
                        "args": {"toolSummary": '"Compile macOS HUD"'},
                    },
                },
                data_dir,
            )
            state2 = json.loads((data_dir / "hud_state.json").read_text(encoding="utf-8"))
            s2 = state2["sessions"]["conv-1234"]
            self.assertEqual(s2["turnStartedAt"], started_at)
            self.assertEqual(s2["lastToolSummary"], "Compile macOS HUD")
            self.assertIn("Compile macOS HUD", s2["detail"])

            # 3. Stop marks completed when terminationReason == NO_TOOL_CALL
            hud_tracker.process_hook_payload(
                {
                    "hookEventName": "Stop",
                    "conversationId": "conv-1234",
                    "terminationReason": "NO_TOOL_CALL",
                    "fullyIdle": True,
                },
                data_dir,
            )
            state3 = json.loads((data_dir / "hud_state.json").read_text(encoding="utf-8"))
            s3 = state3["sessions"]["conv-1234"]
            self.assertEqual(s3["phase"], "completed")
            self.assertTrue(s3["completedAt"])

    def test_stop_error_and_cancel_states(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            data_dir = Path(tmp) / "data"
            hud_tracker.process_hook_payload(
                {
                    "hookEventName": "Stop",
                    "conversationId": "conv-err",
                    "terminationReason": "ERROR",
                },
                data_dir,
            )
            hud_tracker.process_hook_payload(
                {
                    "hookEventName": "Stop",
                    "conversationId": "conv-cancel",
                    "terminationReason": "USER_CANCELED",
                },
                data_dir,
            )
            state = json.loads((data_dir / "hud_state.json").read_text(encoding="utf-8"))
            self.assertEqual(state["sessions"]["conv-err"]["phase"], "error")
            self.assertEqual(state["sessions"]["conv-cancel"]["phase"], "canceled")


if __name__ == "__main__":
    unittest.main()
