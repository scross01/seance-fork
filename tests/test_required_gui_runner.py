"""Guard cases for the required GUI suite runner.

These use synthetic test modules in a temporary directory, so they never start
the application or need a display.
"""
import ast
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


def xdotool_bare_keysyms(source, filename="<source>"):
    """Find unmodified keysyms sent through ``xdotool key``.

    xdotool infers modifiers for a bare keysym from the server's XKB map and
    pressed Alt before F11/F12 on some servers, so GUI suites send unmodified
    keys through ``PhysicalKeyboardTestCase.press`` (XTest keycodes) instead.
    Modifier chords and option values stay on xdotool.
    """
    offenders = []
    for node in ast.walk(ast.parse(source, filename=filename)):
        if not isinstance(node, ast.Call):
            continue
        tokens = []
        for argument in node.args:
            if isinstance(argument, ast.Constant) and isinstance(argument.value, str):
                tokens.append((argument.lineno, argument.value))
            elif isinstance(argument, (ast.List, ast.Tuple)):
                tokens.extend(
                    (item.lineno, item.value) for item in argument.elts
                    if isinstance(item, ast.Constant) and isinstance(item.value, str)
                )
        words = [value for _, value in tokens]
        if "xdotool" not in words:
            continue
        start = words.index("xdotool") + 1
        if words[start:start + 1] != ["key"]:
            continue
        for position in range(start + 1, len(tokens)):
            value, previous = tokens[position][1], tokens[position - 1][1]
            if value.startswith("-") or "+" in value or previous.startswith("-"):
                continue
            offenders.append((tokens[position][0], value))
    return offenders


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

    def test_bare_keysym_guard_flags_xdotool_keys(self):
        source = textwrap.dedent("""
            self.run_x("xdotool", "key", "F11")
            subprocess.run(["xdotool", "key", "a", "b"], check=True)
            self.run_x("xdotool", "key", "--delay", "150", "Return")
        """)
        self.assertEqual(
            [keysym for _, keysym in xdotool_bare_keysyms(source)],
            ["F11", "a", "b", "Return"],
        )

    def test_bare_keysym_guard_allows_chords_and_xtest(self):
        source = textwrap.dedent("""
            self.run_x("xdotool", "key", "ctrl+shift+p")
            self.run_x("xdotool", "key", "--clearmodifiers", chord)
            self.run_x("xdotool", "key", "--delay", "150", *sequence)
            self.run_x("xdotool", "type", "Toggle Fullscreen")
            self.press("F11", "Return")
        """)
        self.assertEqual(xdotool_bare_keysyms(source), [])

    def test_gui_suites_send_unmodified_keys_through_the_xtest_helper(self):
        tests_dir = Path(__file__).resolve().parent
        offenders = [
            f"{path.name}:{line}: {keysym!r} sent through xdotool; use press(...)"
            for path in sorted(tests_dir.glob("test_*.py"))
            for line, keysym in xdotool_bare_keysyms(path.read_text(), filename=str(path))
        ]
        self.assertEqual(offenders, [])


if __name__ == "__main__":
    unittest.main()
