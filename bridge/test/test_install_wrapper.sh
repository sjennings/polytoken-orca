#!/bin/sh
# test_install_wrapper.sh — install-wrapper.sh / uninstall-wrapper.sh
# safety tests (AC.8), run under a temporary HOME and controlled PATH.

# (No `set -u`: several helpers forward possibly-empty "$@" — fatal under
# `set -u` on macOS bash 3.2.)

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
INST="$HERE/../install-wrapper.sh"
UNINST="$HERE/../uninstall-wrapper.sh"
SRC="$HERE/../../bin/pi-polytoken"

PASS=0
FAIL=0
BASE="/bin:/usr/bin:/sbin:/usr/sbin"

JQDIR=""
if command -v jq >/dev/null 2>&1; then JQDIR=$(dirname -- "$(command -v jq)"); fi

T=$(mktemp -d "${TMPDIR:-/tmp}/ptiw.XXXXXX") || { echo "mktemp failed"; exit 1; }
trap 'rm -rf "$T"' EXIT HUP INT TERM

H="$T/home"
mkdir -p "$H"

ok()   { PASS=$((PASS + 1)); echo "ok   - $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "FAIL - $1${2:+: $2}"; }

check() { # desc, condition-result($? passed via if)
    if [ "$1" = 0 ]; then ok "$2"; else bad "$2" "${3:-unexpected state}"; fi
}

mode_of() { ls -l "$1" | cut -c 1-10; }

stage_leftovers() { # dir -> count of .install-wrapper.* leftovers
    ls -A "$1" 2>/dev/null | grep -c '^\.install-wrapper' || true
}

# fake mv (failure injection)
MV_REAL=$(command -v mv)
mkdir -p "$T/bin"
cat > "$T/bin/mv" <<EOF
#!/bin/sh
if [ -n "\$FAKE_MV_FAIL_AT" ] && [ -n "\$FAKE_MV_COUNT_FILE" ]; then
    n=\$(cat "\$FAKE_MV_COUNT_FILE" 2>/dev/null || echo 0)
    n=\$((n + 1))
    echo "\$n" > "\$FAKE_MV_COUNT_FILE"
    if [ "\$n" = "\$FAKE_MV_FAIL_AT" ]; then
        echo "fake-mv: injected failure #\$n" >&2
        exit 1
    fi
fi
exec "$MV_REAL" "\$@"
EOF
chmod 0755 "$T/bin/mv"

CONF="$H/.config/polytoken"
BRIDGE_DIR="$CONF/orca-bridge"
DEST="$BRIDGE_DIR/pi-polytoken"
SHIM="$H/.local/bin/pi"

# --- 1. basic install -------------------------------------------------------
rm -f "$T/out"; HOME="$H" PATH="$BASE" sh "$INST" > "$T/out" 2>&1
rc=$?
if [ $rc = 0 ] && [ -f "$DEST" ] && [ "$(mode_of "$DEST")" = "-rwxr-xr-x" ] \
   && cmp -s "$SRC" "$DEST" && [ "$(stage_leftovers "$BRIDGE_DIR")" = 0 ]; then
    ok "install lands at stable path, mode 0755, content matches"
else
    bad "basic install" "rc=$rc mode=$(mode_of "$DEST" 2>/dev/null) leftovers=$(stage_leftovers "$BRIDGE_DIR" 2>/dev/null)"
fi

# --- 2. idempotent re-install ------------------------------------------------
echo "# local edit" >> "$DEST"
HOME="$H" PATH="$BASE" sh "$INST" > /dev/null 2>&1
if cmp -s "$SRC" "$DEST" && [ "$(stage_leftovers "$BRIDGE_DIR")" = 0 ]; then
    ok "re-install is idempotent (refreshes content, no leftovers)"
else
    bad "re-install idempotent"
fi

# --- 3. PATH shim -------------------------------------------------------------
HOME="$H" PATH="$BASE" sh "$INST" --path-shim > /dev/null 2>&1
rc=$?
if [ $rc = 0 ] && [ -L "$SHIM" ] && [ "$(readlink "$SHIM")" = "$DEST" ]; then
    ok "--path-shim creates shim -> DEST"
else
    bad "--path-shim" "rc=$rc shim=$(readlink "$SHIM" 2>/dev/null)"
fi
HOME="$H" PATH="$BASE" sh "$INST" --path-shim > /dev/null 2>&1
if [ "$(readlink "$SHIM")" = "$DEST" ]; then ok "shim re-install idempotent"; else bad "shim re-install idempotent"; fi

# --- 4. shim collision: another pi on PATH ------------------------------------
H2="$T/home2"; mkdir -p "$H2/otherbin"
printf '#!/bin/sh\necho real-pi\n' > "$H2/otherbin/pi"; chmod 0755 "$H2/otherbin/pi"
HOME="$H2" PATH="$H2/otherbin:$BASE" sh "$INST" --path-shim > "$T/out" 2>&1
rc=$?
if [ $rc != 0 ] && [ ! -e "$H2/.config/polytoken/orca-bridge/pi-polytoken" ] \
   && [ ! -e "$H2/.local/bin/pi" ] && grep -q "another pi" "$T/out"; then
    ok "shim refused on collision; validation preceded any mutation"
else
    bad "shim collision" "rc=$rc out=$(cat "$T/out")"
fi

# --- 5. shim exists but points elsewhere --------------------------------------
H3="$T/home3"; mkdir -p "$H3/.local/bin"
ln -s /usr/bin/true "$H3/.local/bin/pi"
HOME="$H3" PATH="$BASE" sh "$INST" --path-shim > "$T/out" 2>&1
rc=$?
if [ $rc != 0 ] && [ "$(readlink "$H3/.local/bin/pi")" = "/usr/bin/true" ] \
   && [ ! -e "$H3/.config/polytoken/orca-bridge/pi-polytoken" ]; then
    ok "retargeted foreign shim preserved; install refused"
else
    bad "retargeted shim" "rc=$rc"
fi

# --- 5b. --path-shim-force shadows a foreign pi on PATH ----------------------
H10="$T/home10"; mkdir -p "$H10/otherbin"
printf '#!/bin/sh\necho real-pi\n' > "$H10/otherbin/pi"; chmod 0755 "$H10/otherbin/pi"
HOME="$H10" PATH="$H10/otherbin:$BASE" sh "$INST" --path-shim-force > "$T/out" 2>&1
rc=$?
if [ $rc = 0 ] && [ -L "$H10/.local/bin/pi" ] \
   && [ "$(readlink "$H10/.local/bin/pi")" = "$H10/.config/polytoken/orca-bridge/pi-polytoken" ] \
   && [ "$(cat "$H10/otherbin/pi")" != "" ]; then
    ok "--path-shim-force shadows foreign pi; real pi file untouched"
else
    bad "force shim" "rc=$rc shim=$(readlink "$H10/.local/bin/pi" 2>/dev/null)"
fi
# force must still refuse to clobber a foreign file at the shim path itself
H10b="$T/home10b"; mkdir -p "$H10b/.local/bin"
printf '#!/bin/sh\necho not-ours\n' > "$H10b/.local/bin/pi"; chmod 0755 "$H10b/.local/bin/pi"
HOME="$H10b" PATH="$BASE" sh "$INST" --path-shim-force > "$T/out" 2>&1
rc=$?
if [ $rc != 0 ] && grep -q "not ours" "$T/out" && [ ! -e "$H10b/.config/polytoken/orca-bridge/pi-polytoken" ]; then
    ok "force still refuses a foreign pi AT the shim path"
else
    bad "force clobber guard" "rc=$rc out=$(cat "$T/out")"
fi

# --- 6. commit failure: no pre-existing wrapper --------------------------------
H4="$T/home4"; mkdir -p "$H4"
rm -f "$T/mvcount"
FAKE_MV_FAIL_AT=1 FAKE_MV_COUNT_FILE="$T/mvcount" HOME="$H4" PATH="$T/bin:$BASE" \
    sh "$INST" > "$T/out" 2>&1
rc=$?
if [ $rc != 0 ] && [ ! -e "$H4/.config/polytoken/orca-bridge/pi-polytoken" ]; then
    if [ -e "$H4/.config" ] && [ -n "$(ls -A "$H4/.config/polytoken/orca-bridge" 2>/dev/null)" ]; then
        bad "commit failure rollback" "leftovers remain: $(ls -A "$H4/.config/polytoken/orca-bridge")"
    else
        ok "commit failure with no prior install: nothing left behind"
    fi
else
    bad "commit failure with no prior install" "rc=$rc"
fi

# --- 7. commit failure: pre-existing wrapper restored byte+mode ----------------
printf 'OLD-WRAPPER\n' > "$DEST"; chmod 0700 "$DEST"
rm -f "$T/mvcount"
FAKE_MV_FAIL_AT=1 FAKE_MV_COUNT_FILE="$T/mvcount" HOME="$H" PATH="$T/bin:$BASE" \
    sh "$INST" > /dev/null 2>&1
rc=$?
if [ $rc != 0 ] && [ "$(cat "$DEST")" = "OLD-WRAPPER" ] && [ "$(mode_of "$DEST")" = "-rwx------" ] \
   && [ "$(stage_leftovers "$BRIDGE_DIR")" = 0 ]; then
    ok "commit failure with prior install: restored byte+mode identical"
else
    bad "commit failure with prior install" "rc=$rc content=$(cat "$DEST" 2>/dev/null) mode=$(mode_of "$DEST")"
fi

# --- 8. uninstall removes wrapper + shim-ours + dir -----------------------------
HOME="$H" PATH="$BASE" sh "$INST" > /dev/null 2>&1   # clean install (over OLD-WRAPPER)
HOME="$H" PATH="$BASE" sh "$INST" --path-shim > /dev/null 2>&1
HOME="$H" PATH="$BASE" sh "$UNINST" > "$T/out" 2>&1
rc=$?
if [ $rc = 0 ] && [ ! -e "$DEST" ] && [ ! -e "$SHIM" ] && [ ! -d "$BRIDGE_DIR" ]; then
    ok "uninstall removes wrapper, our shim, and the orca-bridge dir"
else
    bad "uninstall" "rc=$rc dest=$([ -e "$DEST" ] && echo present) shim=$([ -e "$SHIM" ] && echo present)"
fi

# --- 9. uninstall preserves retargeted shim ------------------------------------
H5="$T/home5"; mkdir -p "$H5/.local/bin"
HOME="$H5" PATH="$BASE" sh "$INST" --path-shim > /dev/null 2>&1
ln -sfn /usr/bin/true "$SHIM" 2>/dev/null || true
ln -sfn /usr/bin/true "$H5/.local/bin/pi"
HOME="$H5" PATH="$BASE" sh "$UNINST" > "$T/out" 2>&1
if [ ! -e "$H5/.config/polytoken/orca-bridge/pi-polytoken" ] \
   && [ "$(readlink "$H5/.local/bin/pi")" = "/usr/bin/true" ]; then
    ok "uninstall preserves shim retargeted elsewhere"
else
    bad "uninstall retargeted shim"
fi

# --- 10. uninstall refuses under v1: managed hook entries (jq path) --------------
H6="$T/home6"; mkdir -p "$H6/.config/polytoken"
HOME="$H6" PATH="$BASE" sh "$INST" > /dev/null 2>&1
if [ -n "$JQDIR" ]; then
    printf '[{"name":"orca-pi-bridge-stop","event":"stop","handler":{"bash":"true"}}]\n' \
        > "$H6/.config/polytoken/hooks.json"
    HOME="$H6" PATH="$JQDIR:$BASE" sh "$UNINST" > "$T/out" 2>&1
    rc=$?
    if [ $rc != 0 ] && [ -e "$H6/.config/polytoken/orca-bridge/pi-polytoken" ] \
       && grep -q "uninstall-bridge" "$T/out"; then
        ok "uninstall refuses under v1 hooks.json (jq detection)"
    else
        bad "v1 refusal (jq)" "rc=$rc"
    fi

    # --- 12. same via grep fallback (jq not executable on PATH) ---------------
    H7="$T/home7"; mkdir -p "$H7/.config/polytoken"
    HOME="$H7" PATH="$BASE" sh "$INST" > /dev/null 2>&1
    printf '[{"name":"orca-pi-bridge-session-start","event":"session_start","handler":{"bash":"true"}}]\n' \
        > "$H7/.config/polytoken/hooks.json"
    mkdir -p "$T/nojq"
    : > "$T/nojq/jq"; chmod 0644 "$T/nojq/jq"   # decoy: found by name, not executable
    # minimal PATH with just the tools the uninstaller needs — no jq anywhere
    mkdir -p "$T/minpath"
    for c in grep rm rmdir ls readlink cat; do
        real=$(command -v "$c") && ln -sf "$real" "$T/minpath/$c"
    done
    if PATH="$T/minpath" command -v jq >/dev/null 2>&1; then
        ok "skipped: minimal PATH still resolves jq; grep fallback untestable here"
    else
        HOME="$H7" PATH="$T/minpath" sh "$UNINST" > "$T/out" 2>&1
        rc=$?
        if [ $rc != 0 ] && [ -e "$H7/.config/polytoken/orca-bridge/pi-polytoken" ]; then
            ok "uninstall refuses under v1 via grep fallback"
        else
            bad "v1 refusal (grep fallback)" "rc=$rc"
        fi
    fi
else
    ok "skipped: jq unavailable in test environment"
fi

# --- 11. uninstall refuses under v1: hook script on disk --------------------------
H8="$T/home8"; mkdir -p "$H8"
HOME="$H8" PATH="$BASE" sh "$INST" > /dev/null 2>&1
printf '#!/bin/sh\nexit 0\n' > "$H8/.config/polytoken/orca-bridge/orca-pi-hook.sh"
HOME="$H8" PATH="$BASE" sh "$UNINST" > "$T/out" 2>&1
rc=$?
if [ $rc != 0 ] && [ -e "$H8/.config/polytoken/orca-bridge/pi-polytoken" ] \
   && [ -e "$H8/.config/polytoken/orca-bridge/orca-pi-hook.sh" ] \
   && grep -q "uninstall-bridge" "$T/out"; then
    ok "uninstall refuses under v1 hook script (no mutation)"
else
    bad "v1 refusal (hook script)" "rc=$rc"
fi

# --- 14. uninstall with nothing installed ------------------------------------------
H9="$T/home9"; mkdir -p "$H9"
HOME="$H9" PATH="$BASE" sh "$UNINST" > "$T/out" 2>&1
rc=$?
if [ $rc = 0 ] && grep -q "nothing to uninstall" "$T/out"; then
    ok "uninstall with nothing installed exits 0"
else
    bad "uninstall nothing" "rc=$rc out=$(cat "$T/out")"
fi

echo "----"
echo "pass=$PASS fail=$FAIL"
[ "$FAIL" = 0 ]
