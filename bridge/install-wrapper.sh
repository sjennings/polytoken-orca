#!/bin/sh
# install-wrapper.sh — install the pi-polytoken wrapper (v0, standalone).
#
# Installs bin/pi-polytoken to the stable path:
#     $HOME/.config/polytoken/orca-bridge/pi-polytoken   (mode 0755)
#
# Optional: --path-shim also creates $HOME/.local/bin/pi as a symlink to
# the installed wrapper (this is how Orca's fixed `pi` launch command finds
# it). The shim is refused loudly if any other `pi` exists.
#
# Discipline: validate everything, stage on the destination filesystem,
# commit last, roll back on any failure. Re-runs are idempotent.

set -eu

usage() {
    echo "usage: install-wrapper.sh [--path-shim] [--path-shim-force]" >&2
    exit 2
}

PATH_SHIM=0
SHIM_FORCE=0
for arg in "$@"; do
    case "$arg" in
        --path-shim) PATH_SHIM=1 ;;
        --path-shim-force) PATH_SHIM=1; SHIM_FORCE=1 ;;
        *) usage ;;
    esac
done

SRC_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC="$SRC_DIR/../bin/pi-polytoken"

CONF_DIR="$HOME/.config/polytoken"
BRIDGE_DIR="$CONF_DIR/orca-bridge"
DEST="$BRIDGE_DIR/pi-polytoken"
SHIM_DIR="$HOME/.local/bin"
SHIM="$SHIM_DIR/pi"

die() { echo "install-wrapper: $*" >&2; exit 1; }

# state used by the rollback trap; safe defaults before anything can fail
STAGE=""
HAVEDest=0
CREATED_BRIDGE_DIR=0

rollback() {
    status=$?
    if [ -n "$STAGE" ] && [ -d "$STAGE" ]; then
        if [ "$HAVEDest" = 1 ] && [ -f "$STAGE/backup" ] && [ ! -e "$DEST" ]; then
            cp -p "$STAGE/backup" "$DEST" 2>/dev/null || true
        fi
        rm -rf "$STAGE" 2>/dev/null || true
    fi
    if [ "$CREATED_BRIDGE_DIR" = 1 ]; then
        if [ -d "$BRIDGE_DIR" ] && [ -z "$(ls -A "$BRIDGE_DIR" 2>/dev/null)" ]; then
            rmdir "$BRIDGE_DIR" 2>/dev/null || true
        fi
    fi
    exit "$status"
}
trap rollback EXIT HUP INT TERM

# --- validation (no mutation past this point until staging) ---------------
if [ -z "$HOME" ] || [ ! -d "$HOME" ]; then die "HOME is not set or missing"; fi
if [ ! -r "$SRC" ]; then die "wrapper source not readable: $SRC"; fi
if ! head -n 1 "$SRC" | grep -q '^#!.*sh'; then die "wrapper source has no sh shebang: $SRC"; fi

if [ "$PATH_SHIM" = 1 ]; then
    # A pre-existing shim that already points at DEST is fine (idempotent);
    # anything else named `pi` at the shim path is a loud collision.
    # --path-shim-force deliberately shadows a `pi` found elsewhere on PATH
    # (the real binary is untouched and still invocable by absolute path).
    if [ -e "$SHIM" ] || [ -L "$SHIM" ]; then
        if [ "$(readlink "$SHIM" 2>/dev/null || true)" != "$DEST" ]; then
            die "refusing to touch existing pi at $SHIM (not ours); resolve manually"
        fi
    else
        if [ "$SHIM_FORCE" = 0 ] && command -v pi >/dev/null 2>&1; then
            die "another pi exists on PATH: $(command -v pi); refusing to shim (use --path-shim-force to shadow it)"
        fi
    fi
fi

# --- staging (on the destination filesystem) -------------------------------
mkdir -p "$BRIDGE_DIR" || die "cannot create $BRIDGE_DIR"
if [ -z "$(ls -A "$BRIDGE_DIR" 2>/dev/null)" ]; then
    CREATED_BRIDGE_DIR=1
fi

STAGE=$(mktemp -d "$BRIDGE_DIR/.install-wrapper.XXXXXX") || die "mktemp failed in $BRIDGE_DIR"

if [ -e "$DEST" ]; then HAVEDest=1; fi
if [ "$HAVEDest" = 1 ]; then
    cp -p "$DEST" "$STAGE/backup" || die "failed to back up existing wrapper"
fi
cp "$SRC" "$STAGE/pi-polytoken" || die "failed to stage wrapper"
chmod 0755 "$STAGE/pi-polytoken" || die "failed to chmod staged wrapper"

# --- commit -----------------------------------------------------------------
if ! mv "$STAGE/pi-polytoken" "$DEST"; then
    echo "install-wrapper: commit of wrapper failed; rolling back" >&2
    exit 1
fi

if [ "$PATH_SHIM" = 1 ]; then
    mkdir -p "$SHIM_DIR"
    if ! ln -sfn "$DEST" "$SHIM"; then
        echo "install-wrapper: wrapper installed but PATH shim creation failed at $SHIM" >&2
        exit 1
    fi
fi

trap - EXIT HUP INT TERM
rm -rf "$STAGE"
echo "installed $DEST"
if [ "$PATH_SHIM" = 1 ]; then echo "shim $SHIM -> $DEST"; fi
