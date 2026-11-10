"""Guard cases for the required GUI suite runner.

These use synthetic test modules in a temporary directory, so they never start
the application or need a display.
"""
import io
import tempfile
import textwrap
import unittest
from pathlib import Path

import run_required_gui

PASSING = """
import unittest


class Passing(unittest.TestCase):
    def test_runs(self):
        self.assertTrue(True)
"""

SKIPPING = """
import unittest


class Skipping(unittest.TestCase):
    @unittest.skip("opt-in only")
    def test_skipped(self):
        pass
"""

ZERO_TESTS = """
import unittest
"""

FAILING = """
import unittest


class Failing(unittest.TestCase):
    def test_fails(self):
        self.fail("broken")
"""

IMPORT_ERROR = """
raise RuntimeError("import exploded")
"""


class RequiredRunnerTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.directory = Path(tmp.name)

    def module(self, name, body):
        (self.directory / f"{name}.py").write_text(textwrap.dedent(body))

    def binary(self, mode=0o755):
        path = self.directory / "seance"
        path.write_text("#!/bin/sh\nexit 0\n")
        path.chmod(mode)
        return str(path)

    def run_suite(self, name):
        return run_required_gui.run_suite(
            self.directory, name, stream=io.StringIO()
        )

    def test_passing_suite_is_clean(self):
        self.module("test_strict_pass", PASSING)
        count, problem = self.run_suite("test_strict_pass")
        self.assertEqual(count, 1)
        self.assertIsNone(problem)

    def test_skip_is_a_problem(self):
        self.module("test_strict_skip", SKIPPING)
        count, problem = self.run_suite("test_strict_skip")
        self.assertEqual(count, 1)
        self.assertIn("skipped", problem)
        self.assertIn("opt-in only", problem)

    def test_zero_tests_is_a_problem(self):
        self.module("test_strict_empty", ZERO_TESTS)
        count, problem = self.run_suite("test_strict_empty")
        self.assertEqual(count, 0)
        self.assertIn("no tests collected", problem)

    def test_missing_suite_file_is_a_problem(self):
        count, problem = self.run_suite("test_strict_missing")
        self.assertEqual(count, 0)
        self.assertIn("missing required suite file", problem)

    def test_assertion_failure_is_a_problem(self):
        self.module("test_strict_fail", FAILING)
        _, problem = self.run_suite("test_strict_fail")
        self.assertIn("failed", problem)

    def test_import_error_is_a_problem(self):
        self.module("test_strict_import", IMPORT_ERROR)
        count, problem = self.run_suite("test_strict_import")
        self.assertEqual(count, 1)
        self.assertIn("errored", problem)

    def test_missing_environment_exits_non_zero(self):
        code = run_required_gui.main(
            environ={}, suites=(), tests_dir=self.directory, stream=io.StringIO()
        )
        self.assertEqual(code, 2)

    def test_missing_display_exits_non_zero(self):
        code = run_required_gui.main(
            environ={"SEANCE_TEST_BINARY": self.binary()},
            suites=(),
            tests_dir=self.directory,
            stream=io.StringIO(),
        )
        self.assertEqual(code, 2)

    def test_non_executable_binary_exits_non_zero(self):
        code = run_required_gui.main(
            environ={
                "SEANCE_TEST_BINARY": self.binary(0o644),
                "DISPLAY": ":0",
            },
            suites=(),
            tests_dir=self.directory,
            stream=io.StringIO(),
        )
        self.assertEqual(code, 2)

    def test_clean_run_exits_zero(self):
        self.module("test_strict_pass", PASSING)
        code = run_required_gui.main(
            environ={"SEANCE_TEST_BINARY": self.binary(), "DISPLAY": ":0"},
            suites=("test_strict_pass",),
            tests_dir=self.directory,
            stream=io.StringIO(),
        )
        self.assertEqual(code, 0)

    def test_problem_run_exits_non_zero(self):
        self.module("test_strict_skip", SKIPPING)
        output = io.StringIO()
        code = run_required_gui.main(
            environ={"SEANCE_TEST_BINARY": self.binary(), "DISPLAY": ":0"},
            suites=("test_strict_skip",),
            tests_dir=self.directory,
            stream=output,
        )
        self.assertEqual(code, 1)
        self.assertIn("test_strict_skip tests=1 FAIL", output.getvalue())
        self.assertIn("1 failing suites", output.getvalue())

    def test_required_inventory_names_existing_files(self):
        tests_dir = Path(run_required_gui.__file__).resolve().parent
        missing = [
            name
            for name in run_required_gui.REQUIRED_SUITES
            if not (tests_dir / f"{name}.py").is_file()
        ]
        self.assertEqual(missing, [])


if __name__ == "__main__":
    unittest.main()
