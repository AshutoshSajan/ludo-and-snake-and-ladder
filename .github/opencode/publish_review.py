#!/usr/bin/env python3
"""Publish an OpenCode review artifact to a GitHub pull request.

Security posture:
  * This script runs from the *base* commit (checked out by the workflow), not
    from the pull request head, so a PR cannot rewrite the publisher.
  * The artifact is untrusted data. Every path, line and body is validated
    before it reaches the API; malformed findings are dropped or folded into
    the summary, never executed or interpolated into a shell.
  * The review event is always COMMENT. The bot never approves, requests
    changes, merges, or resolves anything.
  * Re-running the same head SHA is a no-op: the existing review is found by
    its hidden marker, so a retry cannot spam the pull request.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any

from github_api import (
    GitHubError,
    REPO_RE,
    SHA_RE,
    current_bot_login,
    gh_json,
    gh_list,
    log,
    warn,
)
from review_lib import (
    Finding,
    ParseError,
    build_error_body,
    build_review_body,
    format_inline_body,
    parse_diff,
    parse_review_output,
    sanitize_text,
    validate_findings,
    MAX_INLINE_COMMENTS,
)

REVIEW_MARKER = "<!-- opencode-review -->"
ERROR_MARKER = "<!-- opencode-review:error -->"


def check_pr_is_current(repo: str, pr: int, head_sha: str) -> bool:
    pr_data = gh_json("GET", f"repos/{repo}/pulls/{pr}")
    if not isinstance(pr_data, dict):
        raise GitHubError("unexpected pull request response")
    if pr_data.get("state") != "open":
        log(f"pull request #{pr} is {pr_data.get('state')!r}; skipping")
        return False
    actual = (pr_data.get("head") or {}).get("sha")
    if actual != head_sha:
        log(
            f"a newer commit is on the pull request (artifact {head_sha[:12]}, "
            f"current {str(actual)[:12]}); skipping the stale artifact"
        )
        return False
    return True


def find_existing_review(
    repo: str, pr: int, head_sha: str, bot_login: str
) -> dict[str, Any] | None:
    reviews = gh_list(f"repos/{repo}/pulls/{pr}/reviews?per_page=100")
    for review in reversed(reviews):
        user = review.get("user") or {}
        body = review.get("body") or ""
        if (
            user.get("login") == bot_login
            and REVIEW_MARKER in body
            and review.get("commit_id") == head_sha
        ):
            return review
    return None


def find_bot_comment(
    repo: str, pr: int, marker: str, bot_login: str
) -> dict[str, Any] | None:
    comments = gh_list(f"repos/{repo}/issues/{pr}/comments?per_page=100")
    for comment in reversed(comments):
        user = comment.get("user") or {}
        body = comment.get("body") or ""
        if user.get("login") == bot_login and marker in body:
            return comment
    return None


def upsert_error_comment(
    repo: str, pr: int, bot_login: str, body: str
) -> None:
    existing = find_bot_comment(repo, pr, ERROR_MARKER, bot_login)
    if existing and isinstance(existing.get("id"), int):
        gh_json(
            "PATCH",
            f"repos/{repo}/issues/comments/{existing['id']}",
            payload={"body": body},
        )
        log("updated the existing parse-failure notice")
        return
    gh_json(
        "POST",
        f"repos/{repo}/issues/{pr}/comments",
        payload={"body": body},
    )
    log("posted a parse-failure notice")


def mark_error_comment_superseded(
    repo: str, pr: int, bot_login: str, head_sha: str
) -> None:
    existing = find_bot_comment(repo, pr, ERROR_MARKER, bot_login)
    if not existing or not isinstance(existing.get("id"), int):
        return
    body = "\n".join(
        [
            ERROR_MARKER,
            "_This earlier parse failure was superseded by a successful "
            f"OpenCode review on commit `{head_sha[:12]}`._",
        ]
    )
    try:
        gh_json(
            "PATCH",
            f"repos/{repo}/issues/comments/{existing['id']}",
            payload={"body": body},
        )
        log("marked the earlier parse-failure notice as superseded")
    except GitHubError as exc:
        warn(f"could not update the earlier parse-failure notice: {exc}")


def review_payload(
    *,
    head_sha: str,
    body: str,
    findings: list[Finding],
) -> dict[str, Any]:
    return {
        "commit_id": head_sha,
        "event": "COMMENT",
        "body": body,
        "comments": [
            {
                "path": finding.path,
                "line": finding.line,
                "side": finding.side,
                "body": format_inline_body(finding),
            }
            for finding in findings
        ],
    }


def post_review(repo: str, pr: int, payload: dict[str, Any]) -> dict[str, Any]:
    result = gh_json(
        "POST",
        f"repos/{repo}/pulls/{pr}/reviews",
        payload=payload,
    )
    if not isinstance(result, dict):
        return {}
    return result


def fold_all_findings(
    *,
    summary: str,
    model: str,
    head_sha: str,
    valid: list[Finding],
    folded: list[Finding],
    discarded: int,
    omitted: int,
    diff_truncated: bool,
) -> str:
    return build_review_body(
        summary=summary
        + "\n\n_GitHub rejected the inline position for one or more comments, so "
        "every finding is listed below._",
        model=model,
        head_sha=head_sha,
        valid=[],
        folded=valid + folded,
        discarded=discarded,
        omitted=omitted,
        diff_truncated=diff_truncated,
    )


def read_text(path: Path, limit: int = 2_000_000) -> str:
    try:
        with path.open("rb") as handle:
            data = handle.read(limit + 1)
    except FileNotFoundError:
        return ""
    if len(data) > limit:
        data = data[:limit]
    return data.decode("utf-8", errors="replace")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifact-dir", required=True, type=Path)
    parser.add_argument("--pr", required=True, type=int)
    parser.add_argument("--head-sha", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument(
        "--repo",
        default=os.environ.get("GITHUB_REPOSITORY", ""),
        help="owner/repo (defaults to GITHUB_REPOSITORY)",
    )
    parser.add_argument(
        "--run-url",
        default="",
        help="workflow run URL used in the parse-failure notice",
    )
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument(
        "--max-inline", type=int, default=MAX_INLINE_COMMENTS
    )
    args = parser.parse_args(argv)

    model = sanitize_text(args.model, 120).replace("\n", " ")
    if not model:
        parser.error("--model is empty")
    if not SHA_RE.fullmatch(args.head_sha):
        parser.error("--head-sha is not a commit SHA")
    if args.pr <= 0:
        parser.error("--pr must be positive")
    if args.max_inline <= 0:
        parser.error("--max-inline must be positive")

    repo = args.repo
    if not args.dry_run:
        if not repo:
            parser.error("--repo is required (or set GITHUB_REPOSITORY)")
        if not REPO_RE.fullmatch(repo):
            parser.error("--repo is not owner/repo")
        if not (os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")):
            parser.error("GH_TOKEN or GITHUB_TOKEN must be set")

    artifact_dir = args.artifact_dir
    output = read_text(artifact_dir / "review-output.txt")
    diff = read_text(artifact_dir / "pr.diff")
    truncated = read_text(artifact_dir / "diff-truncated.txt").strip() == "1"

    try:
        parsed = parse_review_output(output)
    except ParseError as exc:
        reason = str(exc)
        log(f"model output could not be parsed: {reason}")
        body = build_error_body(
            model=model,
            head_sha=args.head_sha,
            run_url=args.run_url or "(workflow run)",
            reason=reason,
        )
        if args.dry_run:
            print(body)
            return 0
        if not check_pr_is_current(repo, args.pr, args.head_sha):
            return 0
        bot_login = current_bot_login()
        try:
            upsert_error_comment(repo, args.pr, bot_login, body)
        except GitHubError as api_exc:
            print(f"could not post the parse-failure notice: {api_exc}", file=sys.stderr)
            if api_exc.detail:
                print(api_exc.detail, file=sys.stderr)
            return 1
        # The comment is the user-visible signal; do not turn the whole PR
        # check red for a model that did not follow the JSON contract.
        return 0

    summary = parsed["summary"]
    raw_comments = parsed["comments"]
    diff_index = parse_diff(diff)
    validation = validate_findings(
        raw_comments, diff_index, max_inline=args.max_inline
    )

    log(
        f"parsed {len(raw_comments)} comment(s): "
        f"{len(validation.valid)} inline, {len(validation.folded)} folded, "
        f"{validation.discarded} discarded, {validation.omitted} omitted"
    )

    body = build_review_body(
        summary=summary,
        model=model,
        head_sha=args.head_sha,
        valid=validation.valid,
        folded=validation.folded,
        discarded=validation.discarded,
        omitted=validation.omitted,
        diff_truncated=truncated,
    )
    payload = review_payload(
        head_sha=args.head_sha,
        body=body,
        findings=validation.valid,
    )

    if args.dry_run:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return 0

    if not check_pr_is_current(repo, args.pr, args.head_sha):
        return 0

    bot_login = current_bot_login()
    existing = find_existing_review(repo, args.pr, args.head_sha, bot_login)
    if existing:
        # A re-run on the same commit would duplicate every inline comment.
        # The first review is kept; push a new commit for a fresh pass.
        log(
            "an OpenCode review already exists for this commit "
            f"({existing.get('html_url') or existing.get('id')}); skipping"
        )
        return 0

    try:
        posted = post_review(repo, args.pr, payload)
        log(
            "posted an OpenCode review "
            f"({posted.get('html_url') or posted.get('id') or 'ok'})"
        )
    except GitHubError as exc:
        if exc.status != 422 or not payload["comments"]:
            print(f"could not post the review: {exc}", file=sys.stderr)
            if exc.detail:
                print(exc.detail, file=sys.stderr)
            return 1

        warn(
            "GitHub rejected the inline comments (422); retrying with every "
            "finding folded into the review summary"
        )
        fallback_body = fold_all_findings(
            summary=summary,
            model=model,
            head_sha=args.head_sha,
            valid=validation.valid,
            folded=validation.folded,
            discarded=validation.discarded,
            omitted=validation.omitted,
            diff_truncated=truncated,
        )
        fallback_payload = review_payload(
            head_sha=args.head_sha,
            body=fallback_body,
            findings=[],
        )
        try:
            posted = post_review(repo, args.pr, fallback_payload)
            log(
                "posted the review without inline comments "
                f"({posted.get('html_url') or posted.get('id') or 'ok'})"
            )
        except GitHubError as fallback_exc:
            print(f"could not post the fallback review: {fallback_exc}", file=sys.stderr)
            if fallback_exc.detail:
                print(fallback_exc.detail, file=sys.stderr)
            return 1

    mark_error_comment_superseded(repo, args.pr, bot_login, args.head_sha)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
