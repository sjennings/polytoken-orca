#!/bin/sh
# uninstall-wrapper.sh — remove the standalone (v0) pi-polytoken wrapper.
#
# Refuses to run while a v1 bridge installation is detected (any managed
# bridge hook entry in hooks.json, or the managed hook script on disk);
# use uninstall-bridge.sh instead — it owns the complete installation.

set -u

CONF_DIR="$HOME/.config/polytoken"
BRIDGE_DIR="$CONF_DIR/orca-bridge"
DEST="$BRIDGE_DIR/pi-polytoken"
HOOKS="$CONF_DIR/hooks.json"
HOOK_SCRIPT="$BRIDGE_DIR/orca-pi-hook.sh"
SHIM_DIR="$HOME/.local/bin"
SHIM="$SHIM_DIR/pi"

MANAGED_NAMES="orca-pi-bridge-session-start orca-pi-bridge-pre-user-prompt orca-pi-bridge-pre-tool-use orca-pi-bridge-notification orca-pi-bridge-post-tool-use orca-pi-bridge-post-tool-use-failure orca-pi-bridge-stop"

die() { echo "uninstall-wrapper: $*" >&2; exit 1; }

# --- v1 detection: refuse without mutation ---------------------------------
if [ -e "$HOOK_SCRIPT" ]; then
    die "v1 bridge installation detected ($HOOK_SCRIPT present); run uninstall-bridge.sh instead"
fi

if [ -r "$HOOKS" ]; then
    bridge_entries=0
    if command -v jq >/dev/null 2>&1; then
        for n in $MANAGED_NAMES; do
            count=$(jq --arg n "$n" '[.[]? | select(.name == $n)] | length' "$HOOKS" 2>/dev/null || echo 0)
            [ "${count:-0}" -gt 0 ] 2>/dev/null && bridge_entries=1 && break
        done
    else
        for n in $MANAGED_NAMES; do
            if grep -q "\"$n\"" "$HOOKS" 2>/dev/null; then bridge_entries=1; break; fi
        done
    fi
    if [ "$bridge_entries" = 1 ]; then
        die "v1 bridge installation detected (managed hook entries in $HOOKS); run uninstall-bridge.sh instead"
    fi
fi

# --- removal ----------------------------------------------------------------
removed=0
if [ -e "$DEST" ] || [ -L "$DEST" ]; then
    rm -f "$DEST" || die "failed to remove $DEST"
    removed=1
    echo "removed $DEST"
fi

if [ -L "$SHIM" ]; then
    if [ "$(readlink "$SHIM" 2>/dev/null || true)" = "$DEST" ]; then
        rm -f "$SHIM" || die "failed to remove shim $SHIM"
        echo "removed shim $SHIM"
    else
        echo "preserved shim $SHIM (points elsewhere, not ours)"
    fi
fi

# remove orca-bridge dir only if we own everything left in it (i.e. it's empty)
if [ -d "$BRIDGE_DIR" ] && [ -z "$(ls -A "$BRIDGE_DIR" 2>/dev/null)" ]; then
    rmdir "$BRIDGE_DIR" 2>/dev/null && echo "removed $BRIDGE_DIR"
fi

[ "$removed" = 1 ] || echo "nothing to uninstall (wrapper not present)"
exit 0
