#!/usr/bin/env python3
"""Unit tests for the checkout symlink refusal boundary."""

from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import sanitize_checkout


class SanitizeCheckoutTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.base = Path(self._tmp.name)
        self.workspace = self.base / "workspace"
        (self.workspace / "lib").mkdir(parents=True)
        (self.workspace / "lib" / "app.dart").write_text("void main() {}\n")

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def link(self, name: str, target: str, root: Path | None = None) -> Path:
        where = root or self.workspace
        link = where / name
        os.symlink(target, link)
        return link

    def run_main(self) -> int:
        return sanitize_checkout.main(["--workspace", str(self.workspace)])

    # ------------------------------------------------------------- refusal

    def test_identifying_link_to_the_reported_sensitive_path_is_caught(self):
        # The exploit exactly as described: a committed link into procfs.
        # realpath canonicalizes /proc/self to /proc/<pid> — of the process
        # that resolves it, here the test process itself.
        link = self.link("escape.md", "/proc/self/environ")
        escaped = sanitize_checkout.find_escaped_links(self.workspace)
        self.assertEqual(
            [(link, Path(f"/proc/{os.getpid()}/environ"))], escaped
        )
        self.assertEqual(self.run_main(), 0)
        self.assertFalse(link.exists())

    def test_file_link_to_a_local_privileged_file_is_refused_and_target_kept(
        self,
    ):
        outside = self.base / "outside" / "secret.txt"
        outside.parent.mkdir()
        outside.write_text("provider key\n")
        link = self.link("secret.txt", str(outside))
        self.assertEqual(self.run_main(), 0)
        self.assertFalse(link.exists(), "the link must not survive checkout")
        self.assertTrue(outside.exists(), "the destination is never touched")
        self.assertEqual(outside.read_text(), "provider key\n")

    def test_escape_through_a_lexical_climb_is_caught(self):
        # link -> lib/../../outside/secret.txt : relative target that
        # climbs out of the workspace. The lexical path starts inside.
        outside = self.base / "outside" / "secret.txt"
        outside.parent.mkdir()
        outside.write_text("x\n")
        link = self.link("climb.md", "../outside/secret.txt")
        self.assertEqual(self.run_main(), 0)
        self.assertFalse(link.exists())

    def test_chain_through_an_internal_link_is_caught(self):
        outside = self.base / "outside" / "secret.txt"
        outside.parent.mkdir()
        outside.write_text("x\n")
        self.link("hopper", str(outside))
        link = self.link("chain.md", "hopper")
        self.assertEqual(self.run_main(), 0)
        self.assertFalse(link.exists(), "the chain's final target decides")
        self.assertTrue(outside.exists())

    def test_dangling_link_outside_the_workspace_is_refused_anyway(self):
        # Refusal is decided by where the path points, not by whether the
        # target happens to exist when the review starts.
        link = self.link("dangling.md", "/nonexistent/beyond/the/boundary")
        self.assertEqual(self.run_main(), 0)
        self.assertFalse(link.exists())

    def test_symlinked_directory_outside_the_workspace_is_refused(self):
        outside = self.base / "outside" / "etc"
        outside.mkdir(parents=True)
        link = self.link("host-etc", str(outside))
        self.assertEqual(self.run_main(), 0)
        self.assertFalse(link.exists())
        self.assertTrue(outside.exists(), "the directory itself is kept")

    def test_nested_links_are_found(self):
        (self.workspace / "docs").mkdir()
        link = self.link("escape.md", "/proc/self/environ", self.workspace / "docs")
        self.assertEqual(self.run_main(), 0)
        self.assertFalse(link.exists())

    # ------------------------------------------------------------ retention

    def test_internal_file_link_is_kept(self):
        link = self.link("app.md", "lib/app.dart")
        self.assertEqual(self.run_main(), 0)
        self.assertTrue(link.exists())
        self.assertTrue(link.is_symlink())

    def test_internal_directory_link_is_kept(self):
        link = self.link("same-dir", ".")
        self.assertEqual(self.run_main(), 0)
        self.assertTrue(link.exists(), "a link that stays inside is not an escape")

    def test_dangling_link_inside_the_workspace_is_kept(self):
        link = self.link("someday.md", "lib/missing.md")
        self.assertEqual(self.run_main(), 0)
        # exists() follows the link, so for a dangling target that is
        # False by definition — the assertion is about the retained entry.
        self.assertTrue(link.is_symlink())

    def test_workspace_without_any_link_reports_nothing(self):
        self.assertEqual(self.run_main(), 0)

    def test_escaping_link_does_not_stop_review_code_from_walking(self):
        # The boundary removes, it does not quarantine or restructure: the
        # surviving checkout still holds its ordinary files.
        self.assertEqual(self.run_main(), 0)
        self.assertTrue((self.workspace / "lib" / "app.dart").exists())

    # ------------------------------------------------------- fail closed

    def _cooperative_unlink(self):
        """Patched Path.unlink: real behavior, OSError for stubborn links.

        With `autospec=True` the stand-in receives the path instance as
        its first argument, so one patch serves both the successful and
        the failing link of a workspace in the same run.
        """
        real = Path.unlink

        def fake(path):
            if "stubborn" in path.name:
                raise OSError(1, "operation not permitted", str(path))
            real(path)

        return fake

    def test_a_failing_removal_fails_the_run_and_removes_nothing(self):
        from unittest import mock

        escape = self.link("escape.md", "/proc/self/environ")
        stubborn = self.link("stubborn.md", "../outside/key")
        with mock.patch.object(
            Path, "unlink", autospec=True, side_effect=OSError(1, "operation not permitted")
        ):
            code = self.run_main()
        self.assertEqual(code, 1)
        self.assertTrue(escape.is_symlink())
        self.assertTrue(stubborn.is_symlink())

    def test_a_partial_removal_fails_the_run_and_counts_only_what_left(self):
        from io import StringIO
        from unittest import mock

        escape = self.link("escape.md", "/proc/self/environ")
        stubborn = self.link("stubborn.md", "../outside/key")
        out, err = StringIO(), StringIO()
        with mock.patch.object(
            Path, "unlink", autospec=True, side_effect=self._cooperative_unlink()
        ), mock.patch.object(sys, "stdout", new=out), mock.patch.object(sys, "stderr", new=err):
            code = self.run_main()
        self.assertEqual(code, 1, "a removal that failed stops the run")
        self.assertFalse(escape.exists(), "the cooperative link is still gone")
        self.assertTrue(stubborn.is_symlink())
        # The summary narrates what WAS removed — one link, not two.
        self.assertIn("Removed 1", out.getvalue())
        self.assertIn("refused:", out.getvalue())
        self.assertEqual(out.getvalue().count("refused:"), 1)
        self.assertNotIn("stubborn", out.getvalue())
        # The failure surfaces on the stderr channel as an error annotation.
        self.assertIn("::error::", err.getvalue())
        self.assertIn("stubborn", err.getvalue())


if __name__ == "__main__":
    unittest.main()
