#!/bin/sh
# test_pi_wrapper.sh — argv-translation tests for bin/pi-polytoken (AC.1).
#
# Uses a stub `polytoken` on PATH that records its argv; the real binary is
# never invoked. Runs the wrapper under a temporary HOME.
# (No `set -u`: run_wrapper must forward a possibly-empty "$@" — fatal
# under `set -u` on macOS bash 3.2.)

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
WRAPPER="$HERE/../../bin/pi-polytoken"

PASS=0
FAIL=0

T=$(mktemp -d "${TMPDIR:-/tmp}/ptw.XXXXXX") || { echo "mktemp failed"; exit 1; }
trap 'rm -rf "$T"' EXIT HUP INT TERM

mkdir -p "$T/stub" "$T/home"
cat > "$T/stub/polytoken" <<EOF
#!/bin/sh
printf '%s\n' "\$#" >> "$T/argv.txt"
for a in "\$@"; do printf '%s\n' "\$a" >> "$T/argv.txt"; done
EOF
chmod 0755 "$T/stub/polytoken"

run_wrapper() {
    rm -f "$T/argv.txt"
    HOME="$T/home" PATH="$T/stub:/bin:/usr/bin" "$WRAPPER" "$@" >/dev/null 2>&1
}

# recorded argv as "argc|joined-args" — argc proves argument boundaries
recorded() {
    [ -f "$T/argv.txt" ] || { echo "(no recording)"; return; }
    argc=$(sed -n '1p' "$T/argv.txt")
    joined=$(awk 'NR>1' "$T/argv.txt" | tr '\n' ' ' | sed 's/ $//')
    printf '%s|%s' "$argc" "$joined"
}

assert_args() {
    desc=$1
    expected=$2
    expected_argc=$(printf '%s\n' "$expected" | wc -w | tr -d ' ')
    shift 2
    run_wrapper "$@"
    got=$(recorded)
    if [ "$got" = "$expected_argc|$expected" ]; then
        PASS=$((PASS + 1)); echo "ok   - $desc"
    else
        FAIL=$((FAIL + 1)); echo "FAIL - $desc: expected [$expected_argc|$expected] got [$got]"
    fi
}

# assert exact argument boundaries (argc + per-arg lines) for tricky values
assert_exact() {
    desc=$1
    expected_argc=$2
    expected=$3
    shift 3
    run_wrapper "$@"
    got=$(recorded)
    if [ "$got" = "$expected_argc|$expected" ]; then
        PASS=$((PASS + 1)); echo "ok   - $desc"
    else
        FAIL=$((FAIL + 1)); echo "FAIL - $desc: expected [$expected_argc|$expected] got [$got]"
    fi
}

# --- AC.1 cases -------------------------------------------------------------
assert_args "no args -> new"                          "new"
assert_args "resume via --session log.jsonl"          "continue abc-123" \
    --session "/Users/x/.local/share/polytoken/sessions/abc-123/log.jsonl"
assert_args "resume via --session dir"                "continue abc-123" \
    --session "/Users/x/.local/share/polytoken/sessions/abc-123"
assert_args "unknown flags swallowed -> new"          "new" --yolo --whatever
assert_args "resume via --session=path"               "continue xyz" \
    "--session=/Users/x/.local/share/polytoken/sessions/xyz/log.jsonl"
assert_exact "session path with spaces (boundary-proof)" "2" "continue my id" \
    --session "/Users/x/.local/share/polytoken/sessions/my id/log.jsonl"
assert_args "dangling --session -> new"               "new" --session
assert_args "--session / (empty basename) -> new"     "new" --session "/"
assert_args "--session bare token -> new"             "new" --session foo
assert_args "--session empty string -> new"           "new" --session ""
assert_args "flags around --session"                  "continue abc" \
    --yolo --session "/p/s/sessions/abc/log.jsonl" --verbose
assert_args "double --session: last wins"             "continue two" \
    --session "/p/sessions/one/log.jsonl" --session "/p/sessions/two/log.jsonl"
assert_args "positional prompt swallowed"             "new" "do the thing" --yolo

# --- argv logging (used to record real Orca invocations during smokes) -----
rm -f "$T/argv.txt"
mkdir -p "$T/home/.config/polytoken/orca-bridge"
HOME="$T/home" PATH="$T/stub:/bin:/usr/bin" "$WRAPPER" --yolo --session "/p/sessions/rec1/log.jsonl" >/dev/null 2>&1
LOG="$T/home/.config/polytoken/orca-bridge/pi-polytoken.argv.log"
if [ -f "$LOG" ] && grep -q -- "--session" "$LOG" && grep -q "rec1" "$LOG"; then
    PASS=$((PASS + 1)); echo "ok   - argv log records invocation"
else
    FAIL=$((FAIL + 1)); echo "FAIL - argv log missing or incomplete: $(cat "$LOG" 2>/dev/null)"
fi

# argv log must not be created when the orca-bridge dir does not exist
rm -rf "$T/home2"; mkdir -p "$T/home2"
HOME="$T/home2" PATH="$T/stub:/bin:/usr/bin" "$WRAPPER" >/dev/null 2>&1
if [ -e "$T/home2/.config" ]; then
    FAIL=$((FAIL + 1)); echo "FAIL - wrapper created .config without orca-bridge dir"
else
    PASS=$((PASS + 1)); echo "ok   - no stray dirs when orca-bridge absent"
fi

# argv log: created owner-only (0600), control chars sanitized
rm -rf "$T/home3"; mkdir -p "$T/home3/.config/polytoken/orca-bridge"
HOME="$T/home3" PATH="$T/stub:/bin:/usr/bin" "$WRAPPER" "$(printf 'a<tab>b\nc')" >/dev/null 2>&1
LOG3="$T/home3/.config/polytoken/orca-bridge/pi-polytoken.argv.log"
mode3=$(ls -l "$LOG3" 2>/dev/null | cut -c 1-10)
lines3=$(grep -c '' "$LOG3" 2>/dev/null || echo 0)
if [ "$mode3" = "-rw-------" ] && [ "$lines3" = 1 ]; then
    PASS=$((PASS + 1)); echo "ok   - argv log is 0600 and control chars sanitized (single line)"
else
    FAIL=$((FAIL + 1)); echo "FAIL - argv log hygiene: mode=$mode3 lines=$lines3"
fi

echo "----"
echo "pass=$PASS fail=$FAIL"
[ "$FAIL" = 0 ]
