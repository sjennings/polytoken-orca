#!/bin/sh
# uninstall-bridge.sh — remove the v1 Polytoken→Orca bridge completely.
#
# Removes ONLY the seven exact managed hook entries from hooks.json (any
# other entry — including other orca-* names — is preserved), deletes the
# installed files under $HOME/.config/polytoken/orca-bridge/ (removing the
# directory if then empty), and removes the ~/.local/bin/pi PATH shim only
# when it still resolves to the managed wrapper.

set -eu

SRC_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
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
COMMITTED_HOOKS=0

rollback() {
    status=$?
    if [ -n "$STAGE" ] && [ -d "$STAGE" ]; then
        if [ "$HAD_HOOKS" = 1 ] && [ "$COMMITTED_HOOKS" = 0 ] && [ -f "$STAGE/backup-hooks.json" ]; then
            cp -p "$STAGE/backup-hooks.json" "$HOOKS" 2>/dev/null || true
        fi
        rm -rf "$STAGE" 2>/dev/null || true
    fi
    exit "$status"
}
trap rollback EXIT HUP INT TERM

if [ -z "$HOME" ] || [ ! -d "$HOME" ]; then die "HOME is not set or missing"; fi

# --- validation + staging ------------------------------------------------------
FILTERED=""
if [ -e "$HOOKS" ]; then
    if [ ! -r "$HOOKS" ]; then die "hooks.json not readable: $HOOKS"; fi
    if command -v jq >/dev/null 2>&1; then
        jq -e 'type == "array"' "$HOOKS" >/dev/null 2>&1 \
            || die "hooks.json is not a JSON array: $HOOKS"
        HAS_MANAGED=$(jq -e --argjson managed "$MANAGED" \
            'any(.[]; .name as $n | $managed | index($n))' "$HOOKS" 2>/dev/null || echo false)
        if [ "$HAS_MANAGED" = true ]; then
            HAD_HOOKS=1
            STAGE=$(mktemp -d "${TMPDIR:-/tmp}/uninstall-bridge.XXXXXX") || die "mktemp failed"
            jq -c --argjson managed "$MANAGED" \
                'map(select(.name as $n | $managed | index($n) | not))' \
                "$HOOKS" > "$STAGE/hooks.json" || die "filter computation failed"
        fi
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

# --- commit: hooks.json first, then files ----------------------------------------
if [ "$HAD_HOOKS" = 1 ]; then
    if ! mv "$STAGE/hooks.json" "$HOOKS"; then
        echo "uninstall-bridge: hooks.json commit failed; rolling back" >&2
        exit 1
    fi
    COMMITTED_HOOKS=1
    echo "removed managed hook entries from $HOOKS"
fi

removed=0
if [ -e "$DEST_HOOK" ]; then rm -f "$DEST_HOOK" || die "failed to remove $DEST_HOOK"; removed=1; fi
if [ -e "$DEST_WRAPPER" ]; then rm -f "$DEST_WRAPPER" || die "failed to remove $DEST_WRAPPER"; removed=1; fi
rm -rf "$BACKUP_DIR" 2>/dev/null || true

if [ -L "$SHIM" ]; then
    if [ "$(readlink "$SHIM" 2>/dev/null || true)" = "$DEST_WRAPPER" ]; then
        rm -f "$SHIM" || die "failed to remove shim $SHIM"
        echo "removed shim $SHIM"
    else
        echo "preserved shim $SHIM (points elsewhere, not ours)"
    fi
fi

if [ -d "$BRIDGE_DIR" ] && [ -z "$(ls -A "$BRIDGE_DIR" 2>/dev/null)" ]; then
    rmdir "$BRIDGE_DIR" 2>/dev/null && echo "removed $BRIDGE_DIR"
fi

if [ "$removed" = 0 ] && [ "$HAD_HOOKS" = 0 ]; then
    echo "nothing to uninstall"
fi
[ -z "$STAGE" ] || { trap - EXIT HUP INT TERM; rm -rf "$STAGE"; }
exit 0
