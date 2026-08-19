#!/bin/sh
# install-bridge.sh — install the v1 Polytoken→Orca Pi-dialect bridge.
#
# Installs (taking ownership of the complete wrapper+hook installation):
#   $HOME/.config/polytoken/orca-bridge/pi-polytoken    (0755)
#   $HOME/.config/polytoken/orca-bridge/orca-pi-hook.sh (0755)
#   $HOME/.config/polytoken/hooks.json                  (merged, atomic)
#
# Optional --path-shim: also create $HOME/.local/bin/pi -> wrapper.
#
# Discipline: validate everything (jq present, sources readable, fragment
# sane, existing config parses, merged output validates) BEFORE any
# mutation; stage on the destination filesystem; commit scripts first and
# hooks.json LAST via mv; roll back to the exact prior state on any
# failure. A timestamped backup of hooks.json is kept under
# orca-bridge/backups/. Repeat runs are idempotent: exactly one managed
# entry per managed name, all unrelated entries preserved untouched.

set -eu

usage() {
    echo "usage: install-bridge.sh [--path-shim] [--path-shim-force]" >&2
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
WRAPPER_SRC="$SRC_DIR/../bin/pi-polytoken"
HOOK_SRC="$SRC_DIR/orca-pi-hook.sh"
FRAGMENT="$SRC_DIR/hooks.fragment.json"

CONF_DIR="$HOME/.config/polytoken"
BRIDGE_DIR="$CONF_DIR/orca-bridge"
BACKUP_DIR="$BRIDGE_DIR/backups"
HOOKS="$CONF_DIR/hooks.json"
DEST_WRAPPER="$BRIDGE_DIR/pi-polytoken"
DEST_HOOK="$BRIDGE_DIR/orca-pi-hook.sh"
SHIM_DIR="$HOME/.local/bin"
SHIM="$SHIM_DIR/pi"

MANAGED='["orca-pi-bridge-session-start","orca-pi-bridge-pre-user-prompt","orca-pi-bridge-pre-tool-use","orca-pi-bridge-notification","orca-pi-bridge-post-tool-use","orca-pi-bridge-post-tool-use-failure","orca-pi-bridge-stop"]'

die() { echo "install-bridge: $*" >&2; exit 1; }

# state for the rollback trap; safe defaults before anything can fail
STAGE=""
CREATED_BRIDGE_DIR=0
CREATED_CONF_DIR=0
SHIM_CREATED=0
COMMITTED_WRAPPER=0
COMMITTED_HOOK=0
COMMITTED_HOOKS=0
HAD_WRAPPER=0
HAD_HOOK=0
HAD_HOOKS=0

rollback() {
    status=$?
    trap - EXIT HUP INT TERM   # never run twice (signal + exit)
    # restore pre-existing files from backups (byte+mode identical), remove
    # files we committed that did not exist before
    if [ -n "$STAGE" ] && [ -d "$STAGE" ]; then
        if [ "$HAD_WRAPPER" = 1 ]; then
            if [ -f "$STAGE/backup-wrapper" ]; then cp -p "$STAGE/backup-wrapper" "$DEST_WRAPPER" 2>/dev/null || true; fi
        elif [ "$COMMITTED_WRAPPER" = 1 ] && [ -e "$DEST_WRAPPER" ]; then
            rm -f "$DEST_WRAPPER" 2>/dev/null || true
        fi
        if [ "$HAD_HOOK" = 1 ]; then
            if [ -f "$STAGE/backup-hook" ]; then cp -p "$STAGE/backup-hook" "$DEST_HOOK" 2>/dev/null || true; fi
        elif [ "$COMMITTED_HOOK" = 1 ] && [ -e "$DEST_HOOK" ]; then
            rm -f "$DEST_HOOK" 2>/dev/null || true
        fi
        if [ "$HAD_HOOKS" = 1 ]; then
            if [ -f "$STAGE/backup-hooks.json" ]; then cp -p "$STAGE/backup-hooks.json" "$HOOKS" 2>/dev/null || true; fi
        elif [ "$COMMITTED_HOOKS" = 1 ] && [ -e "$HOOKS" ]; then
            rm -f "$HOOKS" 2>/dev/null || true
        fi
        rm -rf "$STAGE" 2>/dev/null || true
    fi
    if [ "$SHIM_CREATED" = 1 ] && [ -L "$SHIM" ]; then
        rm -f "$SHIM" 2>/dev/null || true
    fi
    if [ "$CREATED_BRIDGE_DIR" = 1 ] && [ -d "$BRIDGE_DIR" ] \
       && [ -z "$(ls -A "$BRIDGE_DIR" 2>/dev/null)" ]; then
        rmdir "$BRIDGE_DIR" 2>/dev/null || true
    fi
    if [ "$CREATED_CONF_DIR" = 1 ] && [ -d "$CONF_DIR" ] \
       && [ -z "$(ls -A "$CONF_DIR" 2>/dev/null)" ]; then
        rmdir "$CONF_DIR" 2>/dev/null || true
    fi
    exit "$status"
}
trap rollback EXIT HUP INT TERM

# --- validation (nothing mutated past here until staging) --------------------
if [ -z "$HOME" ] || [ ! -d "$HOME" ]; then die "HOME is not set or missing"; fi
command -v jq >/dev/null 2>&1 || die "jq is required (not found on PATH)"
if [ ! -r "$WRAPPER_SRC" ]; then die "wrapper source not readable: $WRAPPER_SRC"; fi
if [ ! -r "$HOOK_SRC" ]; then die "hook source not readable: $HOOK_SRC"; fi
if [ ! -r "$FRAGMENT" ]; then die "hooks fragment not readable: $FRAGMENT"; fi

# fragment must be an array of objects with only known handler keys and
# exactly the seven managed names, each exactly once
jq -e '
    type == "array" and length == 7 and
    (map(.name) == $managed) and
    (map(.name) | unique | length == 7) and
    all(.[]; (keys | sort) == (["event","handler","name"] | sort)) and
    all(.[]; (.handler | keys | sort) == ["bash"])
' --argjson managed "$MANAGED" "$FRAGMENT" >/dev/null 2>&1 \
    || die "hooks fragment failed validation: $FRAGMENT"

# existing hooks.json: missing -> []; otherwise must parse as an array
if [ -e "$HOOKS" ]; then
    if [ ! -r "$HOOKS" ]; then die "existing hooks.json not readable: $HOOKS"; fi
    jq -e 'type == "array"' "$HOOKS" >/dev/null 2>&1 \
        || die "existing hooks.json is not a JSON array: $HOOKS"
    EXISTING="$HOOKS"
else
    EXISTING=""
fi

if [ "$PATH_SHIM" = 1 ]; then
    # A pre-existing shim that already points at the managed wrapper is fine
    # (idempotent); anything else named `pi` at the shim path is a loud
    # collision. --path-shim-force deliberately shadows a `pi` found
    # elsewhere on PATH (the real binary stays invocable by absolute path).
    if [ -e "$SHIM" ] || [ -L "$SHIM" ]; then
        if [ "$(readlink "$SHIM" 2>/dev/null || true)" != "$DEST_WRAPPER" ]; then
            die "refusing to touch existing pi at $SHIM (not ours); resolve manually"
        fi
    else
        if [ "$SHIM_FORCE" = 0 ] && command -v pi >/dev/null 2>&1; then
            die "another pi exists on PATH: $(command -v pi); refusing to shim (use --path-shim-force to shadow it)"
        fi
    fi
fi

# --- staging -------------------------------------------------------------------
if [ ! -d "$CONF_DIR" ]; then CREATED_CONF_DIR=1; fi
if [ ! -d "$BRIDGE_DIR" ]; then CREATED_BRIDGE_DIR=1; fi
mkdir -p "$BRIDGE_DIR"
STAGE=$(mktemp -d "$BRIDGE_DIR/.install-bridge.XXXXXX") || die "mktemp failed in $BRIDGE_DIR"

if [ -e "$DEST_WRAPPER" ]; then HAD_WRAPPER=1; cp -p "$DEST_WRAPPER" "$STAGE/backup-wrapper" || die "backup of existing wrapper failed"; fi
if [ -e "$DEST_HOOK" ]; then HAD_HOOK=1; cp -p "$DEST_HOOK" "$STAGE/backup-hook" || die "backup of existing hook failed"; fi
if [ -e "$HOOKS" ]; then HAD_HOOKS=1; cp -p "$HOOKS" "$STAGE/backup-hooks.json" || die "backup of existing hooks.json failed"; fi

cp "$WRAPPER_SRC" "$STAGE/pi-polytoken" || die "staging wrapper failed"
cp "$HOOK_SRC" "$STAGE/orca-pi-hook.sh" || die "staging hook failed"
chmod 0755 "$STAGE/pi-polytoken" "$STAGE/orca-pi-hook.sh" || die "chmod of staged scripts failed"

if [ "$HAD_HOOKS" = 1 ]; then
    jq -c --argjson managed "$MANAGED" --slurpfile frag "$FRAGMENT" '
        (map(select(.name as $n | $managed | index($n) | not)) + $frag[0])
    ' "$HOOKS" > "$STAGE/hooks.json" || die "merge computation failed"
else
    jq -cn --slurpfile frag "$FRAGMENT" '$frag[0]' > "$STAGE/hooks.json" || die "fragment copy failed"
fi
# merged output must parse as an array (belt and braces)
jq -e 'type == "array"' "$STAGE/hooks.json" >/dev/null 2>&1 || die "merged hooks.json failed validation"

# timestamped persistent backup before any modify of hooks.json
# (name includes the PID: two installs in the same second must not clobber
# each other's backup)
if [ "$HAD_HOOKS" = 1 ]; then
    mkdir -p "$BACKUP_DIR"
    ts=$(date '+%Y%m%dT%H%M%S')
    cp -p "$HOOKS" "$BACKUP_DIR/hooks.json.$ts.$$" || die "timestamped backup failed"
    # keep the 10 newest backups
    ls -1t "$BACKUP_DIR"/hooks.json.* 2>/dev/null | tail -n +11 | while IFS= read -r old; do rm -f "$old"; done || true
fi

# --- commit (scripts first, hooks.json LAST) -----------------------------------
if ! mv "$STAGE/pi-polytoken" "$DEST_WRAPPER"; then
    echo "install-bridge: wrapper commit failed; rolling back" >&2
    exit 1
fi
COMMITTED_WRAPPER=1
if ! mv "$STAGE/orca-pi-hook.sh" "$DEST_HOOK"; then
    echo "install-bridge: hook script commit failed; rolling back" >&2
    exit 1
fi
COMMITTED_HOOK=1
if ! mv "$STAGE/hooks.json" "$HOOKS"; then
    echo "install-bridge: hooks.json commit failed; rolling back" >&2
    exit 1
fi
COMMITTED_HOOKS=1

if [ "$PATH_SHIM" = 1 ]; then
    if ! mkdir -p "$SHIM_DIR" || ! ln -sfn "$DEST_WRAPPER" "$SHIM"; then
        echo "install-bridge: PATH shim creation failed at $SHIM; rolling back" >&2
        exit 1
    fi
    SHIM_CREATED=1
fi

trap - EXIT HUP INT TERM
rm -rf "$STAGE"
echo "installed bridge: $DEST_WRAPPER, $DEST_HOOK, $HOOKS"
if [ "$PATH_SHIM" = 1 ]; then echo "shim $SHIM -> $DEST_WRAPPER"; fi
