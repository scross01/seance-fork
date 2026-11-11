"""Run the required installed-binary regression suites with no silent skips.

Every suite listed here exercises the installed binary (``SEANCE_TEST_BINARY``)
on a display, so a missing binary, a missing display, a missing suite file, an
import failure, a zero-test module, a skip or a failure all make this runner
exit non-zero. CI and local verification must not go green by skipping.

Run it from the repository root after ``make build``::

    SEANCE_TEST_BINARY="$PWD/AppDir/usr/bin/seance" \
    G_DEBUG=fatal-criticals GTK_A11Y=none \
    xvfb-run -a python3 -B tests/run_required_gui.py
"""
import glob
import io
import os
import sys
import unittest
from pathlib import Path

# Suites that must run against the installed binary. New GUI regressions are
# added here deliberately; optional live-agent and wrapper suites stay in the
# broad discovery run instead.
REQUIRED_SUITES = (
    "test_ghostty_integration",
    "test_keyboard_remaps",
    "test_pane_close",
    "test_socket_server",
    "test_fullscreen",
    "test_shell_integration",
    "test_ime",
    "test_browser_eval",
    "test_browser_tls",
    "test_panel_callbacks",
    "test_panel_identity",
    "test_session_restore",
    "test_scrollback_config",
    "test_hermes_install",
    "test_pool_install",
    "test_commandcode_install",
    "test_mixed_panel_transfer",
    "test_port_allocation",
    "test_installer_resources",
    "test_runtime_ownership",
    "test_notification_identity",
    "test_unicode_titles",
)


# Suites here compile GTK probe libraries, and some pkg-config builds (notably
# Homebrew's) report only their own prefix in ``pc_path``. Look for the system
# pkg-config directories directly so the caller never has to export a search path.
PC_SEARCH_GLOBS = (
    "/usr/lib/*/pkgconfig",
    "/usr/lib/pkgconfig",
    "/usr/lib64/pkgconfig",
    "/usr/share/pkgconfig",
    "/usr/local/lib/pkgconfig",
    "/usr/local/share/pkgconfig",
)


def system_pc_dirs(patterns=PC_SEARCH_GLOBS):
    """Return the system pkg-config directories that exist on this machine.

    A module's own ``.pc`` is not enough: ``gtk4.pc`` depends on files that live
    in a second directory, so every existing candidate is added rather than only
    the one that carries the module.
    """
    found = []
    for pattern in patterns:
        for directory in sorted(glob.glob(pattern)):
            if not Path(directory).is_dir() or not glob.glob(f"{directory}/*.pc"):
                continue
            if directory not in found:
                found.append(directory)
    return found


def ensure_pkg_config_path(environ, patterns=PC_SEARCH_GLOBS):
    """Append the system GTK pkg-config directories to ``PKG_CONFIG_PATH``.

    The suites that build probe libraries (``test_fullscreen``, ``test_ime``)
    call ``pkg-config --libs`` themselves, so a pkg-config that cannot see the
    distribution's GTK4 files fails them inside ``setUpClass``. Adding those
    directories here keeps the gate self-contained: nothing has to be exported
    by the caller. Existing entries keep their order and win.
    """
    current = [entry for entry in environ.get("PKG_CONFIG_PATH", "").split(":") if entry]
    added = [directory for directory in system_pc_dirs(patterns) if directory not in current]
    if added:
        environ["PKG_CONFIG_PATH"] = ":".join(current + added)
    return current + added


def environment_problems(binary, display):
    """Return why the runner cannot trust its results, if anything is missing."""
    problems = []
    if not binary:
        problems.append("SEANCE_TEST_BINARY is not set; point it at an installed binary")
    elif not os.path.isfile(binary):
        problems.append(f"SEANCE_TEST_BINARY is not a file: {binary}")
    elif not os.access(binary, os.X_OK):
        problems.append(f"SEANCE_TEST_BINARY is not executable: {binary}")
    if not display:
        problems.append("DISPLAY is not set; run the runner under xvfb-run")
    return problems


def run_suite(tests_dir, name, stream=None):
    """Run one required module and report its collected count and any problem."""
    stream = sys.stdout if stream is None else stream
    path = Path(tests_dir) / f"{name}.py"
    if not path.is_file():
        return 0, f"missing required suite file: {path}"

    # Drop any cached import of this module name so repeated runs against
    # different directories load the file they were asked for.
    sys.modules.pop(name, None)
    suite = unittest.TestLoader().discover(
        str(tests_dir), pattern=f"{name}.py", top_level_dir=str(tests_dir)
    )
    count = suite.countTestCases()
    if count == 0:
        return 0, f"no tests collected from {path}"

    result = unittest.TextTestRunner(stream=stream, verbosity=2).run(suite)
    problems = []
    if result.failures:
        problems.append(f"{len(result.failures)} failed")
    if result.errors:
        problems.append(f"{len(result.errors)} errored")
    if result.skipped:
        reasons = ", ".join(reason for _, reason in result.skipped)
        problems.append(f"{len(result.skipped)} skipped ({reasons})")
    return count, ("; ".join(problems) if problems else None)


def main(environ=None, suites=REQUIRED_SUITES, tests_dir=None, stream=None):
    environ = os.environ if environ is None else environ
    stream = sys.stdout if stream is None else stream
    ensure_pkg_config_path(environ)
    problems = environment_problems(
        environ.get("SEANCE_TEST_BINARY", ""), environ.get("DISPLAY", "")
    )
    if problems:
        for problem in problems:
            print(f"required runner: {problem}", file=sys.stderr)
        return 2

    directory = Path(__file__).resolve().parent if tests_dir is None else Path(tests_dir)
    collected = 0
    failed = []
    for name in suites:
        print(f"required runner: starting {name}", file=stream, flush=True)
        count, problem = run_suite(directory, name, stream=stream)
        collected += count
        status = "ok" if problem is None else f"FAIL ({problem})"
        print(f"required runner: {name} tests={count} {status}", file=stream, flush=True)
        if problem is not None:
            failed.append(f"{name}: {problem}")

    print(
        f"required runner: {len(suites)} suites, {collected} tests, "
        f"{len(failed)} failing suites",
        file=stream,
        flush=True,
    )
    for entry in failed:
        print(f"required runner failure: {entry}", file=stream)
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
