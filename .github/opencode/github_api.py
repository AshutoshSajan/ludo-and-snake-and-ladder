#!/usr/bin/env python3
"""Small, shell-free GitHub API helpers shared by the OpenCode workflows.

Every call goes through the GitHub CLI with an argument list, never a shell.
Callers keep their own policy (which endpoint, what payload); this module only
turns failures into a typed error and removes the token from anything it logs.
"""

from __future__ import annotations

import json
import re
import shutil
import subprocess
from typing import Any

REPO_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
SHA_RE = re.compile(r"^[0-9a-fA-F]{7,64}$")


class GitHubError(RuntimeError):
    def __init__(self, message: str, *, status: int | None = None, detail: str = ""):
        super().__init__(message)
        self.status = status
        self.detail = detail


def log(message: str) -> None:
    print(message, flush=True)


def warn(message: str) -> None:
    print(f"::warning::{message}", flush=True)


def _run(args: list[str], *, input_text: str | None = None) -> str:
    if shutil.which("gh") is None:
        raise GitHubError("the GitHub CLI (gh) is not installed")
    proc = subprocess.run(
        args,
        input=input_text,
        text=True,
        capture_output=True,
        check=False,
    )
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "").strip()
        # gh prints the HTTP status in stderr for API failures; keep the
        # original detail for the job log, but never include the token.
        status = None
        match = re.search(r"HTTP (\d{3})", detail)
        if match:
            status = int(match.group(1))
        raise GitHubError(
            "GitHub API call failed",
            status=status,
            detail=detail[:4000],
        )
    return proc.stdout


def gh_api(
    method: str,
    endpoint: str,
    *,
    payload: dict[str, Any] | None = None,
    paginate: bool = False,
) -> str:
    args = ["gh", "api", "--method", method, endpoint]
    if paginate:
        args += ["--paginate", "--slurp"]
    input_text = None
    if payload is not None:
        args += ["--input", "-"]
        input_text = json.dumps(payload, ensure_ascii=False)
    return _run(args, input_text=input_text)


def gh_json(method: str, endpoint: str, **kwargs: Any) -> Any:
    output = gh_api(method, endpoint, **kwargs)
    if not output.strip():
        return None
    return json.loads(output)


def gh_list(endpoint: str) -> list[dict[str, Any]]:
    output = gh_api("GET", endpoint, paginate=True)
    if not output.strip():
        return []
    data = json.loads(output)
    if isinstance(data, list):
        # --slurp wraps every page in an outer array.
        if data and all(isinstance(page, list) for page in data):
            return [item for page in data for item in page]
        return [item for item in data if isinstance(item, dict)]
    return []


def graphql(query: str, variables: dict[str, Any] | None = None) -> dict[str, Any]:
    args = ["gh", "api", "graphql", "-f", f"query={query}"]
    for key, value in (variables or {}).items():
        if value is None:
            continue
        if isinstance(value, int) and not isinstance(value, bool):
            args += ["-F", f"{key}={value}"]
        else:
            args += ["-f", f"{key}={value}"]
    output = _run(args)
    if not output.strip():
        return {}
    data = json.loads(output)
    return data if isinstance(data, dict) else {}


def current_bot_login() -> str:
    try:
        user = gh_json("GET", "user")
    except GitHubError:
        return "github-actions[bot]"
    if isinstance(user, dict) and isinstance(user.get("login"), str):
        return user["login"]
    return "github-actions[bot]"
