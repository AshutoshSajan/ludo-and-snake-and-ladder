#!/usr/bin/env python3
"""Build the bounded review context and diff artifact for one pull request.

This runs from the trusted base checkout. The workspace is the pull request
head, so nothing here executes or imports anything from the change under
review. Git is given explicit arguments; no shell is involved.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

from review_lib import build_review_context, limit_diff

SHA_RE = re.compile(r"^[0-9a-fA-F]{7,64}$")


def run_git(workspace: Path, *args: str) -> bytes:
    proc = subprocess.run(
        ["git", "-C", str(workspace), *args],
        capture_output=True,
        check=False,
    )
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or b"").decode(
            "utf-8", errors="replace"
        )
        print(detail[:2000], file=sys.stderr)
        raise SystemExit(f"git {' '.join(args[:3])} failed")
    return proc.stdout


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--base-sha", required=True)
    parser.add_argument("--head-sha", required=True)
    parser.add_argument("--repo", required=True)
    args = parser.parse_args(argv)

    for name, value in (("base-sha", args.base_sha), ("head-sha", args.head_sha)):
        if not SHA_RE.fullmatch(value):
            parser.error(f"--{name} is not a commit SHA")

    if not args.workspace.is_dir():
        parser.error(f"--workspace is not a directory: {args.workspace}")

    span = f"{args.base_sha}...{args.head_sha}"
    diff_bytes = run_git(
        args.workspace,
        "diff",
        "--no-color",
        "--no-ext-diff",
        "--unified=3",
        span,
        "--",
    )
    changed_raw = run_git(
        args.workspace,
        "diff",
        "--name-only",
        "-z",
        span,
        "--",
    )
    changed_files = [
        part.decode("utf-8", errors="replace")
        for part in changed_raw.split(b"\0")
        if part
    ]

    diff_text = diff_bytes.decode("utf-8", errors="replace")
    limited = limit_diff(diff_text)
    context = build_review_context(
        repo=args.repo,
        base_sha=args.base_sha,
        head_sha=args.head_sha,
        changed_files=changed_files,
        diff_text=limited.text,
        truncated=limited.truncated,
        files_total=len(changed_files),
    )

    output_dir = args.output_dir
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "context.md").write_text(context, encoding="utf-8")
    (output_dir / "pr.diff").write_text(limited.text, encoding="utf-8")
    (output_dir / "diff-truncated.txt").write_text(
        "1\n" if limited.truncated else "0\n", encoding="utf-8"
    )
    (output_dir / "meta.json").write_text(
        json.dumps(
            {
                "repo": args.repo,
                "base_sha": args.base_sha,
                "head_sha": args.head_sha,
                "changed_files": changed_files,
                "files_total": len(changed_files),
                "files_kept": limited.files_kept,
                "diff_truncated": limited.truncated,
            },
            ensure_ascii=False,
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )

    print(
        f"prepared {len(changed_files)} changed file(s); "
        f"{limited.files_kept} in the diff; "
        f"truncated={str(limited.truncated).lower()}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
