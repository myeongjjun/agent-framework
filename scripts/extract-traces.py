#!/usr/bin/env python3
"""Extract unified Claude/Codex activity traces as JSONL."""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
from datetime import date, datetime, timedelta
from typing import Any

CLAUDE_ROOT = os.path.expanduser("~/.claude/projects")
CODEX_ROOT = os.path.expanduser("~/.codex/sessions")
CODEX_INDEX = os.path.expanduser("~/.codex/session_index.jsonl")
SKIP_CLAUDE_TYPES = {
    "file-history-snapshot",
    "progress",
    "queue-operation",
    "system",
}
SYSTEM_PROMPT_PREFIXES = (
    "<task-notification",
    "<command-",
    "<system-",
    "<local-command",
    "Base directory for this skill:",
    "[Request interrupted",
)


def parse_args() -> argparse.Namespace:
    """Parse command-line arguments."""

    parser = argparse.ArgumentParser(
        description="Extract unified Claude/Codex transcript events as JSONL."
    )
    parser.add_argument(
        "--agent",
        choices=("claude", "codex", "all"),
        required=True,
        help="Transcript source to extract.",
    )
    range_group = parser.add_mutually_exclusive_group(required=True)
    range_group.add_argument(
        "--days",
        type=int,
        help="Include the last N calendar days, including today.",
    )
    range_group.add_argument(
        "--date",
        dest="exact_date",
        help="Include a single calendar date (YYYY-MM-DD).",
    )
    parser.add_argument(
        "--project",
        help="Only include events whose cwd is inside this path.",
    )
    parser.add_argument(
        "--session",
        help="Only include events whose sid matches this session id.",
    )
    parser.add_argument(
        "--include-assistant-text",
        action="store_true",
        help=(
            "Emit evt:assistant_text events containing assistant response "
            "bodies. Requires --session (session-scoped opt-in to prevent "
            "volume explosion). See ADR-022 amendment 2026-04-08."
        ),
    )
    args = parser.parse_args()

    if args.days is not None and args.days < 1:
        parser.error("--days must be >= 1")

    if args.exact_date is not None:
        try:
            datetime.strptime(args.exact_date, "%Y-%m-%d")
        except ValueError as exc:
            parser.error(f"--date must be YYYY-MM-DD: {exc}")

    if args.include_assistant_text and not args.session:
        parser.error("--include-assistant-text requires --session <id>")

    return args


def target_dates(args: argparse.Namespace) -> set[str]:
    """Return the set of YYYY-MM-DD values in scope."""

    if args.exact_date:
        return {args.exact_date}

    today = date.today()
    return {
        (today - timedelta(days=offset)).isoformat()
        for offset in range(args.days)
    }


def normalize_project(project: str | None) -> str | None:
    """Normalize the optional project path."""

    if not project:
        return None
    return os.path.realpath(os.path.abspath(project))


def truncate(value: Any, limit: int) -> str:
    """Convert a value to string and clamp it to a fixed length."""

    if value is None:
        return ""
    text = str(value)
    return text[:limit]


def is_in_project(cwd: str, project: str | None) -> bool:
    """Return True when cwd is inside the selected project."""

    if project is None:
        return True
    if not cwd:
        return False

    real_cwd = os.path.realpath(os.path.abspath(cwd))
    return real_cwd == project or real_cwd.startswith(project + os.sep)


def date_matches(ts: str, dates: set[str]) -> bool:
    """Return True when an ISO-ish timestamp belongs to the requested dates."""

    return bool(ts) and ts[:10] in dates


def should_emit(ts: str, cwd: str, dates: set[str], project: str | None) -> bool:
    """Apply date and project filters."""

    return date_matches(ts, dates) and is_in_project(cwd, project)


def parse_json_line(line: str) -> dict[str, Any] | None:
    """Parse a JSONL record, skipping malformed lines."""

    try:
        value = json.loads(line)
    except json.JSONDecodeError:
        return None
    if isinstance(value, dict):
        return value
    return None


def extract_text_content(content: Any) -> str:
    """Extract user-visible text from Claude/Codex content payloads."""

    if isinstance(content, str):
        return content.strip()

    if isinstance(content, dict):
        item_type = content.get("type")
        if item_type in {"text", "input_text", "output_text"}:
            return truncate(content.get("text") or content.get("content"), 500).strip()
        return ""

    if isinstance(content, list):
        parts: list[str] = []
        for item in content:
            if not isinstance(item, dict):
                continue
            item_type = item.get("type")
            if item_type in {"text", "input_text", "output_text"}:
                text = truncate(item.get("text") or item.get("content"), 500).strip()
                if text:
                    parts.append(text)
        return "\n".join(parts).strip()

    return ""


def extract_assistant_text_full(content: Any, limit: int = 8000) -> str:
    """Extract full assistant text blocks, joined — larger cap than extract_text_content.

    Used only when --include-assistant-text is set (session-scoped), so the
    500-char-per-item truncation of extract_text_content would lose proposal
    bodies. Joins all text items with a blank line and truncates the joined
    result at `limit` characters.
    """

    if isinstance(content, str):
        return content.strip()[:limit]

    if isinstance(content, list):
        parts: list[str] = []
        for item in content:
            if not isinstance(item, dict):
                continue
            if item.get("type") != "text":
                continue
            text = (item.get("text") or "").strip()
            if text:
                parts.append(text)
        joined = "\n\n".join(parts).strip()
        return joined[:limit]

    if isinstance(content, dict) and content.get("type") == "text":
        return (content.get("text") or "").strip()[:limit]

    return ""


def iter_claude_tool_uses(content: Any) -> list[dict[str, Any]]:
    """Return Claude tool_use entries from a message payload."""

    if not isinstance(content, list):
        return []
    return [
        item
        for item in content
        if isinstance(item, dict) and item.get("type") == "tool_use"
    ]


def iter_claude_tool_results(content: Any) -> list[dict[str, Any]]:
    """Return Claude tool_result entries from a message payload."""

    if not isinstance(content, list):
        return []
    return [
        item
        for item in content
        if isinstance(item, dict) and item.get("type") == "tool_result"
    ]


def parse_slash_skill(text: str) -> str | None:
    """Extract an explicit /skill name from a prompt."""

    match = re.match(r"^/([a-z][a-z-]*)", text.strip())
    if match:
        return match.group(1)
    return None


def is_system_generated_prompt(text: str) -> bool:
    """Skip synthetic Claude prompts emitted by hooks/commands."""

    stripped = text.strip()
    return any(stripped.startswith(prefix) for prefix in SYSTEM_PROMPT_PREFIXES)


def safe_json_summary(value: Any, limit: int) -> str:
    """Serialize arbitrary input into a short JSON-ish summary."""

    try:
        text = json.dumps(value, ensure_ascii=False, sort_keys=True)
    except (TypeError, ValueError):
        text = str(value)
    return text[:limit]


def summarize_tool_input(tool_name: str, raw_input: Any) -> dict[str, Any]:
    """Summarize tool input in the same shape as legacy activity logs."""

    data = raw_input if isinstance(raw_input, dict) else {}

    if tool_name in {"Bash", "exec_command", "shell_command"}:
        command = data.get("command") or data.get("cmd")
        return {"command": truncate(command, 500)}

    if tool_name in {"Edit", "MultiEdit"}:
        return {
            "file": data.get("file_path") or data.get("file"),
            "old": truncate(data.get("old_string") or data.get("old"), 100),
        }

    if tool_name in {"Read", "Write"}:
        return {"file": data.get("file_path") or data.get("file")}

    if tool_name == "Grep":
        return {
            "pattern": data.get("pattern"),
            "path": data.get("path"),
        }

    if tool_name == "Glob":
        return {"pattern": data.get("pattern")}

    if tool_name == "Agent":
        return {
            "type": data.get("subagent_type") or data.get("type"),
            "desc": truncate(data.get("description") or data.get("desc"), 200),
        }

    if tool_name == "Skill":
        return {"skill": data.get("skill")}

    return {"summary": safe_json_summary(raw_input, 200)}


def tool_error_from_result(item: dict[str, Any], record: dict[str, Any]) -> str | None:
    """Extract a concise Claude tool error string."""

    if not item.get("is_error"):
        return None

    content = item.get("content")
    text = extract_text_content(content) if isinstance(content, (dict, list)) else truncate(content, 200)
    if not text:
        text = truncate(record.get("toolUseResult"), 200)
    return truncate(text, 200) or None


def emit_prompt_event(
    events: list[dict[str, Any]],
    *,
    ts: str,
    sid: str,
    cwd: str,
    text: str,
    agent: str,
    dates: set[str],
    project: str | None,
) -> None:
    """Append a prompt event and its explicit /skill companion if needed."""

    prompt = truncate(text, 500)
    if not prompt or is_system_generated_prompt(prompt):
        return
    if not should_emit(ts, cwd, dates, project):
        return

    events.append(
        {
            "ts": ts,
            "sid": sid or "unknown",
            "agent": agent,
            "evt": "prompt",
            "text": prompt,
            "cwd": cwd or "unknown",
        }
    )

    skill = parse_slash_skill(prompt)
    if skill:
        events.append(
            {
                "ts": ts,
                "sid": sid or "unknown",
                "agent": agent,
                "evt": "skill",
                "skill": skill,
                "cwd": cwd or "unknown",
            }
        )


def collect_claude_events(
    dates: set[str],
    project: str | None,
    *,
    include_assistant_text: bool = False,
) -> list[dict[str, Any]]:
    """Collect unified events from Claude session transcripts."""

    events: list[dict[str, Any]] = []
    pattern = os.path.join(CLAUDE_ROOT, "**", "*.jsonl")

    for path in sorted(glob.glob(pattern, recursive=True)):
        pending: dict[str, dict[str, Any]] = {}
        session_id = ""
        session_cwd = ""

        try:
            handle = open(path, "r", encoding="utf-8", errors="replace")
        except OSError:
            continue

        with handle:
            for line in handle:
                record = parse_json_line(line)
                if record is None:
                    continue

                record_type = record.get("type")
                if record_type in SKIP_CLAUDE_TYPES:
                    continue

                session_id = str(record.get("sessionId") or session_id or "")
                session_cwd = str(record.get("cwd") or session_cwd or "")
                ts = str(record.get("timestamp") or "")
                sid = session_id or "unknown"
                cwd = session_cwd or "unknown"
                message = record.get("message")
                content = message.get("content") if isinstance(message, dict) else None

                if record_type == "assistant":
                    if include_assistant_text and should_emit(ts, cwd, dates, project):
                        assistant_text = extract_assistant_text_full(content)
                        if assistant_text:
                            events.append(
                                {
                                    "ts": ts,
                                    "sid": sid,
                                    "agent": "claude",
                                    "evt": "assistant_text",
                                    "text": assistant_text,
                                    "cwd": cwd,
                                }
                            )
                    for tool_use in iter_claude_tool_uses(content):
                        tool_id = str(tool_use.get("id") or "")
                        if not tool_id:
                            continue
                        tool_name = str(tool_use.get("name") or "unknown")
                        tool_input = summarize_tool_input(tool_name, tool_use.get("input"))
                        pending[tool_id] = {
                            "sid": sid,
                            "cwd": cwd,
                            "ts": ts,
                            "tool": tool_name,
                            "input": tool_input,
                        }
                        if tool_name == "Skill" and should_emit(ts, cwd, dates, project):
                            events.append(
                                {
                                    "ts": ts,
                                    "sid": sid,
                                    "agent": "claude",
                                    "evt": "skill",
                                    "skill": tool_input.get("skill"),
                                    "cwd": cwd,
                                }
                            )
                    continue

                if record_type != "user" or record.get("userType") != "external":
                    continue

                prompt_text = extract_text_content(content)
                if prompt_text:
                    emit_prompt_event(
                        events,
                        ts=ts,
                        sid=sid,
                        cwd=cwd,
                        text=prompt_text,
                        agent="claude",
                        dates=dates,
                        project=project,
                    )

                for tool_result in iter_claude_tool_results(content):
                    tool_id = str(
                        tool_result.get("tool_use_id")
                        or tool_result.get("toolUseId")
                        or ""
                    )
                    pending_event = pending.pop(tool_id, None)
                    if pending_event is None:
                        continue

                    event_ts = ts or pending_event["ts"]
                    event_cwd = pending_event["cwd"] or cwd
                    if not should_emit(event_ts, event_cwd, dates, project):
                        continue

                    error = tool_error_from_result(tool_result, record)
                    events.append(
                        {
                            "ts": event_ts,
                            "sid": pending_event["sid"],
                            "agent": "claude",
                            "evt": "tool",
                            "tool": pending_event["tool"],
                            "input": pending_event["input"],
                            "ok": error is None,
                            "error": error,
                            "cwd": event_cwd or "unknown",
                        }
                    )

    return events


def load_codex_index(dates: set[str]) -> set[str] | None:
    """Load Codex session ids from session_index.jsonl when available."""

    if not os.path.exists(CODEX_INDEX):
        return None

    session_ids: set[str] = set()
    try:
        handle = open(CODEX_INDEX, "r", encoding="utf-8", errors="replace")
    except OSError:
        return None

    with handle:
        for line in handle:
            record = parse_json_line(line)
            if record is None:
                continue
            updated_at = str(record.get("updated_at") or "")
            session_id = str(record.get("id") or "")
            if session_id and date_matches(updated_at, dates):
                session_ids.add(session_id)

    return session_ids


def codex_files_from_index(session_ids: set[str]) -> list[str]:
    """Resolve rollout files for indexed Codex session ids."""

    files: list[str] = []
    seen: set[str] = set()

    for session_id in sorted(session_ids):
        pattern = os.path.join(CODEX_ROOT, "**", f"*{session_id}.jsonl")
        for path in glob.glob(pattern, recursive=True):
            if path in seen:
                continue
            seen.add(path)
            files.append(path)

    return files


def codex_files_from_dates(dates: set[str]) -> list[str]:
    """Resolve rollout files from date-based Codex directories."""

    files: list[str] = []
    for day in sorted(dates):
        year, month, day_value = day.split("-")
        pattern = os.path.join(CODEX_ROOT, year, month, day_value, "rollout-*.jsonl")
        files.extend(sorted(glob.glob(pattern)))
    return files


def parse_codex_arguments(raw_arguments: Any) -> Any:
    """Parse a Codex function-call argument payload."""

    if isinstance(raw_arguments, (dict, list)):
        return raw_arguments
    if not isinstance(raw_arguments, str):
        return raw_arguments

    text = raw_arguments.strip()
    if not text:
        return {}
    if text[0] not in "{[":
        return text

    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return raw_arguments


def parse_exit_code(output: str) -> int | None:
    """Extract an exit code from Codex tool output."""

    for pattern in (
        r"Process exited with code\s+(-?\d+)",
        r"Exit code:\s*(-?\d+)",
    ):
        match = re.search(pattern, output)
        if match:
            try:
                return int(match.group(1))
            except ValueError:
                return None
    return None


def summarize_codex_error(output: str) -> str | None:
    """Extract a concise error string from raw Codex tool output."""

    if not output:
        return None

    if "\nOutput:\n" in output:
        body = output.split("\nOutput:\n", 1)[1]
        for line in body.splitlines():
            stripped = line.strip()
            if stripped:
                return stripped[:200]

    for line in output.splitlines():
        stripped = line.strip()
        if stripped and not stripped.startswith(("Exit code:", "Wall time:", "Command:", "Chunk ID:", "Process exited with code")):
            return stripped[:200]

    return truncate(output, 200) or None


def collect_codex_events(dates: set[str], project: str | None) -> list[dict[str, Any]]:
    """Collect unified events from Codex rollout transcripts."""

    indexed_ids = load_codex_index(dates)
    if indexed_ids is not None:
        files = codex_files_from_index(indexed_ids)
        if not files:
            indexed_ids = None
            files = codex_files_from_dates(dates)
    else:
        files = codex_files_from_dates(dates)

    events: list[dict[str, Any]] = []

    for path in files:
        pending: dict[str, dict[str, Any]] = {}
        session_id = ""
        session_cwd = ""

        try:
            handle = open(path, "r", encoding="utf-8", errors="replace")
        except OSError:
            continue

        with handle:
            for line in handle:
                record = parse_json_line(line)
                if record is None:
                    continue

                record_type = record.get("type")
                payload = record.get("payload")
                if not isinstance(payload, dict):
                    continue

                ts = str(record.get("timestamp") or "")

                if record_type == "session_meta":
                    session_id = str(payload.get("id") or session_id or "")
                    session_cwd = str(payload.get("cwd") or session_cwd or "")
                    if indexed_ids is not None and session_id and session_id not in indexed_ids:
                        pending.clear()
                        break
                    continue

                if record_type == "turn_context":
                    session_cwd = str(payload.get("cwd") or session_cwd or "")
                    continue

                if record_type == "event_msg" and payload.get("type") == "user_message":
                    emit_prompt_event(
                        events,
                        ts=ts,
                        sid=session_id or "unknown",
                        cwd=session_cwd or "unknown",
                        text=str(payload.get("message") or ""),
                        agent="codex",
                        dates=dates,
                        project=project,
                    )
                    continue

                if record_type != "response_item":
                    continue

                item_type = payload.get("type")
                if item_type == "function_call":
                    tool_name = str(payload.get("name") or "unknown")
                    arguments = parse_codex_arguments(payload.get("arguments"))
                    tool_input = summarize_tool_input(tool_name, arguments)
                    call_id = str(payload.get("call_id") or "")
                    if call_id:
                        pending[call_id] = {
                            "ts": ts,
                            "sid": session_id or "unknown",
                            "cwd": session_cwd or "unknown",
                            "tool": tool_name,
                            "input": tool_input,
                        }

                    if tool_name == "Skill" and should_emit(ts, session_cwd or "unknown", dates, project):
                        events.append(
                            {
                                "ts": ts,
                                "sid": session_id or "unknown",
                                "agent": "codex",
                                "evt": "skill",
                                "skill": tool_input.get("skill"),
                                "cwd": session_cwd or "unknown",
                            }
                        )
                    continue

                if item_type != "function_call_output":
                    continue

                call_id = str(payload.get("call_id") or "")
                pending_event = pending.pop(call_id, None)
                if pending_event is None:
                    continue

                event_cwd = pending_event["cwd"] or session_cwd or "unknown"
                event_ts = ts or pending_event["ts"]
                if not should_emit(event_ts, event_cwd, dates, project):
                    continue

                raw_output = str(payload.get("output") or "")
                exit_code = parse_exit_code(raw_output)
                ok = True if exit_code is None else exit_code == 0
                error = None if ok else summarize_codex_error(raw_output)

                events.append(
                    {
                        "ts": event_ts,
                        "sid": pending_event["sid"],
                        "agent": "codex",
                        "evt": "tool",
                        "tool": pending_event["tool"],
                        "input": pending_event["input"],
                        "ok": ok,
                        "error": error,
                        "cwd": event_cwd,
                    }
                )

        for pending_event in pending.values():
            if should_emit(pending_event["ts"], pending_event["cwd"], dates, project):
                events.append(
                    {
                        "ts": pending_event["ts"],
                        "sid": pending_event["sid"],
                        "agent": "codex",
                        "evt": "tool",
                        "tool": pending_event["tool"],
                        "input": pending_event["input"],
                        "ok": True,
                        "error": None,
                        "cwd": pending_event["cwd"],
                    }
                )

    return events


def main() -> int:
    """CLI entry point."""

    args = parse_args()
    dates = target_dates(args)
    project = normalize_project(args.project)

    events: list[dict[str, Any]] = []

    if args.agent in {"claude", "all"}:
        events.extend(
            collect_claude_events(
                dates,
                project,
                include_assistant_text=args.include_assistant_text,
            )
        )

    if args.agent in {"codex", "all"}:
        events.extend(collect_codex_events(dates, project))

    if args.session:
        events = [e for e in events if e.get("sid") == args.session]

    events.sort(
        key=lambda event: (
            event.get("ts", ""),
            event.get("agent", ""),
            event.get("sid", ""),
            event.get("evt", ""),
        )
    )

    for event in events:
        print(json.dumps(event, ensure_ascii=False, separators=(",", ":")))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
