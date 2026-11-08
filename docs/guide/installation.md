# Installation

Séance is a GTK4 terminal multiplexer for Linux. It supports X11 and Wayland, with GPU-accelerated rendering via [libghostty](https://ghostty.org).

## System Requirements

- **OS:** Linux (X11 or Wayland)
- **Zig:** 0.16.0 (pinned — 0.17.x is not supported yet; for building from source)
- **GTK4** and **libadwaita**
- **OpenGL 4.3+** (Mesa or proprietary GPU drivers)

## AppImage

Download the latest `seance-*-x86_64.AppImage` from [GitHub Releases](https://github.com/scross01/seance-fork/releases), make it executable, and run it:

```bash
chmod +x seance-*-x86_64.AppImage
./seance-*-x86_64.AppImage
```

::: tip
Requires `libfuse2` on the host. On Ubuntu/Debian: `sudo apt install libfuse2`.
:::

### PATH setup

To use `seance ctl` from your shell, move the AppImage onto your `PATH`:

```bash
mv seance-*-x86_64.AppImage ~/.local/bin/seance
```

## Building from Source

### Install build dependencies

**Ubuntu/Debian:**

```bash
sudo apt install pkg-config libgtk-4-dev libadwaita-1-dev libcanberra-dev libwebkitgtk-6.0-dev inotify-tools
```

**Arch Linux:**

```bash
sudo pacman -S pkg-config gtk4 libadwaita libcanberra webkitgtk-6.0 inotify-tools
```

### Clone and build

```bash
git clone --recursive https://github.com/scross01/seance-fork.git
cd seance-fork
make build
make run
```

`make build` installs icons, shell integration, and themes into `AppDir/usr/`;
`make run` builds and launches from there. Do not use `zig-out/bin/seance`
directly — it lacks installed assets.

The Makefile requires Zig 0.16.0 exactly. `make check-zig` reports the
toolchain it would use; it prefers a matching `zig` on `PATH` and otherwise
falls back to a keg-only Homebrew `zig@0.16` install. Override explicitly with
`make ZIG=/path/to/zig-0.16.0/zig build`.

If the ghostty dependency is missing:

```bash
git submodule update --init --recursive
```

## Verify Installation

Launch Séance and check the version:

```bash
seance --version
```

Or simply launch the application and confirm the window appears:

```bash
seance
```
