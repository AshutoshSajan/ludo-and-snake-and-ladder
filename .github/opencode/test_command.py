#!/usr/bin/env python3
"""Unit tests for the trusted-command parsing and context builders."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import command
from command import (
    bound_messages,
    build_discussion_context,
    cap_text,
    clean_reply,
    is_resolve,
    is_triggered,
    is_trusted_comment,
    one_line,
    parse_event,
    strip_trigger,
    with_footer,
)


def review_comment(**overrides):
    data = {
        "id": 11,
        "body": "@opencode why is this null?",
        "author_association": "MEMBER",
        "user": {"login": "maintainer", "type": "User"},
        "created_at": "2026-01-01T00:00:00Z",
        "path": "lib/foo.dart",
        "line": 3,
    }
    data.update(overrides)
    return data


class TriggerTests(unittest.TestCase):
    def test_mentions_and_slash_commands(self):
        for body in (
            "@opencode hello",
            "/opencode hello",
            "hey @opencode can you look?",
            "please ask /opencode about this",
            "`@opencode`",
            "@opencode",
        ):
            with self.subTest(body=body):
                self.assertTrue(is_triggered(body))

    def test_non_triggers(self):
        for body in (
            "foo@opencode.ai",
            "@opencodeai hello",
            "https://opencode.ai/docs",
            "https://example.test//opencode",
            "no command here",
            "",
        ):
            with self.subTest(body=body):
                self.assertFalse(is_triggered(body))

    def test_resolve_is_anchored(self):
        for body in ("/opencode resolve", "  @opencode resolve  ", "/opencode resolve."):
            with self.subTest(body=body):
                self.assertTrue(is_resolve(body))
        for body in (
            "/opencode resolve this too",
            "please /opencode resolve",
            "/opencode answer a question",
            "",
        ):
            with self.subTest(body=body):
                self.assertFalse(is_resolve(body))

    def test_strip_trigger_removes_only_the_first_mention(self):
        self.assertEqual(strip_trigger("@opencode why?"), "why?")
        self.assertEqual(strip_trigger("hey @opencode why?"), "hey  why?")
        self.assertEqual(strip_trigger("/opencode: explain"), "explain")
        self.assertEqual(strip_trigger("no command"), "no command")


class TrustTests(unittest.TestCase):
    def test_trusted_associations(self):
        for association in ("OWNER", "MEMBER", "COLLABORATOR"):
            with self.subTest(association=association):
                self.assertTrue(
                    is_trusted_comment(
                        review_comment(author_association=association)
                    )
                )

    def test_untrusted_authors(self):
        for comment in (
            review_comment(author_association="CONTRIBUTOR"),
            review_comment(author_association="NONE"),
            review_comment(author_association="FIRST_TIME_CONTRIBUTOR"),
            review_comment(user={"login": "dependabot[bot]", "type": "Bot"}),
            review_comment(user={"login": "some-bot[bot]", "type": "User"}),
            review_comment(user={}),
            {},
            None,
        ):
            with self.subTest(comment=comment):
                self.assertFalse(is_trusted_comment(comment))


class ParseEventTests(unittest.TestCase):
    def test_review_comment_event(self):
        ctx = parse_event(
            "pull_request_review_comment",
            {
                "action": "created",
                "comment": review_comment(id=42),
                "pull_request": {"number": 7},
            },
        )
        self.assertIsNotNone(ctx)
        assert ctx is not None
        self.assertEqual(ctx.pr, 7)
        self.assertEqual(ctx.comment_id, 42)
        self.assertTrue(ctx.is_review_thread)
        self.assertEqual(ctx.action, "created")

    def test_issue_comment_on_a_pull_request(self):
        ctx = parse_event(
            "issue_comment",
            {
                "action": "created",
                "issue": {"number": 8, "pull_request": {"url": "x"}},
                "comment": review_comment(id=43, path=None, line=None),
            },
        )
        self.assertIsNotNone(ctx)
        assert ctx is not None
        self.assertEqual(ctx.pr, 8)
        self.assertFalse(ctx.is_review_thread)

    def test_issue_comment_on_a_plain_issue_is_ignored(self):
        self.assertIsNone(
            parse_event(
                "issue_comment",
                {
                    "action": "created",
                    "issue": {"number": 8},
                    "comment": review_comment(),
                },
            )
        )

    def test_other_events_are_ignored(self):
        self.assertIsNone(parse_event("pull_request", {"action": "opened"}))
        self.assertIsNone(parse_event("push", {"action": "created"}))

    def test_missing_ids_are_ignored(self):
        self.assertIsNone(
            parse_event(
                "pull_request_review_comment",
                {"comment": {}, "pull_request": {"number": 7}},
            )
        )
        self.assertIsNone(
            parse_event(
                "pull_request_review_comment",
                {"comment": {"id": 1}, "pull_request": {}},
            )
        )


class BoundingTests(unittest.TestCase):
    def message(self, index: int, body: str | None = None):
        return {
            "id": index,
            "body": body if body is not None else f"body {index}",
            "created_at": f"2026-01-01T00:00:{index:02d}Z",
            "user": {"login": f"user{index}"},
        }

    def test_count_cap_keeps_the_most_recent(self):
        text, included, omitted = bound_messages(
            [self.message(i) for i in range(25)],
            max_messages=20,
            max_chars=100_000,
        )
        self.assertEqual(included, 20)
        self.assertEqual(omitted, 5)
        self.assertNotIn("body 4", text)
        self.assertIn("body 5", text)
        self.assertIn("body 24", text)

    def test_char_cap_drops_oldest_first(self):
        messages = [self.message(i, body="x" * 100) for i in range(20)]
        text, included, omitted = bound_messages(
            messages, max_messages=20, max_chars=550
        )
        self.assertLessEqual(len(text), 550)
        self.assertLess(included, 20)
        self.assertEqual(included + omitted, 20)

    def test_empty_discussion(self):
        text, included, omitted = bound_messages([], max_messages=20, max_chars=100)
        self.assertEqual(text, "")
        self.assertEqual(included, 0)
        self.assertEqual(omitted, 0)

    def test_one_line_and_cap_text(self):
        self.assertEqual(one_line(" a\n b\tc ", 100), "a b c")
        self.assertEqual(one_line(None, 100), "")
        self.assertEqual(cap_text("abc", 10), "abc")
        self.assertIn("_(truncated)_", cap_text("x" * 20, 10))
        self.assertEqual(cap_text(None, 10), "")


class ContextTests(unittest.TestCase):
    def test_context_contains_request_description_discussion_and_diff(self):
        context = build_discussion_context(
            repo="owner/repo",
            pr=7,
            title="Fix the thing",
            base_sha="a" * 40,
            head_sha="b" * 40,
            files_total=2,
            pr_body="PR body",
            request="Why is this null?",
            discussion="**@maintainer**\n\ncontext message",
            discussion_omitted=0,
            diff_text="+new",
            diff_truncated=False,
        )
        self.assertIn("Pull request: #7 — Fix the thing", context)
        self.assertIn("## Current request", context)
        self.assertIn("Why is this null?", context)
        self.assertIn("PR body", context)
        self.assertIn("context message", context)
        self.assertIn("````diff", context)
        self.assertIn("+new", context)
        self.assertNotIn("capped", context)

    def test_context_notes_omissions_and_truncation(self):
        context = build_discussion_context(
            repo="owner/repo",
            pr=7,
            title="t",
            base_sha="a" * 40,
            head_sha="b" * 40,
            files_total=2,
            pr_body="",
            request="q",
            discussion="",
            discussion_omitted=3,
            diff_text="",
            diff_truncated=True,
        )
        self.assertIn("3 earlier message(s) were omitted", context)
        self.assertIn("was capped before this message", context)


class ReplyTests(unittest.TestCase):
    def test_clean_reply_removes_comments_and_mentions(self):
        reply = clean_reply(
            "<!-- ignore me -->\nHello @team\n<opencode_review>text</opencode_review>"
        )
        self.assertNotIn("ignore me", reply)
        self.assertIn("@\u200bteam", reply)
        self.assertNotIn("<opencode_review>", reply)

    def test_clean_reply_caps(self):
        reply = clean_reply("x" * (command.MAX_REPLY_CHARS + 100))
        self.assertIn("_(truncated)_", reply)

    def test_with_footer_marks_the_comment(self):
        body = with_footer("hello", model="opencode/model", run_url="https://example.test/run")
        self.assertIn("hello", body)
        self.assertIn(command.COMMAND_MARKER, body)
        self.assertIn("https://example.test/run", body)

    def test_with_footer_omits_an_unsafe_url(self):
        body = with_footer("hello", model="m", run_url="javascript:alert(1)")
        self.assertNotIn("javascript:", body)

    def test_failure_reply_does_not_echo_raw_output(self):
        body = command.failure_reply(
            reason="The model timed out.", model="m", run_url=""
        )
        self.assertIn("could not answer", body)
        self.assertIn("The model timed out.", body)


if __name__ == "__main__":
    unittest.main()
