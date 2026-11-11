# Contributing to Séance

Thanks for considering a contribution. A few notes to save time.

## Filing issues

- Use one of the issue templates. Bug reports without a version, distro, and repro step are hard to act on.
- For feature ideas that are bigger than a single commit, open a Discussion first so we can talk about shape before anyone writes code.
- Agent support requests (new agents to auto-track) have their own template. The hook-system question is the important one.

## Building from source

```
git clone --recursive https://github.com/scross01/seance-fork.git
cd seance-fork
make check-zig
make build
make run
```

You need Zig 0.16.x, GTK4, libadwaita, OpenGL 4.3+, and Linux. The submodule (`ghostty`) must be checked out for libghostty to build.

The fork's [patch ledger](ghostty/SEANCE_PATCHES.md) documents the embedding
changes that must survive upstream updates. Run
`G_DEBUG=fatal-criticals GTK_A11Y=none xvfb-run -a zig build test` and
`xvfb-run zig build e2e`, then exercise scrollback restore, clipboard, and pane
reparenting with:

```bash
SEANCE_TEST_BINARY="$PWD/AppDir/usr/bin/seance" xvfb-run python3 -m unittest discover -s tests -p 'test_ghostty_integration.py' -v
```

Run the Codex wrapper regression tests with `python3 -m unittest discover -s tests -v`.
Set `SEANCE_TEST_CODEX` to the real Codex binary (outside Séance's wrapper directory)
to also check hook loading and approval persistence using its local app-server.
This check uses a temporary Codex home and makes no model calls.

The same Python discovery command runs the OpenCode wrapper tests and, with Node
installed, the plugin lifecycle tests. Node is only a test dependency; OpenCode
provides the plugin runtime. To also verify plugin loading against an installed
OpenCode binary without model calls:

```bash
SEANCE_TEST_BINARY="$PWD/AppDir/usr/bin/seance" SEANCE_TEST_OPENCODE=/usr/bin/opencode \
  python3 -m unittest discover -s tests -p 'test_opencode.py' -v
```

Antigravity wrapper, configuration, and lifecycle regressions run through the same
Python discovery command after building. They use the real Séance binary with a
fake agent and socket server, without model calls. The pane test requires Xvfb:

```bash
python3 -m unittest discover -s tests -p 'test_antigravity.py' -v
SEANCE_TEST_BINARY="$PWD/AppDir/usr/bin/seance" xvfb-run -a python3 -m unittest discover -s tests -p 'test_antigravity_pane.py' -v
```

For a live Antigravity check, launch `agy` in a pane of the new build. Confirm
working/idle status, then use a command that requires approval and verify
**Needs input** and one notification while the dialog stays open. Exercise both
approval and denial, cancellation, conversation switching, and exit. Preserve
any existing status-line script and verify its output survives setup. Antigravity
1.1.22 emits `tool_confirmation_pending` only while a tool dialog is visible;
`PreToolUse` alone is not evidence of an approval request. The status callback
also reports idle after cancellation, so notifications describe readiness rather
than successful completion. Use an isolated profile for permission-setting changes.

Fullscreen tests require Openbox, Xvfb, xdotool, setxkbmap, a C compiler, and
libadwaita headers. They use a separate X server and window manager. Shell
integration tests require zsh and check user startup files and both sets of hooks:

```bash
SEANCE_TEST_BINARY="$PWD/AppDir/usr/bin/seance" python3 -m unittest discover -s tests -p 'test_fullscreen.py' -v
SEANCE_TEST_BINARY="$PWD/AppDir/usr/bin/seance" xvfb-run -a python3 -m unittest discover -s tests -p 'test_shell_integration.py' -v
```

Physical keyboard remap tests require `Xvfb`, `xdotool`, and `setxkbmap`.
They create a separate X server and never modify your desktop's keyboard layout:

```bash
SEANCE_TEST_BINARY="$PWD/AppDir/usr/bin/seance" python3 -m unittest discover -s tests -p 'test_keyboard_remaps.py' -v
```

Pane close tests use the same isolated keyboard setup. They check last-tab
teardown in stacked and tabbed columns, shell exit, keyboard focus afterward,
and closing windows or workspaces while terminal output is in flight. The
remaining window or workspace must still accept input. The fork's patch ledger
also lists the Ghostty queue cancellation and payload ownership tests:

```bash
SEANCE_TEST_BINARY="$PWD/AppDir/usr/bin/seance" python3 -m unittest discover -s tests -p 'test_pane_close.py' -v
```

Control-socket number parsing tests cover oversized request IDs and integer
parameter boundaries:

```bash
SEANCE_TEST_BINARY="$PWD/AppDir/usr/bin/seance" xvfb-run -a python3 -m unittest discover -s tests -p 'test_socket_server.py' -v
```

IME tests also use isolated X servers. They exercise GTK's compose engine and a
test input context for Korean syllable transitions, asynchronous commits, focus,
and cursor positioning. The test context requires a C compiler and GTK4 headers:

```bash
SEANCE_TEST_BINARY="$PWD/AppDir/usr/bin/seance" python3 -m unittest discover -s tests -p 'test_ime.py' -v
```

For a desktop check, build and launch with `make build` then `make run` (installed AppDir assets) at your next restart
so an older running instance does not handle the launch. Enable your Korean
input method and type `안녕` followed by a space. Also insert Korean text into the
middle of an existing shell command, and switch panes during composition. Check
that syllables appear once, the candidate popup follows the cursor, and ordinary
typing and shortcuts still work after switching back. The automated X11 tests do
not replace this check with your usual IME on Wayland. Switch back to your normal
input method when finished.

## Required GUI regression suites

GUI regressions must run against the installed binary, and a skip counts as a
failure. Build with assets, then run the strict runner:

```bash
make check-zig
make build
SEANCE_TEST_BINARY="$PWD/AppDir/usr/bin/seance" G_DEBUG=fatal-criticals GTK_A11Y=none \
  xvfb-run -a python3 -B tests/run_required_gui.py
```

It fails on a missing or non-executable binary, a missing display, a missing
suite file, an import error, a zero-test module, any skip, or any failure, and
prints per-suite `tests=` counts so an absent suite cannot pass for a green run.
Adding a GUI regression means adding its module to `REQUIRED_SUITES` in
`tests/run_required_gui.py`.

The runner resolves the GTK pkg-config directories itself, so nothing beyond
`SEANCE_TEST_BINARY` has to be exported to build and run the gate.

The runner needs `Xvfb`, `xvfb-run`, `xdotool`, `setxkbmap` (`x11-xkb-utils`),
`openbox`, `zsh`, `openssl` and `inotify-tools`. Fullscreen and IME tests also
need a C compiler and GTK4 headers. The broad
`python3 -m unittest discover -s tests -v` run still covers the wrapper and
plugin suites; GUI modules skip there without a binary, so it is not a substitute
for the runner. Live-agent checks (`SEANCE_TEST_CODEX`, `SEANCE_TEST_OPENCODE`)
remain opt-in outside the runner.

## Code style

- Match existing style. Zig source uses the standard formatter (`zig fmt`).
- Keep functions small. If a function is growing past ~80 lines, look for a natural split.
- Comments should explain *why*, not *what*. Identifiers are for the what.
- Don't introduce dependencies without opening a Discussion first. The binary's "one file" feel matters.

## Pull requests

- One focused change per PR. Bundled refactors make reviewing slow.
- Include a short description that says what changed and why, not only what.
- If the change is user-visible, update the README if it's covered there.
- CI must pass before merge.

## Adding support for a new agent

The hook injection layer lives in a single file and is the main integration point. To add a new agent:

1. Identify the agent's hook or notification system. If it has one, write an injection routine that sets up config/env pointing at our hook commands.
2. Map its lifecycle events onto Séance's three states: working, waiting for permission, idle.
3. Add a detection check so Séance recognises when a new pane is running this agent.
4. Update the README's "Why Séance?" section and the bundled skill file if the agent exposes meaningful scriptable surface.

PR with the integration and a short note on how you tested it. I'll merge quickly if it's self-contained.

## Licensing

By contributing you agree that your contribution is MIT-licensed under the project's LICENSE.
