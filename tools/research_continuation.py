#!/usr/bin/env python3
"""Small, local-only ownership coordination for StockSage continuation work.

The helper deliberately performs no Git, network, API, scheduler, or app action.  It only
serializes a JSON state document under an advisory OS lock so a caller can decide whether it may
continue work.  Fallback ownership is intentionally fail-closed.
"""

from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import json
import os
import re
import sys
import tempfile
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterator


BRANCH = "codex/research-quality-fixes"
MAX_EVIDENCE_AGE_SECONDS = 300
OWNER = re.compile(r"^[A-Za-z0-9._:/-]{1,200}$")


class Refused(RuntimeError):
    """The requested transition is not safe enough to perform."""


def utc_now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def iso(value: dt.datetime) -> str:
    return value.astimezone(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def parse_time(value: str) -> dt.datetime:
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise Refused("evidence-at must be an ISO-8601 timestamp") from error
    if parsed.tzinfo is None:
        raise Refused("evidence-at must include a timezone")
    return parsed.astimezone(dt.timezone.utc)


def require_owner(owner: str) -> None:
    if not OWNER.fullmatch(owner):
        raise Refused("owner-thread is required and may contain only letters, digits, . _ : / -")


@contextmanager
def locked_state(path: Path, *, write: bool) -> Iterator[tuple[dict[str, Any], Any]]:
    """Load state while holding one flock shared by all helper invocations for this path."""
    path.parent.mkdir(parents=True, exist_ok=True)
    lock_path = path.with_name(path.name + ".lock")
    with lock_path.open("a+", encoding="utf-8") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX if write else fcntl.LOCK_SH)
        try:
            if not path.exists():
                state: dict[str, Any] = {}
            else:
                try:
                    decoded = json.loads(path.read_text(encoding="utf-8"))
                except (OSError, json.JSONDecodeError) as error:
                    raise Refused("state is unreadable or malformed; refusing to overwrite it") from error
                if not isinstance(decoded, dict):
                    raise Refused("state root must be an object")
                state = decoded
            yield state, lock
        finally:
            fcntl.flock(lock.fileno(), fcntl.LOCK_UN)


def section(state: dict[str, Any]) -> dict[str, Any]:
    value = state.setdefault("researchContinuation", {})
    if not isinstance(value, dict):
        raise Refused("researchContinuation must be an object")
    history = value.setdefault("history", [])
    if not isinstance(history, list):
        raise Refused("researchContinuation.history must be an array")
    if "activeClaim" not in value:
        value["activeClaim"] = None
    active = value["activeClaim"]
    if active is not None and not isinstance(active, dict):
        raise Refused("researchContinuation.activeClaim must be an object or null")
    return value


def persisted_pause_blocks(state: dict[str, Any]) -> bool:
    """A durable user pause wins over a caller's optimistic command-line flag."""
    return state.get("user_paused") is True


def sync_top_level(state: dict[str, Any], *, status: str, owner: str | None, at: dt.datetime) -> None:
    """Keep the canonical state summary current without rewriting unrelated fields."""
    state["status"] = status
    state["owner_thread_id"] = owner
    state["updated_at"] = iso(at)


def write_state(path: Path, state: dict[str, Any]) -> None:
    encoded = json.dumps(state, sort_keys=True, indent=2) + "\n"
    fd, temporary = tempfile.mkstemp(prefix=path.name + ".", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as file:
            file.write(encoded)
            file.flush()
            os.fsync(file.fileno())
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def public_state(state: dict[str, Any]) -> dict[str, Any]:
    value = state.get("researchContinuation")
    if not isinstance(value, dict):
        return {"activeClaim": None, "historyCount": 0}
    history = value.get("history")
    return {
        "activeClaim": value.get("activeClaim") if isinstance(value.get("activeClaim"), dict) else None,
        "historyCount": len(history) if isinstance(history, list) else None,
    }


def check_branch(branch: str) -> None:
    if branch != BRANCH:
        raise Refused("branch must be " + BRANCH)


def fallback_evidence(args: argparse.Namespace, now: dt.datetime) -> dict[str, Any]:
    # Exact strings prevent a low/unknown percentage from being silently treated as exhaustion.
    if args.ordinary_usage != "exhausted":
        raise Refused("fallback requires explicit ordinary-usage=exhausted; unknown or low is refused")
    if args.spark_available != "true":
        raise Refused("fallback requires spark-available=true")
    if args.primary_task_running != "false":
        raise Refused("fallback requires primary-task-running=false")
    if args.user_paused != "false":
        raise Refused("fallback is forbidden while user-paused is not explicitly false")
    if not args.evidence_at:
        raise Refused("fallback requires evidence-at")
    observed = parse_time(args.evidence_at)
    age = (now - observed).total_seconds()
    if age < 0 or age > MAX_EVIDENCE_AGE_SECONDS:
        raise Refused("fallback evidence must be fresh and not from the future")
    return {
        "ordinaryUsage": "exhausted",
        "sparkAvailable": True,
        "primaryTaskRunning": False,
        "userPaused": False,
        "observedAt": iso(observed),
    }


def claim(path: Path, args: argparse.Namespace) -> dict[str, Any]:
    require_owner(args.owner_thread)
    check_branch(args.branch)
    if args.mode == "explicit" and (args.takeover_owner_thread or args.prior_owner_running):
        raise Refused("explicit mode cannot take over an active owner")
    if args.mode == "fallback" and bool(args.takeover_owner_thread) != bool(args.prior_owner_running):
        raise Refused("takeover-owner-thread and prior-owner-running must be supplied together")
    now = utc_now()
    if args.mode == "fallback":
        evidence = fallback_evidence(args, now)
    else:
        if args.user_paused != "false":
            raise Refused("explicit continuation is forbidden while user-paused is not explicitly false")
        evidence = {"userPaused": False}
    with locked_state(path, write=True) as (state, _):
        if persisted_pause_blocks(state):
            raise Refused("persisted user_paused=true blocks every claim until the owner clears it elsewhere")
        value = section(state)
        active = value["activeClaim"]
        if active is not None:
            if args.mode != "fallback" or not args.takeover_owner_thread:
                raise Refused("another active owner exists; no stale-timeout takeover is permitted")
            if args.prior_owner_running != "false":
                raise Refused("takeover requires prior-owner-running=false")
            if args.takeover_owner_thread != active.get("ownerThread"):
                raise Refused("takeover-owner-thread must exactly match the active owner")
            value["history"].append({"event": "handoff", "at": iso(now),
                                     "fromOwnerThread": active.get("ownerThread"),
                                     "toOwnerThread": args.owner_thread,
                                     "displacedClaim": active,
                                     "evidence": evidence})
        elif args.takeover_owner_thread:
            raise Refused("takeover requires an active owner")
        entry = {"ownerThread": args.owner_thread, "branch": args.branch, "mode": args.mode,
                 "ownerKind": "codex-spark" if args.mode == "fallback" else "codex-astra",
                 "claimedAt": iso(now), "evidence": evidence}
        value["activeClaim"] = entry
        value["history"].append({"event": "claim", **entry})
        sync_top_level(state, status="active", owner=args.owner_thread, at=now)
        write_state(path, state)
        return public_state(state)


def checkpoint(path: Path, args: argparse.Namespace) -> dict[str, Any]:
    require_owner(args.owner_thread)
    with locked_state(path, write=True) as (state, _):
        value = section(state)
        active = value["activeClaim"]
        if active is None or active.get("ownerThread") != args.owner_thread:
            raise Refused("checkpoint requires the current active owner")
        event = {"event": "checkpoint", "ownerThread": args.owner_thread, "at": iso(utc_now())}
        if args.note is not None:
            event["note"] = args.note
        value["history"].append(event)
        sync_top_level(state, status="active", owner=args.owner_thread, at=utc_now())
        write_state(path, state)
        return public_state(state)


def release(path: Path, args: argparse.Namespace) -> dict[str, Any]:
    require_owner(args.owner_thread)
    with locked_state(path, write=True) as (state, _):
        value = section(state)
        active = value["activeClaim"]
        if active is None or active.get("ownerThread") != args.owner_thread:
            raise Refused("release requires the current active owner")
        released = utc_now()
        value["history"].append({"event": "release", "ownerThread": args.owner_thread,
                                 "releasedAt": iso(released), "priorClaim": active})
        value["activeClaim"] = None
        sync_top_level(state, status="released", owner=None, at=released)
        write_state(path, state)
        return public_state(state)


def status(path: Path) -> dict[str, Any]:
    with locked_state(path, write=False) as (state, _):
        return public_state(state)


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    root.add_argument("--state", type=Path, required=True, help="JSON state path; caller owns its location")
    commands = root.add_subparsers(dest="command", required=True)
    commands.add_parser("status")
    for name in ("claim", "checkpoint", "release"):
        command = commands.add_parser(name)
        command.add_argument("--owner-thread", required=True)
        if name == "claim":
            command.add_argument("--branch", required=True)
            command.add_argument("--mode", choices=("explicit", "fallback"), required=True)
            command.add_argument("--user-paused", choices=("true", "false"), required=True)
            command.add_argument("--ordinary-usage", choices=("exhausted", "low", "unknown"))
            command.add_argument("--spark-available", choices=("true", "false"))
            command.add_argument("--primary-task-running", choices=("true", "false"))
            command.add_argument("--evidence-at")
            command.add_argument("--takeover-owner-thread")
            command.add_argument("--prior-owner-running", choices=("true", "false"))
        elif name == "checkpoint":
            command.add_argument("--note")
    return root


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        if args.command == "status":
            result = status(args.state)
        elif args.command == "claim":
            result = claim(args.state, args)
        elif args.command == "checkpoint":
            result = checkpoint(args.state, args)
        else:
            result = release(args.state, args)
    except Refused as error:
        print(json.dumps({"ok": False, "refused": str(error)}, sort_keys=True), file=sys.stderr)
        return 2
    print(json.dumps({"ok": True, **result}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
