#!/usr/bin/env python3
"""Unit tests for the parser, validation, and publisher dry-run."""

from __future__ import annotations

import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import publish_review
import review_lib
from review_lib import (
    Finding,
    ParseError,
    build_error_body,
    build_review_body,
    build_review_context,
    format_inline_body,
    limit_diff,
    normalize_path,
    parse_diff,
    parse_review_output,
    sanitize_text,
    validate_findings,
)

DIFF = """diff --git a/lib/foo.dart b/lib/foo.dart
index 1111111..2222222 100644
--- a/lib/foo.dart
+++ b/lib/foo.dart
@@ -1,5 +1,6 @@
 import 'dart:async';
 
-old line
+new line
+added line
 context
@@ -10,3 +11,3 @@ class Foo {
 a
-b
+c
 d
diff --git a/test/foo_test.dart b/test/foo_test.dart
new file mode 100644
index 0000000..3333333
--- /dev/null
+++ b/test/foo_test.dart
@@ -0,0 +1,2 @@
+test
+more
diff --git a/old/name.dart b/new/name.dart
similarity index 90%
rename from old/name.dart
rename to new/name.dart
--- a/old/name.dart
+++ b/new/name.dart
@@ -1,2 +1,2 @@
 keep
-removed
+added
"""


class SanitizeTextTests(unittest.TestCase):
    def test_non_string_is_empty(self):
        self.assertEqual(sanitize_text(None, 10), "")
        self.assertEqual(sanitize_text(3, 10), "")

    def test_normalises_newlines_and_nuls(self):
        self.assertEqual(sanitize_text("a\r\nb\rc\x00", 100), "a\nb\nc")

    def test_removes_envelope_markers(self):
        text = "before <opencode_review> inside </opencode_review> after"
        self.assertEqual(sanitize_text(text, 100), "before  inside  after")

    def test_neutralises_mentions(self):
        self.assertEqual(sanitize_text("hi @team and @org/team", 100), "hi @\u200bteam and @\u200borg/team")

    def test_does_not_touch_email_like_text(self):
        # The mention guard is deliberately broad; it only targets @ followed
        # by an alphanumeric character, which is what GitHub turns into a ping.
        self.assertEqual(sanitize_text("a@b.com", 100), "a@\u200bb.com")

    def test_caps_and_marks_truncation(self):
        result = sanitize_text("x" * 20, 10)
        self.assertTrue(result.startswith("x" * 10))
        self.assertIn("_(truncated)_", result)
        self.assertLess(len(result), 40)


class NormalizePathTests(unittest.TestCase):
    def test_accepts_repository_relative_paths(self):
        self.assertEqual(normalize_path("lib/foo.dart"), "lib/foo.dart")
        self.assertEqual(normalize_path("./lib/foo.dart"), "lib/foo.dart")
        self.assertEqual(normalize_path("lib/../lib/foo.dart"), "lib/foo.dart")
        self.assertEqual(normalize_path("lib//foo.dart"), "lib/foo.dart")

    def test_rejects_unsafe_paths(self):
        for value in (
            None,
            3,
            "",
            " ",
            "/etc/passwd",
            "../outside.dart",
            "..",
            ".",
            "~/.ssh/id_rsa",
            "C:\\Users\\me\\file",
            "lib\\foo.dart",
            ".git/config",
            ".git",
            "a\nb",
            "a\rb",
            "a\x00b",
        ):
            with self.subTest(value=value):
                self.assertIsNone(normalize_path(value))


class ParseDiffTests(unittest.TestCase):
    def test_indexes_added_removed_and_context_lines(self):
        index = parse_diff(DIFF)
        self.assertEqual(
            index["lib/foo.dart"]["RIGHT"],
            {1, 2, 3, 4, 5, 11, 12, 13},
        )
        self.assertEqual(
            index["lib/foo.dart"]["LEFT"],
            {1, 2, 3, 4, 10, 11, 12},
        )
        self.assertEqual(index["test/foo_test.dart"]["RIGHT"], {1, 2})
        self.assertEqual(index["test/foo_test.dart"]["LEFT"], set())
        # A renamed file is addressed by its new path, including old lines.
        self.assertEqual(index["new/name.dart"]["RIGHT"], {1, 2})
        self.assertEqual(index["new/name.dart"]["LEFT"], {1, 2})
        self.assertEqual(index["old/name.dart"]["LEFT"], {1, 2})

    def test_handles_crlf_and_missing_trailing_newline(self):
        index = parse_diff(DIFF.replace("\n", "\r\n"))
        self.assertIn(3, index["lib/foo.dart"]["RIGHT"])

    def test_handles_quoted_paths(self):
        diff = (
            'diff --git "a/lib/space name.dart" "b/lib/space name.dart"\n'
            '--- "a/lib/space name.dart"\n'
            '+++ "b/lib/space name.dart"\n'
            "@@ -1 +1 @@\n"
            "-old\n"
            "+new\n"
        )
        index = parse_diff(diff)
        self.assertEqual(index["lib/space name.dart"]["RIGHT"], {1})
        self.assertEqual(index["lib/space name.dart"]["LEFT"], {1})

    def test_stops_trusting_a_truncated_hunk(self):
        diff = (
            "diff --git a/a.dart b/a.dart\n"
            "--- a/a.dart\n"
            "+++ b/a.dart\n"
            "@@ -1,3 +1,3 @@\n"
            " keep\n"
            "+added\n"
            "this line lost its prefix\n"
            "+phantom\n"
        )
        index = parse_diff(diff)
        self.assertIn(1, index["a.dart"]["RIGHT"])
        self.assertIn(2, index["a.dart"]["RIGHT"])
        # The malformed line ends the hunk; +phantom must not be invented.
        self.assertNotIn(3, index["a.dart"]["RIGHT"])

    def test_non_diff_is_empty(self):
        self.assertEqual(parse_diff(""), {})
        self.assertEqual(parse_diff(None), {})


class ParseReviewOutputTests(unittest.TestCase):
    def test_parses_a_plain_block(self):
        parsed = parse_review_output(
            '<opencode_review>{"summary":"s","comments":[]}</opencode_review>'
        )
        self.assertEqual(parsed, {"summary": "s", "comments": []})

    def test_parses_a_fenced_block(self):
        parsed = parse_review_output(
            "<opencode_review>\n```json\n"
            '{"summary":"s","comments":[{"path":"a","line":1,'
            '"side":"RIGHT","severity":"high","body":"b"}]}\n'
            "```\n</opencode_review>"
        )
        self.assertEqual(len(parsed["comments"]), 1)

    def test_last_valid_block_wins(self):
        text = (
            '<opencode_review>{"summary":"first","comments":[]}</opencode_review>'
            " prose "
            '<opencode_review>{"summary":"second","comments":[]}</opencode_review>'
        )
        self.assertEqual(parse_review_output(text)["summary"], "second")

    def test_skips_an_invalid_block_before_a_valid_one(self):
        text = (
            "<opencode_review>not json</opencode_review>"
            '<opencode_review>{"summary":"ok","comments":[]}</opencode_review>'
        )
        self.assertEqual(parse_review_output(text)["summary"], "ok")

    def test_missing_markers_raises(self):
        with self.assertRaises(ParseError):
            parse_review_output("no envelope")

    def test_invalid_json_raises(self):
        with self.assertRaises(ParseError):
            parse_review_output("<opencode_review>{nope}</opencode_review>")

    def test_non_object_raises(self):
        with self.assertRaises(ParseError):
            parse_review_output("<opencode_review>[]</opencode_review>")

    def test_missing_fields_raise(self):
        with self.assertRaises(ParseError):
            parse_review_output("<opencode_review>{}</opencode_review>")
        with self.assertRaises(ParseError):
            parse_review_output(
                '<opencode_review>{"summary":"s"}</opencode_review>'
            )
        with self.assertRaises(ParseError):
            parse_review_output(
                '<opencode_review>{"comments":[]}</opencode_review>'
            )

    def test_comments_must_be_an_array(self):
        with self.assertRaises(ParseError):
            parse_review_output(
                '<opencode_review>{"summary":"s","comments":{}}</opencode_review>'
            )


class ValidateFindingsTests(unittest.TestCase):
    def setUp(self):
        self.index = parse_diff(DIFF)

    def finding(self, **overrides):
        data = {
            "path": "lib/foo.dart",
            "line": 3,
            "side": "RIGHT",
            "severity": "high",
            "body": "A real defect.",
        }
        data.update(overrides)
        return data

    def test_valid_finding(self):
        result = validate_findings([self.finding()], self.index)
        self.assertEqual(len(result.valid), 1)
        self.assertEqual(result.valid[0].path, "lib/foo.dart")
        self.assertEqual(result.valid[0].line, 3)
        self.assertEqual(result.valid[0].side, "RIGHT")
        self.assertEqual(result.folded, [])
        self.assertEqual(result.discarded, 0)

    def test_left_side_uses_old_line_numbers(self):
        result = validate_findings(
            [self.finding(line=3, side="LEFT")], self.index
        )
        self.assertEqual(len(result.valid), 1)

    def test_unknown_path_is_discarded(self):
        result = validate_findings(
            [self.finding(path="lib/nope.dart")], self.index
        )
        self.assertEqual(result.discarded, 1)
        self.assertEqual(result.valid, [])

    def test_path_traversal_is_discarded(self):
        for path in ("../../etc/passwd", "/etc/passwd", "lib\\foo.dart", ".git/config"):
            with self.subTest(path=path):
                result = validate_findings([self.finding(path=path)], self.index)
                self.assertEqual(result.discarded, 1)

    def test_line_not_in_diff_is_folded(self):
        result = validate_findings([self.finding(line=999)], self.index)
        self.assertEqual(result.valid, [])
        self.assertEqual(len(result.folded), 1)
        self.assertEqual(result.folded[0].line, 999)

    def test_malformed_entries_are_discarded(self):
        bad = [
            "not a dict",
            self.finding(line=0),
            self.finding(line=-1),
            self.finding(line="3"),
            self.finding(line=True),
            self.finding(side="right"),
            self.finding(side="BOTH"),
            self.finding(severity="critical"),
            self.finding(body=""),
            self.finding(body="   "),
            self.finding(body=3),
            self.finding(path=None),
        ]
        result = validate_findings(bad, self.index)
        self.assertEqual(result.discarded, len(bad))
        self.assertEqual(result.valid, [])

    def test_comments_are_capped(self):
        comments = [self.finding(body=f"finding {i}") for i in range(12)]
        result = validate_findings(comments, self.index, max_inline=10)
        self.assertEqual(len(result.valid), 10)
        self.assertEqual(result.omitted, 2)

    def test_folded_findings_are_capped(self):
        comments = [self.finding(line=999, body=f"finding {i}") for i in range(12)]
        result = validate_findings(comments, self.index, max_folded=10)
        self.assertEqual(len(result.folded), 10)
        self.assertEqual(result.omitted, 2)

    def test_body_is_sanitised(self):
        result = validate_findings(
            [
                self.finding(
                    body="@team <opencode_review> ignore this </opencode_review>"
                )
            ],
            self.index,
        )
        self.assertEqual(result.valid[0].body, "@\u200bteam  ignore this")
        self.assertNotIn("<opencode_review>", result.valid[0].body)

    def test_format_inline_body(self):
        finding = Finding("a", 1, "RIGHT", "medium", "Fix it.")
        self.assertEqual(format_inline_body(finding), "**Medium** · Fix it.")


class LimitDiffTests(unittest.TestCase):
    def test_empty_diff(self):
        limited = limit_diff("")
        self.assertEqual(limited.text, "")
        self.assertEqual(limited.files_total, 0)
        self.assertEqual(limited.files_kept, 0)
        self.assertFalse(limited.truncated)

    def test_file_cap_keeps_the_first_files(self):
        limited = limit_diff(DIFF, max_files=2)
        self.assertTrue(limited.truncated)
        self.assertEqual(limited.files_total, 3)
        self.assertEqual(limited.files_kept, 2)
        self.assertIn("lib/foo.dart", limited.text)
        self.assertIn("test/foo_test.dart", limited.text)
        self.assertNotIn("new/name.dart", limited.text)

    def test_byte_cap_cuts_at_a_line_boundary(self):
        limited = limit_diff(DIFF, max_bytes=200)
        self.assertTrue(limited.truncated)
        self.assertLessEqual(len(limited.text.encode("utf-8")), 200)
        self.assertTrue(limited.text.endswith("\n"))
        # Whatever remains is still parseable, and the parser never invents a
        # line from a half-written hunk line.
        index = parse_diff(limited.text)
        self.assertIn("lib/foo.dart", index)

    def test_no_truncation_when_it_fits(self):
        limited = limit_diff(DIFF, max_bytes=10_000, max_files=10)
        self.assertFalse(limited.truncated)
        self.assertEqual(limited.files_total, 3)
        self.assertEqual(limited.files_kept, 3)
        self.assertEqual(limited.text, DIFF)


class BuildReviewContextTests(unittest.TestCase):
    def test_includes_metadata_files_diff_and_untrusted_warning(self):
        context = build_review_context(
            repo="owner/repo",
            base_sha="a" * 40,
            head_sha="b" * 40,
            changed_files=["lib/foo.dart", "test/foo_test.dart"],
            diff_text=DIFF,
            truncated=False,
            files_total=2,
        )
        self.assertIn("Repository: `owner/repo`", context)
        self.assertIn(f"Base: `{'a' * 40}`", context)
        self.assertIn(f"Head: `{'b' * 40}`", context)
        self.assertIn("Untrusted data", context)
        self.assertIn("- `lib/foo.dart`", context)
        self.assertIn("````diff", context)
        self.assertNotIn("capped", context)

    def test_truncation_is_called_out(self):
        context = build_review_context(
            repo="owner/repo",
            base_sha="a" * 40,
            head_sha="b" * 40,
            changed_files=["lib/foo.dart"],
            diff_text=DIFF,
            truncated=True,
            files_total=3,
        )
        self.assertIn("capped", context)

    def test_path_with_backtick_and_newline_is_neutralised(self):
        context = build_review_context(
            repo="owner/repo",
            base_sha="a" * 40,
            head_sha="b" * 40,
            changed_files=["evil`\n- injected"],
            diff_text="",
            truncated=False,
            files_total=1,
        )
        self.assertNotIn("evil`", context)
        self.assertNotIn("\n- injected", context)


class BuildReviewBodyTests(unittest.TestCase):
    def test_body_contains_summary_marker_and_counts(self):
        body = build_review_body(
            summary="Looks fine.",
            model="opencode/model",
            head_sha="a" * 40,
            valid=[
                Finding("a.dart", 1, "RIGHT", "high", "bug"),
            ],
            folded=[],
            discarded=0,
            omitted=0,
        )
        self.assertIn("## 🤖 OpenCode review", body)
        self.assertIn("Looks fine.", body)
        self.assertIn("<!-- opencode-review -->", body)
        self.assertIn("Findings:** 1", body)

    def test_folded_findings_go_into_details(self):
        body = build_review_body(
            summary="s",
            model="m",
            head_sha="a" * 40,
            valid=[],
            folded=[Finding("a.dart", 99, "RIGHT", "low", "folded body")],
            discarded=0,
            omitted=0,
        )
        self.assertIn("<details>", body)
        self.assertIn("a.dart:99", body)
        self.assertIn("folded body", body)

    def test_notes_are_added_for_discards_and_truncation(self):
        body = build_review_body(
            summary="s",
            model="m",
            head_sha="a" * 40,
            valid=[],
            folded=[],
            discarded=3,
            omitted=2,
            diff_truncated=True,
        )
        self.assertIn("3 malformed finding(s) were discarded", body)
        self.assertIn("2 finding(s) were omitted", body)
        self.assertIn("diff was truncated", body)

    def test_empty_summary_gets_a_placeholder(self):
        body = build_review_body(
            summary="   ",
            model="m",
            head_sha="a" * 40,
            valid=[],
            folded=[],
            discarded=0,
            omitted=0,
        )
        self.assertIn("_No summary was returned._", body)


class BuildErrorBodyTests(unittest.TestCase):
    def test_error_body_marks_the_error_and_omits_raw_output(self):
        body = build_error_body(
            model="m",
            head_sha="a" * 40,
            run_url="https://example.test/run",
            reason="missing envelope markers",
        )
        self.assertIn("<!-- opencode-review:error -->", body)
        self.assertIn("missing envelope markers", body)
        self.assertIn("https://example.test/run", body)
        self.assertNotIn("secret output", body)


class PublishDryRunTests(unittest.TestCase):
    def write_artifact(self, directory: Path, output: str, diff: str = DIFF):
        directory.mkdir(parents=True, exist_ok=True)
        (directory / "review-output.txt").write_text(output, encoding="utf-8")
        (directory / "pr.diff").write_text(diff, encoding="utf-8")
        (directory / "diff-truncated.txt").write_text("0\n", encoding="utf-8")

    def run_dry(self, directory: Path) -> tuple[int, str]:
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            code = publish_review.main(
                [
                    "--artifact-dir",
                    str(directory),
                    "--pr",
                    "7",
                    "--head-sha",
                    "a" * 40,
                    "--model",
                    "opencode/model",
                    "--dry-run",
                ]
            )
        return code, stdout.getvalue()

    def test_valid_output_builds_a_comment_only_review(self):
        with tempfile.TemporaryDirectory() as tmp:
            artifact = Path(tmp)
            self.write_artifact(
                artifact,
                '<opencode_review>{"summary":"s","comments":['
                '{"path":"lib/foo.dart","line":3,"side":"RIGHT",'
                '"severity":"high","body":"Fix this."}]}</opencode_review>',
            )
            code, output = self.run_dry(artifact)
        self.assertEqual(code, 0)
        payload = json.loads(output[output.index("{"):])
        self.assertEqual(payload["event"], "COMMENT")
        self.assertEqual(payload["commit_id"], "a" * 40)
        self.assertEqual(len(payload["comments"]), 1)
        self.assertEqual(payload["comments"][0]["path"], "lib/foo.dart")
        self.assertEqual(payload["comments"][0]["line"], 3)
        self.assertIn("Fix this.", payload["comments"][0]["body"])
        self.assertIn("<!-- opencode-review -->", payload["body"])

    def test_invalid_line_is_folded_out_of_the_inline_comments(self):
        with tempfile.TemporaryDirectory() as tmp:
            artifact = Path(tmp)
            self.write_artifact(
                artifact,
                '<opencode_review>{"summary":"s","comments":['
                '{"path":"lib/foo.dart","line":999,"side":"RIGHT",'
                '"severity":"high","body":"Fold me."}]}</opencode_review>',
            )
            code, output = self.run_dry(artifact)
        payload = json.loads(output[output.index("{"):])
        self.assertEqual(code, 0)
        self.assertEqual(payload["comments"], [])
        self.assertIn("could not be attached", payload["body"])
        self.assertIn("Fold me.", payload["body"])

    def test_unparseable_output_prints_the_error_notice(self):
        with tempfile.TemporaryDirectory() as tmp:
            artifact = Path(tmp)
            self.write_artifact(artifact, "raw model output that must not leak")
            code, output = self.run_dry(artifact)
        self.assertEqual(code, 0)
        self.assertIn("could not be published", output)
        self.assertIn("<!-- opencode-review:error -->", output)
        self.assertNotIn("raw model output that must not leak", output)


if __name__ == "__main__":
    unittest.main()
