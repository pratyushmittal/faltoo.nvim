#!/usr/bin/env python3
from __future__ import annotations

import argparse
import asyncio
import json
from pathlib import Path
import sys
from typing import Any

from faltoobot.faltoochat.git import get_unstaged_files, is_git_workspace  # ty: ignore[unresolved-import]
from faltoobot.faltoochat.review_api import Review, reviews_prompt  # ty: ignore[unresolved-import]
from faltoobot.faltoochat.slash_commands import SlashCommandStore  # ty: ignore[unresolved-import]
from faltoobot.faltoochat.stream import get_event_text  # ty: ignore[unresolved-import]
from faltoobot.sessions import (  # ty: ignore[unresolved-import]
    Session,
    append_user_turn,
    get_answer_streaming,
    get_dir_chat_key,
    get_messages,
    get_session,
)


def _session(workspace: Path) -> Session:
    workspace = workspace.expanduser().resolve()
    return get_session(get_dir_chat_key(workspace), workspace=workspace)


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


def _stdin_payload() -> dict[str, Any]:
    payload = json.loads(sys.stdin.read() or "{}")
    if isinstance(payload, dict):
        return payload
    return {}


def _payload_comments(payload: dict[str, Any]) -> list[dict[str, Any]]:
    comments = payload.get("comments")
    if not isinstance(comments, list):
        return []
    return [item for item in comments if isinstance(item, dict)]


def messages_path(workspace: Path) -> int:
    session = _session(workspace)
    print(session.messages_path)
    return 0


def unstaged_files(workspace: Path) -> int:
    workspace = workspace.expanduser().resolve()
    if not is_git_workspace(workspace):
        print(
            json.dumps(
                {"ok": False, "error": "Not inside a git repository"},
                ensure_ascii=False,
            )
        )
        return 0

    files = []
    for path in get_unstaged_files(workspace):
        full_path = workspace / path
        if full_path.is_file():
            # Deleted files can appear in git diff but cannot be opened as buffers.
            files.append(str(full_path.resolve()))

    print(json.dumps({"ok": True, "files": files}, ensure_ascii=False))
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

    print(json.dumps({"messages": messages_payload}, ensure_ascii=False))
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
    print(json.dumps({"commands": payload}, ensure_ascii=False))
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


def _emit(is_new: bool, classes: str, text: str) -> None:
    print(
        json.dumps(
            {"is_new": is_new, "classes": classes, "text": text},
            ensure_ascii=False,
        ),
        flush=True,
    )


async def _stream_answer(session: Session) -> None:
    async for event in get_answer_streaming(session):
        is_new, classes, text = get_event_text(event)
        # Some stream events only update state and have no visible text.
        if not text.strip():
            continue
        _emit(is_new, classes, text)

    _emit(True, "done", "Assistant response saved.")


async def append_review(workspace: Path, items: list[dict[str, Any]]) -> int:
    comments = _normalize_comments(items)
    # The UI can submit with a stale empty queue after comments were cleared.
    if not comments:
        _emit(True, "done", "No review comments to submit.")
        return 0

    session = _session(workspace)
    await append_user_turn(session, question=reviews_prompt(comments))
    _emit(
        True,
        "status",
        f"Submitted {len(comments)} review comment(s). Waiting for assistant...",
    )
    await _stream_answer(session)
    return 0


async def append_message(workspace: Path, text: str) -> int:
    text = _expand_slash_command(text.strip())
    # FaltooBot requires a non-empty user turn.
    if not text:
        _emit(True, "done", "No message to submit.")
        return 0

    session = _session(workspace)
    await append_user_turn(session, question=text)
    _emit(True, "status", "Submitted message. Waiting for assistant...")
    await _stream_answer(session)
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

    sub.add_parser("append-review")
    sub.add_parser("append-message")
    sub.add_parser("slash-commands")

    args = parser.parse_args()
    if args.command == "messages":
        return messages(Path(args.workspace), args.limit)
    if args.command == "messages-path":
        return messages_path(Path(args.workspace))
    if args.command == "unstaged-files":
        return unstaged_files(Path(args.workspace))
    if args.command == "append-review":
        payload = _stdin_payload()
        workspace = Path(str(payload.get("workspace") or Path.cwd()))
        return asyncio.run(append_review(workspace, _payload_comments(payload)))
    if args.command == "append-message":
        payload = _stdin_payload()
        workspace = Path(str(payload.get("workspace") or Path.cwd()))
        return asyncio.run(append_message(workspace, str(payload.get("text") or "")))
    if args.command == "slash-commands":
        return slash_commands()
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
