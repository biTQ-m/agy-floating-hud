#!/usr/bin/env python3
"""Antigravity Desktop lifecycle hook for AGY Floating HUD.

Captures real-time session progress, tool completions, task.md checklist percentages,
and terminal status into PLUGIN_DATA/hud_state.json without blocking or altering
agent execution or permissions.
"""

from __future__ import annotations

import json
import os
import re
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

MAX_STDIN_BYTES = 1024 * 1024
MAX_TRACKED_SESSIONS = 24

USER_REQ_RE = re.compile(r"<USER_REQUEST>([\s\S]*?)</USER_REQUEST>", re.IGNORECASE)
METADATA_RE = re.compile(r"<ADDITIONAL_METADATA>[\s\S]*$", re.IGNORECASE)
CHECKBOX_RE = re.compile(r"^\s*[-*+]\s*\[([ xX/])\]\s*(.+?)\s*$")


def resolve_data_dir() -> Path:
    env_dir = os.environ.get("PLUGIN_DATA")
    if env_dir:
        return Path(env_dir)
    return Path.home() / ".gemini" / "antigravity" / "plugin_data" / "agy-floating-hud"


def clean_user_input(raw: Any) -> str:
    text = str(raw or "").strip()
    if not text:
        return ""
    m = USER_REQ_RE.search(text)
    if m:
        text = m.group(1)
    text = METADATA_RE.sub("", text).strip()
    text = re.sub(r"\s+", " ", text)
    return text[:180]


def summarize_tool(tool_call: Any) -> tuple[str, str]:
    if not isinstance(tool_call, dict):
        return "", ""
    name = str(tool_call.get("name") or "").strip()
    args = tool_call.get("args")
    if not isinstance(args, dict):
        args = {}

    def unquote(val: Any) -> str:
        s = str(val or "").strip()
        if len(s) >= 2 and s[0] == '"' and s[-1] == '"':
            try:
                parsed = json.loads(s)
                if isinstance(parsed, str):
                    return parsed.strip()
            except Exception:
                return s[1:-1].strip()
        return s

    summary = unquote(args.get("toolSummary"))
    path_val = unquote(args.get("Path") or args.get("TargetFile") or args.get("ScriptPath"))
    base_path = Path(path_val).name if path_val else ""

    if name == "ask_question":
        return name, "等待用户确认选项"
    if summary:
        return name, summary[:90]
    if name == "run_command":
        cmd = unquote(args.get("CommandLine"))
        return name, f"终端: {cmd[:60]}" if cmd else "执行终端命令"
    if name in ("edit_file", "write_file", "replace_file_content", "multi_replace_file_content"):
        return name, f"编辑 {base_path}" if base_path else "写入文件"
    if name in ("read_file", "view_file"):
        return name, f"读取 {base_path}" if base_path else "读取文件"
    if name == "invoke_subagent":
        role = unquote(args.get("Role") or args.get("TypeName"))
        return name, f"子代理: {role[:50]}" if role else "启动子代理"
    if name == "search_web":
        q = unquote(args.get("query"))
        return name, f"搜索: {q[:50]}" if q else "网页搜索"
    if name:
        return name, f"完成 {name}"
    return "", ""


def parse_task_checklist(artifact_dir: str, conv_id: str) -> dict[str, Any] | None:
    candidates: list[Path] = []
    if artifact_dir:
        candidates.append(Path(artifact_dir) / "task.md")
    if conv_id:
        candidates.append(Path.home() / ".gemini" / "antigravity" / "brain" / conv_id / "task.md")

    task_file: Path | None = None
    for cand in candidates:
        if cand.is_file():
            task_file = cand
            break
    if task_file is None:
        return None

    try:
        lines = task_file.read_text(encoding="utf-8", errors="ignore").splitlines()
    except OSError:
        return None

    done = 0
    in_progress = 0
    total = 0
    current_item = ""
    first_pending = ""

    for line in lines:
        m = CHECKBOX_RE.match(line)
        if not m:
            continue
        mark = m.group(1)
        label = re.sub(r"[*_`]+", "", m.group(2)).strip()
        label = re.sub(r"<!--.*?-->", "", label).strip()
        total += 1
        if mark in ("x", "X"):
            done += 1
        elif mark == "/":
            in_progress += 1
            if not current_item and label:
                current_item = label[:90]
        else:
            if not first_pending and label:
                first_pending = label[:90]

    if total == 0:
        return None

    return {
        "done": done,
        "inProgress": in_progress,
        "total": total,
        "percent": round((done / total) * 100),
        "currentItem": current_item or first_pending,
    }


def load_existing(state_path: Path) -> dict[str, Any]:
    try:
        data = json.loads(state_path.read_text(encoding="utf-8"))
        if isinstance(data, dict):
            return data
    except (OSError, ValueError):
        pass
    return {"sessions": {}}


def atomic_write_json(target: Path, payload: dict[str, Any]) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=".hud_state_", suffix=".tmp", dir=str(target.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, ensure_ascii=False, indent=2)
        os.replace(tmp_name, target)
    except Exception:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise


def derive_workspace_name(workspace_paths: Any, cwd: str) -> str:
    if isinstance(workspace_paths, list):
        for p in workspace_paths:
            s = str(p or "").strip().rstrip("/")
            if s:
                return Path(s).name or s
    if cwd:
        return Path(cwd.rstrip("/")).name or cwd
    return ""


def compute_phase_and_detail(
    event_name: str,
    termination_reason: str,
    tool_name: str,
    tool_summary: str,
    tool_error: str,
) -> tuple[str, str]:
    if event_name == "SessionStart":
        return "thinking", "新会话已启动 · 准备就绪"
    if event_name == "PreInvocation":
        return "thinking", "模型正在思考与规划…"
    if event_name == "PostToolUse":
        if tool_error:
            return "thinking", f"工具返回异常 ({tool_name}) · 继续分析…"
        if tool_summary:
            return "thinking", f"已完成: {tool_summary}"
        return "thinking", "工具执行完毕 · 模型继续推理…"
    if event_name == "PostInvocation":
        return "thinking", "本轮工具链完成 · 整理回复…"
    if event_name == "Stop":
        reason = termination_reason.upper()
        if reason in ("", "NO_TOOL_CALL", "TERMINAL_STEP_TYPE", "INJECTED_RESPONSE"):
            return "completed", "已完成本轮回复"
        if reason == "USER_CANCELED":
            return "canceled", "用户已中止执行"
        return "error", f"异常中止 ({termination_reason})"
    return "thinking", "处理中…"


def process_hook_payload(payload: dict[str, Any], data_dir: Path) -> str:
    event_name = str(payload.get("hookEventName") or "")
    conv_id = str(payload.get("conversationId") or "").strip()
    if not conv_id:
        return event_name

    state_path = data_dir / "hud_state.json"
    state = load_existing(state_path)
    sessions = state.get("sessions")
    if not isinstance(sessions, dict):
        sessions = {}

    now_iso = datetime.now(timezone.utc).isoformat()
    prev = sessions.get(conv_id)
    if not isinstance(prev, dict):
        prev = {}

    workspace_paths = payload.get("workspacePaths") or prev.get("workspacePaths") or []
    cwd = str(payload.get("cwd") or prev.get("cwd") or "")
    workspace_name = derive_workspace_name(workspace_paths, cwd) or str(prev.get("workspaceName") or "")

    user_input = clean_user_input(payload.get("lastUserInput")) or str(prev.get("lastUserInput") or "")
    artifact_dir = str(payload.get("artifactDirectoryPath") or prev.get("artifactDirectoryPath") or "")
    transcript_path = str(payload.get("transcriptPath") or prev.get("transcriptPath") or "")

    tool_name, tool_summary = summarize_tool(payload.get("toolCall"))
    tool_error = str(payload.get("error") or "").strip() if event_name in ("PostToolUse", "Stop") else ""
    termination_reason = str(payload.get("terminationReason") or "") if event_name == "Stop" else ""

    phase, detail = compute_phase_and_detail(
        event_name=event_name,
        termination_reason=termination_reason,
        tool_name=tool_name,
        tool_summary=tool_summary,
        tool_error=tool_error,
    )

    prev_phase = str(prev.get("phase") or "")
    prev_input = str(prev.get("lastUserInput") or "")
    turn_started_at = str(prev.get("turnStartedAt") or "")

    # Reset turn timer when starting a fresh turn after Stop/completion or when user prompt changes
    if (
        not turn_started_at
        or event_name == "SessionStart"
        or (event_name == "PreInvocation" and prev_phase in ("completed", "canceled", "error", "idle", ""))
        or (user_input and user_input != prev_input)
    ):
        turn_started_at = now_iso

    step_idx = payload.get("stepIdx")
    if not isinstance(step_idx, int):
        step_idx = prev.get("stepIdx") if isinstance(prev.get("stepIdx"), int) else 0

    task_stats = parse_task_checklist(artifact_dir, conv_id) or prev.get("taskStats")

    sessions[conv_id] = {
        "conversationId": conv_id,
        "workspaceName": workspace_name,
        "workspacePaths": workspace_paths,
        "cwd": cwd,
        "modelName": str(payload.get("modelName") or prev.get("modelName") or ""),
        "transcriptPath": transcript_path,
        "artifactDirectoryPath": artifact_dir,
        "lastUserInput": user_input,
        "lastEvent": event_name or str(prev.get("lastEvent") or ""),
        "phase": phase,
        "detail": detail,
        "stepIdx": step_idx,
        "invocationNum": payload.get("invocationNum", prev.get("invocationNum", 0)),
        "executionNum": payload.get("executionNum", prev.get("executionNum", 0)),
        "lastToolName": tool_name or str(prev.get("lastToolName") or ""),
        "lastToolSummary": tool_summary or str(prev.get("lastToolSummary") or ""),
        "lastToolError": tool_error,
        "terminationReason": termination_reason,
        "fullyIdle": bool(payload.get("fullyIdle", True)) if event_name == "Stop" else False,
        "taskStats": task_stats,
        "turnStartedAt": turn_started_at,
        "completedAt": now_iso if phase in ("completed", "canceled", "error") else str(prev.get("completedAt") or ""),
        "updatedAt": now_iso,
    }

    if len(sessions) > MAX_TRACKED_SESSIONS:
        ordered = sorted(
            sessions.items(),
            key=lambda kv: str((kv[1] or {}).get("updatedAt") or ""),
            reverse=True,
        )
        sessions = dict(ordered[:MAX_TRACKED_SESSIONS])

    next_state = {
        "activeConversationId": conv_id,
        "updatedAt": now_iso,
        "sessions": sessions,
    }
    atomic_write_json(state_path, next_state)
    return event_name


def main() -> int:
    event_name = ""
    try:
        raw = sys.stdin.read(MAX_STDIN_BYTES)
        payload = json.loads(raw) if raw.strip() else {}
        if isinstance(payload, dict):
            event_name = process_hook_payload(payload, resolve_data_dir())
    except Exception:
        # Never block or fail the agent execution loop.
        pass

    if event_name == "Stop":
        sys.stdout.write(json.dumps({"decision": "allow"}))
    else:
        sys.stdout.write("{}")
    sys.stdout.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
