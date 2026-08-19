#!/bin/sh
# uninstall-bridge.sh — remove the v1 Polytoken→Orca bridge completely.
#
# Removes ONLY the seven exact managed hook entries from hooks.json (any
# other entry — including other orca-* names — is preserved), deletes the
# installed files under $HOME/.config/polytoken/orca-bridge/ (removing the
# directory if then empty), and removes the ~/.local/bin/pi PATH shim only
# when it still resolves to the managed wrapper.
#
# Transaction: validate (fail closed on malformed config) → stage (rename
# owned files aside on the same filesystem, compute filtered hooks.json) →
# commit hooks.json LAST via atomic mv → on any pre-commit failure restore
# everything (renames back, shim recreated) byte/mode/target-identical.

set -eu

CONF_DIR="$HOME/.config/polytoken"
BRIDGE_DIR="$CONF_DIR/orca-bridge"
BACKUP_DIR="$BRIDGE_DIR/backups"
HOOKS="$CONF_DIR/hooks.json"
DEST_WRAPPER="$BRIDGE_DIR/pi-polytoken"
DEST_HOOK="$BRIDGE_DIR/orca-pi-hook.sh"
SHIM_DIR="$HOME/.local/bin"
SHIM="$SHIM_DIR/pi"

MANAGED='["orca-pi-bridge-session-start","orca-pi-bridge-pre-user-prompt","orca-pi-bridge-pre-tool-use","orca-pi-bridge-notification","orca-pi-bridge-post-tool-use","orca-pi-bridge-post-tool-use-failure","orca-pi-bridge-stop"]'

die() { echo "uninstall-bridge: $*" >&2; exit 1; }

STAGE=""
HAD_HOOKS=0
HAD_HOOK=0
HAD_WRAPPER=0
HAD_SHIM_OURS=0
SHIM_TARGET=""
COMMITTED_HOOKS=0

rollback() {
    status=$?
    trap - EXIT HUP INT TERM   # never run twice (signal + exit)
    if [ -n "$STAGE" ] && [ -d "$STAGE" ]; then
        # restore renamed files (rename back = byte+mode identical)
        if [ "$HAD_HOOK" = 1 ] && [ -e "$STAGE/hook" ] && [ ! -e "$DEST_HOOK" ]; then
            mv "$STAGE/hook" "$DEST_HOOK" 2>/dev/null || true
        fi
        if [ "$HAD_WRAPPER" = 1 ] && [ -e "$STAGE/wrapper" ] && [ ! -e "$DEST_WRAPPER" ]; then
            mv "$STAGE/wrapper" "$DEST_WRAPPER" 2>/dev/null || true
        fi
        # restore hooks.json if we never committed the filtered version
        if [ "$HAD_HOOKS" = 1 ] && [ "$COMMITTED_HOOKS" = 0 ] && [ -f "$STAGE/backup-hooks.json" ]; then
            cp -p "$STAGE/backup-hooks.json" "$HOOKS" 2>/dev/null || true
        fi
        # recreate our shim if we removed it pre-commit
        if [ "$HAD_SHIM_OURS" = 1 ] && [ -n "$SHIM_TARGET" ] && [ ! -e "$SHIM" ] && [ ! -L "$SHIM" ]; then
            ln -sfn "$SHIM_TARGET" "$SHIM" 2>/dev/null || true
        fi
        rm -rf "$STAGE" 2>/dev/null || true
    fi
    exit "$status"
}
trap rollback EXIT HUP INT TERM

if [ -z "$HOME" ] || [ ! -d "$HOME" ]; then die "HOME is not set or missing"; fi

# --- validation (fail closed; nothing mutated) ---------------------------------
FILTERED=""
if [ -e "$HOOKS" ]; then
    if [ ! -r "$HOOKS" ]; then die "hooks.json not readable: $HOOKS"; fi
    if command -v jq >/dev/null 2>&1; then
        # array of objects with string names — anything else fails closed
        jq -e 'type == "array" and all(.[]; type == "object" and ((.name // null) | type == "string"))' \
            "$HOOKS" >/dev/null 2>&1 \
            || die "hooks.json is malformed (not an array of {name: string} entries): $HOOKS"
        HAS_MANAGED=$(jq -r --argjson managed "$MANAGED" \
            'any(.[]; .name as $n | $managed | index($n))' "$HOOKS" 2>/dev/null || echo error)
        [ "$HAS_MANAGED" = true ] || [ "$HAS_MANAGED" = false ] \
            || die "failed to analyze hooks.json (jq error); refusing to mutate"
        if [ "$HAS_MANAGED" = true ]; then HAD_HOOKS=1; fi
    else
        # no jq: refuse to touch config that contains managed entries
        found=""
        for n in orca-pi-bridge-session-start orca-pi-bridge-pre-user-prompt \
                 orca-pi-bridge-pre-tool-use orca-pi-bridge-notification \
                 orca-pi-bridge-post-tool-use orca-pi-bridge-post-tool-use-failure \
                 orca-pi-bridge-stop; do
            if grep -q "\"$n\"" "$HOOKS" 2>/dev/null; then found="$found $n"; fi
        done
        if [ -n "$found" ]; then
            die "hooks.json contains managed entries:$found — jq is required to remove them safely"
        fi
    fi
fi

# --- staging (same filesystem as hooks.json) ------------------------------------
mkdir -p "$CONF_DIR"
STAGE=$(mktemp -d "$CONF_DIR/.uninstall-bridge.XXXXXX") || die "mktemp failed in $CONF_DIR"

if [ "$HAD_HOOKS" = 1 ]; then
    cp -p "$HOOKS" "$STAGE/backup-hooks.json" || die "backup of hooks.json failed"
    jq -c --argjson managed "$MANAGED" \
        'map(select(.name as $n | $managed | index($n) | not))' \
        "$HOOKS" > "$STAGE/hooks.json" || die "filter computation failed"
fi
if [ -e "$DEST_HOOK" ]; then HAD_HOOK=1; fi
if [ -e "$DEST_WRAPPER" ]; then HAD_WRAPPER=1; fi
if [ "$HAD_HOOK" = 1 ]; then mv "$DEST_HOOK" "$STAGE/hook" || die "staging hook script aside failed"; fi
if [ "$HAD_WRAPPER" = 1 ]; then mv "$DEST_WRAPPER" "$STAGE/wrapper" || die "staging wrapper aside failed"; fi
if [ -L "$SHIM" ] && [ "$(readlink "$SHIM" 2>/dev/null || true)" = "$DEST_WRAPPER" ]; then
    HAD_SHIM_OURS=1
    SHIM_TARGET="$DEST_WRAPPER"
    rm -f "$SHIM" || die "removal of our shim failed"
fi

# --- commit: hooks.json LAST -----------------------------------------------------
if [ "$HAD_HOOKS" = 1 ]; then
    if ! mv "$STAGE/hooks.json" "$HOOKS"; then
        echo "uninstall-bridge: hooks.json commit failed; rolling back" >&2
        exit 1
    fi
    COMMITTED_HOOKS=1
    echo "removed managed hook entries from $HOOKS"
fi

# --- success: drop staged originals and finish ------------------------------------
trap - EXIT HUP INT TERM
rm -rf "$STAGE" "$BACKUP_DIR" 2>/dev/null || true
STAGE=""

if [ "$HAD_SHIM_OURS" = 1 ]; then echo "removed shim $SHIM"; fi
if [ -d "$BRIDGE_DIR" ] && [ -z "$(ls -A "$BRIDGE_DIR" 2>/dev/null)" ]; then
    rmdir "$BRIDGE_DIR" 2>/dev/null && echo "removed $BRIDGE_DIR"
fi
if [ "$HAD_HOOKS" = 0 ] && [ "$HAD_HOOK" = 0 ] && [ "$HAD_WRAPPER" = 0 ] && [ "$HAD_SHIM_OURS" = 0 ]; then
    echo "nothing to uninstall"
fi
exit 0
