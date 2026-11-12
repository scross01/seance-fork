# Shipped build entry point for a source checkout/export. `build` installs the
# binary and its assets under PREFIX (AppDir/usr by default); `run` launches
# from there. Never launch zig-out/bin/seance directly: it lacks installed
# assets (icons, shell integration, themes).
BRANCH := $(shell git rev-parse --abbrev-ref HEAD 2>/dev/null)
# A detached HEAD reports the literal "HEAD", which is not a branch: treat it
# like a source export so a tagged build keeps the bare release version instead
# of producing `0.7.0-HEAD-<sha>`.
ifeq ($(BRANCH),HEAD)
BRANCH :=
endif
# Branch names may contain '/' (e.g. feature/foo). Left as-is, that lands in the
# AppImage output path and appimagetool fails with "Could not create destination
# file: No such file or directory" because the parent dir does not exist.
# Sanitize to a filename-safe form. Done via a second git call rather than by
# interpolating $(BRANCH) so a quote in the branch name cannot break the shell.
BRANCH_SAFE := $(shell git rev-parse --abbrev-ref HEAD 2>/dev/null | LC_ALL=C sed -e 's|^heads/||' -e 's|[^A-Za-z0-9._-]|-|g' -e 's|-\{2,\}|-|g' -e 's|-\+$$||')
VERSION := $(shell grep -oP '(?<=\.version = ")[^"]+' build.zig.zon)
COMMIT := $(shell git rev-parse --short HEAD 2>/dev/null)
# A source export has no Git metadata; keep the bare release version there.
ifneq ($(BRANCH),main)
ifneq ($(BRANCH),)
VERSION := $(VERSION)-$(BRANCH_SAFE)-$(COMMIT)
endif
endif
PREFIX ?= AppDir/usr

LINUXDEPLOY_URL := https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage
GTK_PLUGIN_URL := https://raw.githubusercontent.com/niclas3640/linuxdeploy-plugin-gtk/master/linuxdeploy-plugin-gtk.sh
LOCALBIN := $(HOME)/.local/bin

# Some pkg-config builds (notably Homebrew's) report only their own prefix, so a
# plain `pkg-config --libs gtk4` fails even when GTK4 is installed by the
# distribution. Append the system pkg-config directories that exist here, so the
# build works without an exported PKG_CONFIG_PATH; caller entries keep their
# order and win.
PKG_CONFIG_SYSTEM_DIRS := $(shell for d in /usr/lib/*/pkgconfig /usr/lib/pkgconfig /usr/lib64/pkgconfig /usr/share/pkgconfig /usr/local/lib/pkgconfig /usr/local/share/pkgconfig; do [ -d "$$d" ] && ls "$$d"/*.pc >/dev/null 2>&1 && printf '%s ' "$$d"; done)
space := $(subst ,, )
export PKG_CONFIG_PATH := $(subst $(space),:,$(strip $(PKG_CONFIG_PATH) $(PKG_CONFIG_SYSTEM_DIRS)))

# Zig toolchain pin: this project builds ONLY with Zig 0.16.0. Zig 0.17.0 may
# be what plain `zig` resolves to on PATH, but it is not supported yet and must
# not be used. Resolution order:
#   1. `make ZIG=/path/to/zig build` — explicit override always wins
#   2. a `zig` on PATH that reports exactly 0.16.0
#   3. the keg-only Homebrew zig@0.16 install, located through `brew --prefix`
#      so this works on any Homebrew prefix instead of a hardcoded path
# `check-zig` enforces the pin for every zig-invoking target.
ZIG_VERSION_PIN := 0.16.0
ZIG_BREW_PREFIX := $(shell brew --prefix zig@0.16 2>/dev/null)
ZIG_BREW_016 ?= $(if $(ZIG_BREW_PREFIX),$(ZIG_BREW_PREFIX)/bin/zig)
PATH_ZIG_VERSION := $(shell zig version 2>/dev/null)
ifeq ($(PATH_ZIG_VERSION),$(ZIG_VERSION_PIN))
ZIG ?= zig
else
ZIG ?= $(if $(ZIG_BREW_016),$(ZIG_BREW_016),zig)
endif

.PHONY: build run appimage clean check-zig images

check-zig:
	@found=$$($(ZIG) version 2>/dev/null); \
	if [ "$$found" != "$(ZIG_VERSION_PIN)" ]; then \
		echo "error: seance-fork requires Zig $(ZIG_VERSION_PIN); '$(ZIG)' reports '$${found:-not found}'." >&2; \
		echo "       Install it (e.g. 'brew install zig@0.16') or run: make ZIG=/path/to/zig-$(ZIG_VERSION_PIN)/zig <target>" >&2; \
		exit 1; \
	fi
	@echo "zig $(ZIG_VERSION_PIN) OK: $(ZIG)"

build: check-zig
	$(ZIG) build -p $(PREFIX) -Doptimize=ReleaseSafe -Dstrip=true

$(LOCALBIN)/linuxdeploy-x86_64.AppImage:
	mkdir -p $(LOCALBIN)
	curl -L -o $@ $(LINUXDEPLOY_URL)
	chmod +x $@

$(LOCALBIN)/linuxdeploy-plugin-gtk.sh:
	mkdir -p $(LOCALBIN)
	curl -L -o $@ $(GTK_PLUGIN_URL)
	chmod +x $@

appimage: build $(LOCALBIN)/linuxdeploy-x86_64.AppImage $(LOCALBIN)/linuxdeploy-plugin-gtk.sh
	# Stage top-level files
	cp resources/com.seance-fork.app.desktop AppDir/com.seance-fork.app.desktop
	# Stage icon: install transparent PNG into hicolor and create symlinks
	./scripts/appimage-icon.sh stage AppDir
	# Bundle dependencies
	ARCH=x86_64 DEPLOY_GTK_VERSION=4 $(LOCALBIN)/linuxdeploy-x86_64.AppImage \
		--appdir AppDir \
		--plugin gtk \
		--desktop-file AppDir/com.seance-fork.app.desktop \
		--icon-file AppDir/com.seance-fork.app.png
	# Finalize icon: ensure root links are correct and remove any stale SVG
	./scripts/appimage-icon.sh finalize AppDir
	# Remove GStreamer media module (not used, causes GLib version mismatches)
	rm -vf AppDir/usr/lib/gtk-4.0/*/media/libmedia-gstreamer.so
	# Remove GTK_THEME override (interferes with libadwaita's stylesheet)
	sed -i '/^export GTK_THEME/d' AppDir/apprun-hooks/linuxdeploy-plugin-gtk.sh
	# Remove old AppImage if present (prevents "Text file busy" error)
	rm -f seance-fork-$(VERSION)-x86_64.AppImage
	# Verify icon packaging (requires Pillow for full PNG transparency check)
	@if python3 -c "import PIL" 2>/dev/null; then \
		python3 scripts/verify-appimage-icon.py AppDir resources/icons/hicolor/256x256/apps/com.seance-fork.app.png; \
	else \
		python3 scripts/verify-appimage-icon.py AppDir resources/icons/hicolor/256x256/apps/com.seance-fork.app.png --no-transparency; \
	fi
	# Build AppImage
	ARCH=x86_64 OUTPUT="seance-fork-$(VERSION)-x86_64.AppImage" $(LOCALBIN)/linuxdeploy-x86_64.AppImage \
		--appdir AppDir \
		--output appimage

run: build
	$(PREFIX)/bin/seance

images:
	rsvg-convert -w 16  ./resources/icons/hicolor/scalable/apps/com.seance-fork.app.svg -o ./resources/icons/hicolor/16x16/apps/com.seance-fork.app.png
	rsvg-convert -w 22  ./resources/icons/hicolor/scalable/apps/com.seance-fork.app.svg -o ./resources/icons/hicolor/22x22/apps/com.seance-fork.app.png
	rsvg-convert -w 24  ./resources/icons/hicolor/scalable/apps/com.seance-fork.app.svg -o ./resources/icons/hicolor/24x24/apps/com.seance-fork.app.png
	rsvg-convert -w 32  ./resources/icons/hicolor/scalable/apps/com.seance-fork.app.svg -o ./resources/icons/hicolor/32x32/apps/com.seance-fork.app.png
	rsvg-convert -w 36  ./resources/icons/hicolor/scalable/apps/com.seance-fork.app.svg -o ./resources/icons/hicolor/36x36/apps/com.seance-fork.app.png
	rsvg-convert -w 48  ./resources/icons/hicolor/scalable/apps/com.seance-fork.app.svg -o ./resources/icons/hicolor/48x48/apps/com.seance-fork.app.png
	rsvg-convert -w 64  ./resources/icons/hicolor/scalable/apps/com.seance-fork.app.svg -o ./resources/icons/hicolor/64x64/apps/com.seance-fork.app.png
	rsvg-convert -w 72  ./resources/icons/hicolor/scalable/apps/com.seance-fork.app.svg -o ./resources/icons/hicolor/72x72/apps/com.seance-fork.app.png
	rsvg-convert -w 96  ./resources/icons/hicolor/scalable/apps/com.seance-fork.app.svg -o ./resources/icons/hicolor/96x96/apps/com.seance-fork.app.png
	rsvg-convert -w 128 ./resources/icons/hicolor/scalable/apps/com.seance-fork.app.svg -o ./resources/icons/hicolor/128x128/apps/com.seance-fork.app.png
	rsvg-convert -w 192 ./resources/icons/hicolor/scalable/apps/com.seance-fork.app.svg -o ./resources/icons/hicolor/192x192/apps/com.seance-fork.app.png
	rsvg-convert -w 256 ./resources/icons/hicolor/scalable/apps/com.seance-fork.app.svg -o ./resources/icons/hicolor/256x256/apps/com.seance-fork.app.png
	rsvg-convert -w 512 ./resources/icons/hicolor/scalable/apps/com.seance-fork.app.svg -o ./resources/icons/hicolor/512x512/apps/com.seance-fork.app.png
clean:
	rm -rf AppDir squashfs-root *.AppImage zig-out .zig-cache
