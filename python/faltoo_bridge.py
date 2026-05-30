#!/usr/bin/env python3
from __future__ import annotations

import argparse
import asyncio
import json
import sys
from collections.abc import Callable
from pathlib import Path
from typing import Any

from faltoobot.faltoochat.git import get_unstaged_files, is_git_workspace
from faltoobot.faltoochat.logging_config import configure_logging  # ty: ignore[unresolved-import]
from faltoobot.faltoochat.review_api import Review, reviews_prompt
from faltoobot.faltoochat.slash_commands import SlashCommandStore
from faltoobot.faltoochat.stream import get_event_text
from faltoobot.sessions import (
    Session,
    append_user_turn,
    get_answer_streaming,
    get_dir_chat_key,
    get_messages,
    get_session,
    prewarm_openai_websocket,  # ty: ignore[unresolved-import]
)

# Logging can change when the workspace/session changes, so remember the last one.
_configured_logging: tuple[Path, str] | None = None


def _session(workspace: Path) -> Session:
    global _configured_logging

    workspace = workspace.expanduser().resolve()
    session = get_session(get_dir_chat_key(workspace), workspace=workspace)
    log_path = session.chat_root.parent.parent / "faltoochat.log"
    key = (log_path, session.session_id)
    if _configured_logging != key:
        # _session() is called often; only reconfigure when the active session changes.
        configure_logging(log_path, session_id=session.session_id)
        _configured_logging = key
    return session


def _message_text(item: dict[str, Any]) -> str:
    content = item.get("content", "")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for part in content:
            if isinstance(part, dict) and isinstance(part.get("text"), str):
                parts.append(part["text"])
        return "\n".join(parts)
    return ""


def _payload_comments(payload: dict[str, Any]) -> list[dict[str, Any]]:
    comments = payload.get("comments")
    if not isinstance(comments, list):
        return []
    return [item for item in comments if isinstance(item, dict)]


def _print_json(payload: dict[str, Any]) -> None:
    print(json.dumps(payload, ensure_ascii=False), flush=True)


def messages_path(workspace: Path) -> int:
    session = _session(workspace)
    print(session.messages_path)
    return 0


def unstaged_files(workspace: Path) -> int:
    workspace = workspace.expanduser().resolve()
    if not is_git_workspace(workspace):
        _print_json({"ok": False, "error": "Not inside a git repository"})
        return 0

    files = []
    for path in get_unstaged_files(workspace):
        full_path = workspace / path
        if full_path.is_file():
            # Deleted files can appear in git diff but cannot be opened as buffers.
            files.append(str(full_path.resolve()))

    _print_json({"ok": True, "files": files})
    return 0


def messages(workspace: Path, limit: int) -> int:
    items = get_messages(_session(workspace))["messages"][-limit:]
    messages_payload: list[dict[str, str]] = []
    for item in items:
        # Skip non-message records that cannot be displayed by the Neovim modal.
        if not isinstance(item, dict):
            continue
        role = str(item.get("role") or item.get("type") or "item")
        text = _message_text(item).strip()
        # Navigation is message-based, so omit empty/tool-only records.
        if not text:
            continue
        messages_payload.append({"role": role, "text": text})

    _print_json({"messages": messages_payload})
    return 0


def _normalize_comments(items: list[dict[str, Any]]) -> list[Review]:
    comments: list[Review] = []
    for item in items:
        line = int(item.get("line_number_start") or 0)
        end = int(item.get("line_number_end") or line)
        comments.append(
            {
                "filename": Path(str(item.get("filename") or "[No Name]")),
                "line_number_start": line,
                "line_number_end": end,
                "file_line_number_start": int(
                    item.get("file_line_number_start") or line
                ),
                "file_line_number_end": int(item.get("file_line_number_end") or end),
                "code": str(item.get("code") or ""),
                "comment": str(item.get("comment") or ""),
            }
        )
    return comments


BUILTIN_SLASH_COMMANDS = frozenset(
    {"/compact", "/name", "/reset", "/resume", "/status", "/tree"}
)


def slash_commands() -> int:
    commands = SlashCommandStore(excluded_commands=BUILTIN_SLASH_COMMANDS).commands()
    payload = [
        {
            "command": command,
            "preview": prompt.preview,
            "template": prompt.template,
        }
        for command, prompt in sorted(commands.items())
    ]
    _print_json({"commands": payload})
    return 0


def _expand_slash_command(text: str) -> str:
    command = text.strip()
    prompt = (
        SlashCommandStore(excluded_commands=BUILTIN_SLASH_COMMANDS)
        .commands()
        .get(command)
    )
    if prompt is None:
        return text
    return prompt.template


# Streaming code emits small updates; the server maps them to JSON lines for Neovim.
Emit = Callable[[bool, str, str], None]


async def _stream_answer(session: Session, emit: Emit) -> None:
    async for event in get_answer_streaming(session):
        is_new, classes, text = get_event_text(event)
        # Empty new events separate adjacent streaming blocks in the UI.
        if not text.strip() and not is_new:
            continue
        emit(is_new, classes, text)

    emit(True, "done", "Assistant response saved.")


async def prewarm(workspace: Path) -> int:
    await prewarm_openai_websocket(_session(workspace))
    return 0


async def append_review(
    workspace: Path, items: list[dict[str, Any]], emit: Emit
) -> int:
    comments = _normalize_comments(items)
    # The UI can submit with a stale empty queue after comments were cleared.
    if not comments:
        emit(True, "done", "No review comments to submit.")
        return 0

    session = _session(workspace)
    await append_user_turn(session, question=reviews_prompt(comments))
    emit(
        True,
        "status",
        f"Submitted {len(comments)} review comment(s). Waiting for assistant...",
    )
    await _stream_answer(session, emit)
    return 0


async def append_message(workspace: Path, text: str, emit: Emit) -> int:
    text = _expand_slash_command(text.strip())
    # FaltooBot requires a non-empty user turn.
    if not text:
        emit(True, "done", "No message to submit.")
        return 0

    session = _session(workspace)
    await append_user_turn(session, question=text)
    emit(True, "status", "Submitted message. Waiting for assistant...")
    await _stream_answer(session, emit)
    return 0


async def _run_server_command(
    command: str, payload: dict[str, Any], emit: Emit
) -> None:
    workspace = Path(str(payload.get("workspace") or Path.cwd()))
    if command == "prewarm":
        await prewarm(workspace)
    elif command == "append-review":
        await append_review(workspace, _payload_comments(payload), emit)
    elif command == "append-message":
        await append_message(workspace, str(payload.get("text") or ""), emit)
    else:
        raise ValueError(f"Unsupported server command: {command}")


async def _handle_server_request(request: dict[str, Any]) -> None:
    """Run one JSON request from the persistent Neovim bridge server."""
    request_id = request.get("id")
    args = request.get("args")
    if not isinstance(args, list) or not args:
        _print_json(
            {"id": request_id, "done": True, "ok": False, "error": "Missing command"}
        )
        return

    def emit(is_new: bool, classes: str, text: str) -> None:
        _print_json(
            {
                "id": request_id,
                "event": {"is_new": is_new, "classes": classes, "text": text},
            }
        )

    try:
        payload = json.loads(str(request.get("input") or "{}"))
        if not isinstance(payload, dict):
            # Invalid JSON input should fail as an empty command payload.
            payload = {}
        await _run_server_command(str(args[0]), payload, emit)
    except Exception as exc:
        _print_json({"id": request_id, "done": True, "ok": False, "error": str(exc)})
        return

    _print_json({"id": request_id, "done": True, "ok": True})


async def server() -> int:
    """Run the persistent Neovim bridge server.

    Reads one JSON object per stdin line:
    {"id": "1", "args": ["append-message"], "input": "{...}"}.
    Writes JSON lines back with the same id, either streaming `event` payloads
    or a final `{done: true, ok: bool}` response. Requests run one at a time
    so websocket prewarm cannot race with a later submit.
    """
    loop = asyncio.get_running_loop()
    while line := await loop.run_in_executor(None, sys.stdin.readline):
        try:
            request = json.loads(line)
        except json.JSONDecodeError as exc:
            _print_json({"id": None, "done": True, "ok": False, "error": str(exc)})
            continue
        if not isinstance(request, dict):
            _print_json(
                {"id": None, "done": True, "ok": False, "error": "Invalid request"}
            )
            continue

        # Keep requests ordered so prewarm cannot race with a later submit.
        await _handle_server_request(request)

    return 0


def main() -> int:
    parser = argparse.ArgumentParser(prog="faltoo_bridge")
    sub = parser.add_subparsers(dest="command", required=True)

    messages_parser = sub.add_parser("messages")
    messages_parser.add_argument("--workspace", default=str(Path.cwd()))
    messages_parser.add_argument("--limit", type=int, default=100)

    messages_path_parser = sub.add_parser("messages-path")
    messages_path_parser.add_argument("--workspace", default=str(Path.cwd()))

    unstaged_parser = sub.add_parser("unstaged-files")
    unstaged_parser.add_argument("--workspace", default=str(Path.cwd()))

    sub.add_parser("slash-commands")
    sub.add_parser("server")

    args = parser.parse_args()
    if args.command == "messages":
        return messages(Path(args.workspace), args.limit)
    if args.command == "messages-path":
        return messages_path(Path(args.workspace))
    if args.command == "unstaged-files":
        return unstaged_files(Path(args.workspace))
    if args.command == "slash-commands":
        return slash_commands()
    if args.command == "server":
        return asyncio.run(server())
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
