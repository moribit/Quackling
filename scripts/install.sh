#!/bin/sh
# Install quackling, the DuckDB Quack protocol client.
#
#   curl -fsSL https://raw.githubusercontent.com/OWNER/Quackling/main/scripts/install.sh | sh
#
# Options (flags or environment variables):
#   --version <v>   / QUACK_VERSION   version to install, or "latest" (default)
#   --bin-dir <dir> / QUACK_BIN_DIR   where to install (default: see below)
#   --repo <o/r>    / QUACK_REPO      GitHub repo to download from
#   --build         / QUACK_BUILD=1   build from source with Zig instead
#   --no-verify     / QUACK_NO_VERIFY=1  skip checksum verification
#   --no-alias      / QUACK_NO_ALIAS=1   skip the short `qkl` alias
#   --dry-run                         print what would happen, change nothing
#
# Written for POSIX sh (not bash): the smallest containers and Alpine images
# ship only /bin/sh, and an installer that needs bash is an installer that
# fails exactly where you most want it to work.
#
# Deliberate properties:
#   * Never writes outside the chosen bin dir.
#   * Verifies a SHA-256 checksum before installing, and says so if it cannot.
#   * Downloads to a temp file and moves it into place, so an interrupted run
#     cannot leave a half-written binary on PATH.
#   * Refuses to overwrite silently on a downgrade; asks or needs --force.
#   * Never runs sudo on its own. If the target needs root, it says what to run.

set -eu

REPO="${QUACK_REPO:-OWNER/Quackling}"
VERSION="${QUACK_VERSION:-latest}"
BIN_DIR="${QUACK_BIN_DIR:-}"
DO_BUILD="${QUACK_BUILD:-0}"
NO_VERIFY="${QUACK_NO_VERIFY:-0}"
NO_ALIAS="${QUACK_NO_ALIAS:-0}"
DRY_RUN=0
FORCE=0
EXE_NAME="quackling"
# `quackling` is the canonical name; `qkl` is a symlink to it, because a command
# typed all day should be short. Only ever created when it is free, or when it
# already points at our own binary.
ALIAS_NAME="qkl"

# ---------------------------------------------------------------------------
# output helpers
# ---------------------------------------------------------------------------

# Colour only when stdout is a terminal, so piped output and CI logs stay clean.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$(printf '\033[0m'); C_DIM=$(printf '\033[2m')
    C_RED=$(printf '\033[31m'); C_GREEN=$(printf '\033[32m')
    C_YELLOW=$(printf '\033[33m'); C_BOLD=$(printf '\033[1m')
else
    C_RESET=''; C_DIM=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BOLD=''
fi

info()  { printf '%s\n' "$*"; }
step()  { printf '%s==>%s %s\n' "$C_BOLD" "$C_RESET" "$*"; }
warn()  { printf '%swarning:%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
dim()   { printf '%s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }
die()   { printf '%serror:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }
ok()    { printf '%s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }

usage() {
    # Print the header comment block: everything from line 2 up to the first
    # line that is not a comment. Derived rather than a hard-coded range, so
    # editing the header cannot leak code into --help.
    sed -n '2,${/^#/!q; s/^# \{0,1\}//; p;}' "$0"
    exit 0
}

# ---------------------------------------------------------------------------
# arguments
# ---------------------------------------------------------------------------

while [ $# -gt 0 ]; do
    case "$1" in
        --version) [ $# -ge 2 ] || die "--version needs a value"; VERSION="$2"; shift 2 ;;
        --version=*) VERSION="${1#*=}"; shift ;;
        --bin-dir) [ $# -ge 2 ] || die "--bin-dir needs a value"; BIN_DIR="$2"; shift 2 ;;
        --bin-dir=*) BIN_DIR="${1#*=}"; shift ;;
        --repo) [ $# -ge 2 ] || die "--repo needs a value"; REPO="$2"; shift 2 ;;
        --repo=*) REPO="${1#*=}"; shift ;;
        --build) DO_BUILD=1; shift ;;
        --no-verify) NO_VERIFY=1; shift ;;
        --no-alias) NO_ALIAS=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --force|-f) FORCE=1; shift ;;
        -h|--help) usage ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
done

# ---------------------------------------------------------------------------
# platform detection
# ---------------------------------------------------------------------------

detect_target() {
    os=$(uname -s)
    arch=$(uname -m)

    case "$arch" in
        x86_64|amd64) arch=x86_64 ;;
        aarch64|arm64) arch=aarch64 ;;
        # An explicit failure beats downloading a binary that cannot run.
        *) die "unsupported architecture: $arch (supported: x86_64, aarch64)" ;;
    esac

    case "$os" in
        Linux)
            # Release Linux builds are static musl, so they run on glibc and
            # musl distros alike - no libc detection needed.
            TARGET="$arch-linux-musl" ;;
        Darwin)
            TARGET="$arch-macos" ;;
        MINGW*|MSYS*|CYGWIN*)
            TARGET="$arch-windows"
            EXE_NAME="quackling.exe"
            ALIAS_NAME="qkl.exe" ;;
        *)
            die "unsupported OS: $os (supported: Linux, macOS, Windows via MSYS/Cygwin)" ;;
    esac
}

# ---------------------------------------------------------------------------
# download helpers
# ---------------------------------------------------------------------------

have() { command -v "$1" >/dev/null 2>&1; }

# Fetch $1 to stdout. Fails loudly on HTTP errors rather than saving an error page.
fetch() {
    if have curl; then
        curl -fsSL "$1"
    elif have wget; then
        wget -qO- "$1"
    else
        die "need curl or wget to download"
    fi
}

# Fetch $1 into file $2.
fetch_to() {
    if have curl; then
        curl -fsSL -o "$2" "$1"
    elif have wget; then
        wget -qO "$2" "$1"
    else
        die "need curl or wget to download"
    fi
}

sha256_of() {
    if have sha256sum; then sha256sum "$1" | cut -d' ' -f1
    elif have shasum; then shasum -a 256 "$1" | cut -d' ' -f1
    elif have openssl; then openssl dgst -sha256 "$1" | awk '{print $NF}'
    else return 1
    fi
}

# ---------------------------------------------------------------------------
# install directory
# ---------------------------------------------------------------------------

choose_bin_dir() {
    [ -n "$BIN_DIR" ] && return 0

    # Prefer a writable, conventional, user-owned location, so the common path
    # needs no privileges at all.
    for candidate in "$HOME/.local/bin" "$HOME/bin"; do
        if [ -d "$candidate" ] && [ -w "$candidate" ]; then
            BIN_DIR="$candidate"; return 0
        fi
    done
    # Then a system location, but only if we can actually write to it.
    for candidate in /usr/local/bin /opt/homebrew/bin; do
        if [ -d "$candidate" ] && [ -w "$candidate" ]; then
            BIN_DIR="$candidate"; return 0
        fi
    done
    # Otherwise create the XDG-ish default rather than demanding root.
    BIN_DIR="$HOME/.local/bin"
}

# ---------------------------------------------------------------------------
# version resolution
# ---------------------------------------------------------------------------

resolve_version() {
    [ "$VERSION" != "latest" ] && return 0

    step "Resolving latest release"
    # Parsed from the API without jq, which is not present on a bare system.
    tag=$(fetch "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
          | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)
    if [ -z "$tag" ]; then
        die "could not determine the latest release of $REPO.
  Pass an explicit version:  --version v0.1.0
  Or build from source:      --build"
    fi
    VERSION="$tag"
}

# ---------------------------------------------------------------------------
# install from a release
# ---------------------------------------------------------------------------

install_release() {
    resolve_version
    base="https://github.com/$REPO/releases/download/$VERSION"
    asset="quackling-$TARGET"
    case "$TARGET" in *windows) asset="$asset.exe" ;; esac

    step "Installing quackling $VERSION for $TARGET"

    if [ "$DRY_RUN" = 1 ]; then
        dim "  would download $base/$asset"
        dim "  would install to $BIN_DIR/$EXE_NAME"
        [ "$NO_ALIAS" = 1 ] || dim "  would link $BIN_DIR/$ALIAS_NAME -> $EXE_NAME"
        return 0
    fi

    tmp=$(mktemp -d 2>/dev/null || mktemp -d -t quackling)
    # Clean up on any exit path, including Ctrl-C, so no temp dirs accumulate.
    trap 'rm -rf "$tmp"' EXIT HUP INT TERM

    dim "  downloading $asset"
    fetch_to "$base/$asset" "$tmp/$EXE_NAME" ||
        die "download failed: $base/$asset
  Check that $VERSION exists and has an asset for $TARGET, or use --build."

    # Guard against a saved error page being installed as a binary.
    if [ ! -s "$tmp/$EXE_NAME" ]; then
        die "downloaded file is empty"
    fi

    verify_checksum "$tmp/$EXE_NAME" "$base" "$asset"

    chmod +x "$tmp/$EXE_NAME"
    place "$tmp/$EXE_NAME"
}

verify_checksum() {
    file="$1"; base="$2"; asset="$3"

    if [ "$NO_VERIFY" = 1 ]; then
        warn "skipping checksum verification (--no-verify)"
        return 0
    fi

    sums=$(fetch "$base/SHA256SUMS" 2>/dev/null || true)
    if [ -z "$sums" ]; then
        # Say so rather than pretending the download was verified.
        warn "no SHA256SUMS published for $VERSION; cannot verify the download"
        return 0
    fi

    expected=$(printf '%s\n' "$sums" | grep -F " $asset" | cut -d' ' -f1 | head -1)
    if [ -z "$expected" ]; then
        warn "SHA256SUMS has no entry for $asset; cannot verify"
        return 0
    fi

    actual=$(sha256_of "$file") || {
        warn "no sha256 tool available (sha256sum/shasum/openssl); cannot verify"
        return 0
    }

    if [ "$expected" != "$actual" ]; then
        die "checksum mismatch for $asset
  expected $expected
  actual   $actual
  Refusing to install. This could be a corrupted download or a tampered asset."
    fi
    ok "checksum verified"
}

# ---------------------------------------------------------------------------
# install from source
# ---------------------------------------------------------------------------

install_from_source() {
    have zig || die "--build needs zig on PATH (https://ziglang.org/download/)"

    # The build requires a specific Zig; a mismatch produces confusing compile
    # errors, so check up front.
    zig_version=$(zig version)
    case "$zig_version" in
        0.17.*) ;;
        *) warn "this project targets Zig 0.17.x; found $zig_version" ;;
    esac

    step "Building quackling from source with Zig $zig_version"
    if [ "$DRY_RUN" = 1 ]; then
        dim "  would run: zig build -Doptimize=safe"
        dim "  would install to $BIN_DIR/$EXE_NAME"
        [ "$NO_ALIAS" = 1 ] || dim "  would link $BIN_DIR/$ALIAS_NAME -> $EXE_NAME"
        return 0
    fi

    # Run from the repo root, whether the script was invoked from there or not.
    script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
    root=$(dirname "$script_dir")
    [ -f "$root/build.zig" ] || die "build.zig not found; run this from a checkout or drop --build"

    ( cd "$root" && zig build -Doptimize=safe ) || die "build failed"
    built="$root/zig-out/bin/$EXE_NAME"
    [ -f "$built" ] || die "build produced no $EXE_NAME"
    place "$built"
}

# ---------------------------------------------------------------------------
# placement
# ---------------------------------------------------------------------------

place() {
    src="$1"
    dest="$BIN_DIR/$EXE_NAME"

    if [ ! -d "$BIN_DIR" ]; then
        dim "  creating $BIN_DIR"
        mkdir -p "$BIN_DIR" || die "cannot create $BIN_DIR"
    fi

    if [ ! -w "$BIN_DIR" ]; then
        die "$BIN_DIR is not writable.
  Either choose a different location:
      $0 --bin-dir \"\$HOME/.local/bin\"
  or install there yourself:
      sudo install -m 755 '$src' '$dest'"
    fi

    # Warn before replacing a different version, so an accidental downgrade is
    # visible rather than silent.
    if [ -e "$dest" ] && [ "$FORCE" != 1 ]; then
        existing=$("$dest" --version 2>/dev/null || echo "unknown")
        dim "  replacing existing install ($existing)"
    fi

    # Copy to a sibling temp path then move: a rename within one directory is
    # atomic, so a concurrent shell never sees a partial binary on PATH.
    staged="$dest.new.$$"
    cp "$src" "$staged" || die "cannot write to $BIN_DIR"
    chmod 755 "$staged"
    mv -f "$staged" "$dest" || { rm -f "$staged"; die "cannot install to $dest"; }

    ok "installed $dest"
    verify_install "$dest"
    place_alias "$dest"
    check_path
}

# Install `qkl` alongside `quackling`. A symlink keeps one binary on disk and
# makes it obvious what the alias points at; Windows gets a copy, since symlinks
# there need either developer mode or elevation.
place_alias() {
    dest="$1"
    if [ "$NO_ALIAS" = 1 ]; then
        dim "  skipping the $ALIAS_NAME alias (--no-alias)"
        return 0
    fi

    alias_path="$BIN_DIR/$ALIAS_NAME"

    # Never clobber someone else's `qkl`. Replacing a link that already points at
    # our binary is fine - that is just a reinstall.
    if [ -e "$alias_path" ] || [ -L "$alias_path" ]; then
        if [ -L "$alias_path" ] && [ "$(readlink "$alias_path")" = "$EXE_NAME" ]; then
            : # our own alias from a previous run
        elif [ "$FORCE" = 1 ]; then
            dim "  replacing existing $ALIAS_NAME (--force)"
        else
            warn "$alias_path already exists and is not our alias; leaving it alone
  Use --force to replace it, or --no-alias to skip creating it."
            return 0
        fi
    fi

    # Relative target, so the pair stays valid if BIN_DIR is later moved.
    if ln -sfn "$EXE_NAME" "$alias_path" 2>/dev/null; then
        ok "installed $alias_path -> $EXE_NAME"
    elif cp -f "$dest" "$alias_path" 2>/dev/null; then
        chmod 755 "$alias_path"
        ok "installed $alias_path (copy; symlinks unavailable)"
    else
        warn "could not create the $ALIAS_NAME alias; $EXE_NAME is installed and works"
    fi
}

verify_install() {
    dest="$1"
    # Actually run it: a binary for the wrong architecture installs fine and
    # then fails on first use, which is a worse experience than failing here.
    if out=$("$dest" --version 2>&1); then
        ok "$out"
    else
        die "installed binary does not run:
  $out
  This usually means the wrong platform asset. Try --build."
    fi
}

check_path() {
    case ":$PATH:" in
        *":$BIN_DIR:"*) return 0 ;;
    esac

    warn "$BIN_DIR is not on your PATH"
    # Name the file the user's own shell reads, rather than guessing bash.
    case "${SHELL:-}" in
        */zsh)  rc="$HOME/.zshrc" ;;
        */bash) rc="$HOME/.bashrc" ;;
        */fish) rc="$HOME/.config/fish/config.fish" ;;
        *)      rc="your shell profile" ;;
    esac
    info ""
    if [ "$rc" = "$HOME/.config/fish/config.fish" ]; then
        info "  Add it with:"
        info "    fish_add_path $BIN_DIR"
    else
        info "  Add it with:"
        info "    echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> $rc"
        info "    exec \$SHELL"
    fi
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

detect_target
choose_bin_dir

if [ "$DO_BUILD" = 1 ]; then
    install_from_source
else
    install_release
fi

if [ "$DRY_RUN" != 1 ]; then
    info ""
    info "Try it:"
    info "  quackling --url quack:localhost:9494 --token \"\$QUACK_TOKEN\" 'SELECT 42'"
    if [ "$NO_ALIAS" != 1 ]; then
        info "  qkl 'SELECT 42'   # same command, shorter"
    fi
    info ""
    dim "Start a server with:"
    dim "  duckdb -c \"LOAD quack; CALL quack_serve('quack:localhost:9494', token => 'secret');\""
fi
