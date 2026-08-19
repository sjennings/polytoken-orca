#!/bin/sh
# test_install_bridge.sh — install-bridge.sh / uninstall-bridge.sh safety
# tests (AC.4), run under a temporary HOME, including sequenced mv-failure
# injection proving atomicity, and cross-installer lifecycle transitions.

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
INST="$HERE/../install-bridge.sh"
UNINST="$HERE/../uninstall-bridge.sh"
WRAP_INST="$HERE/../install-wrapper.sh"
HOOK_SRC="$HERE/../orca-pi-hook.sh"
WRAP_SRC="$HERE/../../bin/pi-polytoken"
FRAGMENT="$HERE/../hooks.fragment.json"

PASS=0
FAIL=0
BASE="/bin:/usr/bin:/sbin:/usr/sbin"
ok()  { PASS=$((PASS + 1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL - $1${2:+: $2}"; }
mode_of() { ls -l "$1" 2>/dev/null | cut -c 1-10; }

T=$(mktemp -d "${TMPDIR:-/tmp}/ptib.XXXXXX") || { echo "mktemp failed"; exit 1; }
trap 'rm -rf "$T"' EXIT HUP INT TERM

# fake mv for failure injection
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

# fake ln (failure injection for post-commit shim failures)
LN_REAL=$(command -v ln)
cat > "$T/bin/ln" <<EOF
#!/bin/sh
if [ -n "\$FAKE_LN_FAIL_AT" ] && [ -n "\$FAKE_LN_COUNT_FILE" ]; then
    n=\$(cat "\$FAKE_LN_COUNT_FILE" 2>/dev/null || echo 0)
    n=\$((n + 1))
    echo "\$n" > "\$FAKE_LN_COUNT_FILE"
    if [ "\$n" = "\$FAKE_LN_FAIL_AT" ]; then
        echo "fake-ln: injected failure #\$n" >&2
        exit 1
    fi
fi
exec "$LN_REAL" "\$@"
EOF
chmod 0755 "$T/bin/ln"

MANAGED_COUNT_EXPR='["orca-pi-bridge-session-start","orca-pi-bridge-pre-user-prompt","orca-pi-bridge-pre-tool-use","orca-pi-bridge-notification","orca-pi-bridge-post-tool-use","orca-pi-bridge-post-tool-use-failure","orca-pi-bridge-stop"] as $m | [ $m[] | . as $n | [ .[] | select(.name == $n) ] | length ]'

managed_per_name() { # hooks-file -> prints 7 counts
    jq -c --argjson m '["orca-pi-bridge-session-start","orca-pi-bridge-pre-user-prompt","orca-pi-bridge-pre-tool-use","orca-pi-bridge-notification","orca-pi-bridge-post-tool-use","orca-pi-bridge-post-tool-use-failure","orca-pi-bridge-stop"]' \
        '[ $m[] as $n | [ .[] | select(.name == $n) ] | length ]' "$1"
}

unrelated_count() { # hooks-file -> count of non-managed entries
    jq --argjson m '["orca-pi-bridge-session-start","orca-pi-bridge-pre-user-prompt","orca-pi-bridge-pre-tool-use","orca-pi-bridge-notification","orca-pi-bridge-post-tool-use","orca-pi-bridge-post-tool-use-failure","orca-pi-bridge-stop"]' \
        '[ .[] | select(.name as $n | $m | index($n) | not) ] | length' "$1"
}

UNRELATED='[{"name":"orca-custom-hook","event":"stop","handler":{"bash":"echo custom"}},{"name":"my-own-hook","event":"pre_tool_use","matcher":"shell_exec","handler":{"bash":"echo mine"}}]'

# =====================================================================
# 1. fresh install (no existing config at all)
# =====================================================================
H1="$T/h1"; mkdir -p "$H1"
HOME="$H1" PATH="$BASE" sh "$INST" > "$T/out" 2>&1
rc=$?
C1="$H1/.config/polytoken/hooks.json"; B1="$H1/.config/polytoken/orca-bridge"
if [ $rc = 0 ] && jq -e 'length == 7' "$C1" >/dev/null 2>&1 \
   && [ "$(managed_per_name "$C1")" = "[1,1,1,1,1,1,1]" ] \
   && [ "$(mode_of "$B1/pi-polytoken")" = "-rwxr-xr-x" ] \
   && [ "$(mode_of "$B1/orca-pi-hook.sh")" = "-rwxr-xr-x" ] \
   && cmp -s "$WRAP_SRC" "$B1/pi-polytoken" && cmp -s "$HOOK_SRC" "$B1/orca-pi-hook.sh"; then
    ok "fresh install: 7 managed entries, scripts 0755, content matches"
else
    bad "fresh install" "rc=$rc counts=$(managed_per_name "$C1" 2>/dev/null)"
fi

# =====================================================================
# 2. empty-array baseline (the live operator content) + idempotent re-run
# =====================================================================
H2="$T/h2"; mkdir -p "$H2/.config/polytoken"
printf '[]\n' > "$H2/.config/polytoken/hooks.json"
HOME="$H2" PATH="$BASE" sh "$INST" > /dev/null 2>&1
rc=$?
C2="$H2/.config/polytoken/hooks.json"
if [ $rc = 0 ] && [ "$(managed_per_name "$C2")" = "[1,1,1,1,1,1,1]" ] \
   && [ "$(jq 'length' "$C2")" = 7 ]; then
    ok "install over [] baseline"
else
    bad "install over []" "rc=$rc"
fi

# =====================================================================
# 3. unrelated entries preserved; repeated install stays single-entry
# =====================================================================
H3="$T/h3"; mkdir -p "$H3/.config/polytoken"
printf '%s\n' "$UNRELATED" > "$H3/.config/polytoken/hooks.json"
cp "$H3/.config/polytoken/hooks.json" "$T/orig3.json"
HOME="$H3" PATH="$BASE" sh "$INST" > /dev/null 2>&1
HOME="$H3" PATH="$BASE" sh "$INST" > /dev/null 2>&1   # repeat: idempotency
C3="$H3/.config/polytoken/hooks.json"
if [ "$(managed_per_name "$C3")" = "[1,1,1,1,1,1,1]" ] \
   && [ "$(jq 'length' "$C3")" = 9 ] \
   && [ "$(unrelated_count "$C3")" = 2 ] \
   && [ "$(jq -r '.[] | select(.name == "orca-custom-hook") | .handler.bash' "$C3")" = "echo custom" ]; then
    ok "unrelated entries (incl orca-custom-hook) preserved; repeat install idempotent"
else
    bad "unrelated preservation / idempotency" "counts=$(managed_per_name "$C3") len=$(jq 'length' "$C3" 2>/dev/null)"
fi

# =====================================================================
# 4. timestamped backup of prior hooks.json
# =====================================================================
BK="$H3/.config/polytoken/orca-bridge/backups"
found=""
for f in "$BK"/hooks.json.*; do
    if cmp -s "$f" "$T/orig3.json"; then found="$f"; break; fi
done
if [ -n "$found" ]; then
    ok "timestamped backup created with original content"
else
    bad "backup" "no backup matches original (files: $(ls "$BK" 2>/dev/null | tr '\n' ' '))"
fi

# =====================================================================
# 4b. --path-shim-force shadows a foreign pi on PATH
# =====================================================================
H4b="$T/h4b"; mkdir -p "$H4b/otherbin"
printf '#!/bin/sh\necho real-pi\n' > "$H4b/otherbin/pi"; chmod 0755 "$H4b/otherbin/pi"
HOME="$H4b" PATH="$H4b/otherbin:$BASE" sh "$INST" --path-shim-force > /dev/null 2>&1
rc=$?
if [ $rc = 0 ] && [ -L "$H4b/.local/bin/pi" ] \
   && [ "$(readlink "$H4b/.local/bin/pi")" = "$H4b/.config/polytoken/orca-bridge/pi-polytoken" ] \
   && [ "$(managed_per_name "$H4b/.config/polytoken/hooks.json")" = "[1,1,1,1,1,1,1]" ]; then
    ok "bridge --path-shim-force shadows foreign pi; install complete"
else
    bad "bridge force shim" "rc=$rc"
fi

# =====================================================================
# 5. malformed existing hooks.json: fail non-zero, no partial writes
# =====================================================================
H4="$T/h4"; mkdir -p "$H4/.config/polytoken"
printf '[{"name": broken\n' > "$H4/.config/polytoken/hooks.json"
cp "$H4/.config/polytoken/hooks.json" "$T/orig4.json"
HOME="$H4" PATH="$BASE" sh "$INST" > "$T/out" 2>&1
rc=$?
if [ $rc != 0 ] && cmp -s "$H4/.config/polytoken/hooks.json" "$T/orig4.json" \
   && [ ! -e "$H4/.config/polytoken/orca-bridge" ]; then
    ok "malformed hooks.json: non-zero, config byte-identical, no scripts installed"
else
    bad "malformed input" "rc=$rc"
fi

# =====================================================================
# 6. atomicity: sequenced mv-failure injection with pre-existing files
#    (pre-existing wrapper + hook script from an older install)
# =====================================================================
H5="$T/h5"; mkdir -p "$H5/.config/polytoken/orca-bridge"
printf 'OLD-WRAPPER\n' > "$H5/.config/polytoken/orca-bridge/pi-polytoken"
chmod 0700 "$H5/.config/polytoken/orca-bridge/pi-polytoken"
printf 'OLD-HOOK\n' > "$H5/.config/polytoken/orca-bridge/orca-pi-hook.sh"
chmod 0711 "$H5/.config/polytoken/orca-bridge/orca-pi-hook.sh"
printf '%s\n' "$UNRELATED" > "$H5/.config/polytoken/hooks.json"
cp "$H5/.config/polytoken/hooks.json" "$T/orig5.json"
D5="$H5/.config/polytoken/orca-bridge"
W5="$D5/pi-polytoken"; K5="$D5/orca-pi-hook.sh"; J5="$H5/.config/polytoken/hooks.json"

inj_fail() { # fail-at-ordinal, description
    fail_at=$1; desc=$2
    rm -f "$T/mvcount"
    FAKE_MV_FAIL_AT=$fail_at FAKE_MV_COUNT_FILE="$T/mvcount" HOME="$H5" \
        PATH="$T/bin:$BASE" sh "$INST" > "$T/out" 2>&1
    rc=$?
    leftovers=$(ls -A "$D5" 2>/dev/null | grep -c '^\.install-bridge' || true)
    if [ $rc != 0 ] \
       && cmp -s "$J5" "$T/orig5.json" \
       && [ "$(cat "$W5")" = "OLD-WRAPPER" ] && [ "$(mode_of "$W5")" = "-rwx------" ] \
       && [ "$(cat "$K5")" = "OLD-HOOK" ] && [ "$(mode_of "$K5")" = "-rwx--x--x" ] \
       && [ "${leftovers:-0}" = 0 ]; then
        ok "$desc: hooks.json byte-identical, prior scripts restored byte+mode, no leftovers"
    else
        bad "$desc" "rc=$rc wmode=$(mode_of "$W5") kmode=$(mode_of "$K5") leftovers=${leftovers:-?} jsoncmp=$(cmp -s "$J5" "$T/orig5.json" && echo same || echo DIFF)"
    fi
}
inj_fail 1 "fail mv#1 (wrapper commit)"
inj_fail 2 "fail mv#2 (hook script commit)"
inj_fail 3 "fail mv#3 (hooks.json commit)"

# =====================================================================
# 7. atomicity on fresh HOME: fail final commit -> nothing installed
# =====================================================================
H6="$T/h6"; mkdir -p "$H6"
rm -f "$T/mvcount"
FAKE_MV_FAIL_AT=3 FAKE_MV_COUNT_FILE="$T/mvcount" HOME="$H6" \
    PATH="$T/bin:$BASE" sh "$INST" > /dev/null 2>&1
rc=$?
if [ $rc != 0 ] && [ ! -e "$H6/.config/polytoken/hooks.json" ] \
   && [ ! -e "$H6/.config/polytoken/orca-bridge/pi-polytoken" ] \
   && [ ! -e "$H6/.config/polytoken/orca-bridge/orca-pi-hook.sh" ] \
   && [ ! -d "$H6/.config/polytoken/orca-bridge" ]; then
    ok "fresh HOME, fail final commit: nothing installed, dirs cleaned"
else
    bad "fresh fail-final" "rc=$rc exists: $([ -e "$H6/.config/polytoken/hooks.json" ] && echo json)$( [ -d "$H6/.config/polytoken/orca-bridge" ] && echo dir)"
fi

# =====================================================================
# 7b. shim (ln) failure AFTER all commits -> full rollback
# =====================================================================
rm -f "$T/lncount"
FAKE_LN_FAIL_AT=1 FAKE_LN_COUNT_FILE="$T/lncount" HOME="$H5" \
    PATH="$T/bin:$BASE" sh "$INST" --path-shim > "$T/out" 2>&1
rc=$?
if [ $rc != 0 ] && cmp -s "$J5" "$T/orig5.json" \
   && [ "$(cat "$W5")" = "OLD-WRAPPER" ] && [ "$(cat "$K5")" = "OLD-HOOK" ] \
   && [ ! -e "$H5/.local/bin/pi" ] && grep -q "rolling back" "$T/out"; then
    ok "shim failure after commits: hooks.json + prior scripts fully restored"
else
    bad "bridge shim failure rollback" "rc=$rc w=$(cat "$W5" 2>/dev/null | head -c 20) k=$(cat "$K5" 2>/dev/null | head -c 20)"
fi

# =====================================================================
# 8. uninstall: only exact managed names removed, scripts gone, shim ours
# =====================================================================
HOME="$H5" PATH="$BASE" sh "$INST" --path-shim > /dev/null 2>&1 || { echo "setup install failed"; exit 1; }
SHIM5="$H5/.local/bin/pi"
[ -L "$SHIM5" ] || { echo "setup shim missing"; exit 1; }
HOME="$H5" PATH="$BASE" sh "$UNINST" > "$T/out" 2>&1
rc=$?
if [ $rc = 0 ] \
   && [ "$(jq 'length' "$J5")" = 2 ] && [ "$(unrelated_count "$J5")" = 2 ] \
   && [ "$(jq -r '.[] | select(.name == "orca-custom-hook") | .name' "$J5")" = "orca-custom-hook" ] \
   && [ ! -e "$W5" ] && [ ! -e "$K5" ] && [ ! -e "$SHIM5" ] \
   && [ ! -d "$D5" ]; then
    ok "uninstall: only managed names removed, orca-custom-hook survives, scripts+shim ours gone"
else
    bad "uninstall scope" "rc=$rc len=$(jq 'length' "$J5" 2>/dev/null)"
fi

# =====================================================================
# 9. uninstall preserves retargeted shim
# =====================================================================
H7="$T/h7"; mkdir -p "$H7/.local/bin"
HOME="$H7" PATH="$BASE" sh "$INST" --path-shim > /dev/null 2>&1
ln -sfn /usr/bin/true "$H7/.local/bin/pi"
HOME="$H7" PATH="$BASE" sh "$UNINST" > "$T/out" 2>&1
if [ "$(readlink "$H7/.local/bin/pi" 2>/dev/null)" = "/usr/bin/true" ]; then
    ok "uninstall preserves shim retargeted elsewhere"
else
    bad "retargeted shim on uninstall"
fi

# =====================================================================
# 10. cross-installer lifecycle: wrapper+shim -> bridge -> uninstall-bridge
# =====================================================================
H8="$T/h8"; mkdir -p "$H8/.config/polytoken"
printf '[]\n' > "$H8/.config/polytoken/hooks.json"
cp "$H8/.config/polytoken/hooks.json" "$T/orig8.json"
HOME="$H8" PATH="$BASE" sh "$WRAP_INST" --path-shim > /dev/null 2>&1 || { echo "wrapper install failed"; exit 1; }
HOME="$H8" PATH="$BASE" sh "$INST" > /dev/null 2>&1 || { echo "bridge upgrade failed"; exit 1; }
SHIM8="$H8/.local/bin/pi"
if [ -L "$SHIM8" ] && [ "$(readlink "$SHIM8")" = "$H8/.config/polytoken/orca-bridge/pi-polytoken" ]; then
    : # bridge took ownership of the shim target
else
    bad "bridge ownership of shim" "shim=$(readlink "$SHIM8" 2>/dev/null)"
fi
HOME="$H8" PATH="$BASE" sh "$UNINST" > /dev/null 2>&1 || { echo "bridge uninstall failed"; exit 1; }
if [ ! -e "$SHIM8" ] && cmp -s "$H8/.config/polytoken/hooks.json" "$T/orig8.json" \
   && [ ! -e "$H8/.config/polytoken/orca-bridge/pi-polytoken" ]; then
    ok "lifecycle wrapper->bridge->uninstall-bridge: no dangling shim, config restored"
else
    bad "lifecycle transition" "shim=$([ -e "$SHIM8" ] && echo present || echo gone)"
fi

# =====================================================================
# 11. uninstaller through failure injection: no config mutation
# =====================================================================
H9="$T/h9"; mkdir -p "$H9"
HOME="$H9" PATH="$BASE" sh "$INST" > /dev/null 2>&1 || { echo "setup failed"; exit 1; }
J9="$H9/.config/polytoken/hooks.json"
cp "$J9" "$T/orig9.json"
rm -f "$T/mvcount"
FAKE_MV_FAIL_AT=1 FAKE_MV_COUNT_FILE="$T/mvcount" HOME="$H9" \
    PATH="$T/bin:$BASE" sh "$UNINST" > /dev/null 2>&1
rc=$?
if [ $rc != 0 ] && cmp -s "$J9" "$T/orig9.json" \
   && [ -e "$H9/.config/polytoken/orca-bridge/pi-polytoken" ] \
   && [ -e "$H9/.config/polytoken/orca-bridge/orca-pi-hook.sh" ]; then
    ok "uninstaller mv failure: config byte-identical, scripts untouched"
else
    bad "uninstaller injection" "rc=$rc"
fi

# --- 11b. uninstaller: fail the hooks.json commit after renames -> full restore ---
rm -f "$T/mvcount"
FAKE_MV_FAIL_AT=3 FAKE_MV_COUNT_FILE="$T/mvcount" HOME="$H9" \
    PATH="$T/bin:$BASE" sh "$UNINST" > "$T/out" 2>&1
rc=$?
leftovers9=$(ls -A "$H9/.config/polytoken" 2>/dev/null | grep -c '^\.uninstall-bridge' || true)
if [ $rc != 0 ] && cmp -s "$J9" "$T/orig9.json" \
   && cmp -s "$H9/.config/polytoken/orca-bridge/pi-polytoken" "$WRAP_SRC" \
   && cmp -s "$H9/.config/polytoken/orca-bridge/orca-pi-hook.sh" "$HOOK_SRC" \
   && [ "${leftovers9:-0}" = 0 ]; then
    ok "uninstaller hooks-commit failure: renamed scripts restored, config intact"
else
    bad "uninstaller hooks-commit rollback" "rc=$rc leftovers=${leftovers9:-?}"
fi

# --- 11c. uninstaller fails closed on malformed array elements --------------------
H11="$T/h11"; mkdir -p "$H11"
HOME="$H11" PATH="$BASE" sh "$INST" > /dev/null 2>&1 || { echo "setup failed"; exit 1; }
J11="$H11/.config/polytoken/hooks.json"
printf '["scalar-before", %s]\n' "$(cat "$J11" | jq -c '.[0]')" > "$T/malformed.json"
cp "$T/malformed.json" "$J11"
HOME="$H11" PATH="$BASE" sh "$UNINST" > "$T/out" 2>&1
rc=$?
if [ $rc != 0 ] && cmp -s "$J11" "$T/malformed.json" \
   && [ -e "$H11/.config/polytoken/orca-bridge/pi-polytoken" ] \
   && grep -q "malformed" "$T/out"; then
    ok "uninstaller refuses malformed array without mutation (fail closed)"
else
    bad "malformed refusal" "rc=$rc out=$(head -c 120 "$T/out")"
fi

# =====================================================================
# 12. uninstall with nothing installed
# =====================================================================
H10="$T/h10"; mkdir -p "$H10"
HOME="$H10" PATH="$BASE" sh "$UNINST" > "$T/out" 2>&1
rc=$?
if [ $rc = 0 ] && grep -q "nothing to uninstall" "$T/out"; then
    ok "uninstall with nothing installed exits 0"
else
    bad "uninstall nothing" "rc=$rc out=$(cat "$T/out")"
fi

echo "----"
echo "pass=$PASS fail=$FAIL"
[ "$FAIL" = 0 ]
