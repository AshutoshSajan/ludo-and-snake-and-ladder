#!/usr/bin/env python3
"""Refuse checkout symlinks that resolve outside the review workspace.

This runs from the trusted base checkout, before the model process starts, so
it is repository code — never change-under-review code. The reviewer's read,
glob, and grep tools authorize lexical paths, and their implementations follow
symlinks after that authorization: a pull request could commit one link to
/proc/self/environ and fish the reviewer's own provider key (which the model
process carries as OPENCODE_API_KEY, per the workflow's deliberate design, and
which its child processes inherit) or any other readable file on the runner
through an otherwise-permitted search (CWE-61). A boundary that only checks
the printed path is not a boundary — the final canonical target has to be
inside the workspace, or the link does not survive checkout.

Refusing means removing the LINK, before the model runs; the review itself
continues on a schedule where the path is simply no longer traversable.
Nothing outside the workspace is read, opened, written, or deleted in the
process: resolving happens in the script's imagination (realpath of the
lexical target), and unlinking touches only in-workspace link entries. Links
that stay inside the workspace — including dangling ones — are kept untouched.
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path


def is_inside(target: Path, root: Path) -> bool:
    """True when the canonical [target] cannot leave the workspace [root]."""
    return target.is_relative_to(root)


def find_escaped_links(workspace: Path) -> list[tuple[Path, Path]]:
    """Every symlink under [workspace] whose canonical target leaves it.

    Returns `(link, canonical_target)` pairs. The walk never follows symlinked
    directories, so the traversal cannot loop regardless of what the checkout
    contains; a symlinked directory is examined as the link entry itself.
    Both file- and directory-symlinks are returned — a directory link is
    exactly as followable by a search as a file link is.
    """
    root = workspace.resolve()
    escaped: list[tuple[Path, Path]] = []
    walker = os.walk(workspace, followlinks=False)
    for dirpath, dirnames, filenames in walker:
        here = Path(dirpath)
        for name in (*dirnames, *filenames):
            link = here / name
            if not link.is_symlink():
                continue
            # strict=False: a dangling link resolves to its lexical target,
            # so refusing dangling outside-workspace links is decided the
            # same way as refusing live ones — by where the path points.
            target = Path(os.path.realpath(link, strict=False))
            if not is_inside(target, root):
                escaped.append((link, target))
    return escaped


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace", required=True, type=Path)
    args = parser.parse_args(argv)

    if not args.workspace.is_dir():
        parser.error(f"--workspace is not a directory: {args.workspace}")

    escaped = find_escaped_links(args.workspace)
    for link, target in escaped:
        try:
            # The link is unlinked, its destination is never opened — the
            # operation cannot touch anything outside the workspace.
            link.unlink()
        except OSError as exc:
            print(f"::warning::could not remove {link}: {exc}", file=sys.stderr)
    if escaped:
        print(
            f"::warning::Removed {len(escaped)} checkout symlink(s) whose "
            "target leaves the workspace; the review continues without them."
        )
        for link, target in escaped:
            print(f"  refused: {link} -> {target}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
