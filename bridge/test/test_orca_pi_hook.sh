#!/bin/sh
# test_orca_pi_hook.sh — bridge hook translation + transport tests (AC.3).
#
# Runs bridge/orca-pi-hook.sh against a local fake Orca listener (node),
# with a generated endpoint.env, and asserts for every mapped Polytoken
# event: method, path /hook/pi, token header, and the exact translated
# Pi-dialect payload — delivered via BOTH pinned transports: the classic
# form-urlencoded POST (six pane/env fields) and the endpoint-selected
# raw-json-v1 POST (application/json body + base64 X-Orca-Agent-Hook-Meta
# header). Also asserts loopback delivery survives a dead proxy
# (--noproxy 127.0.0.1) and the spool fallback on delivery failure.
# Negative cases assert silent exit 0 with no request.

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HOOK="$HERE/../orca-pi-hook.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL - $1${2:+: $2}"; }

T=$(mktemp -d "${TMPDIR:-/tmp}/ptoh.XXXXXX") || { echo "mktemp failed"; exit 1; }
NODE_BIN=$(command -v node) || { echo "node required for fake listener"; exit 1; }
cleanup() { [ -n "${SRV_PID:-}" ] && kill "$SRV_PID" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT HUP INT TERM

# --- fake listener ----------------------------------------------------------
cat > "$T/server.js" <<'EOF'
const http = require('http');
const fs = require('fs');
const out = process.argv[2];
const server = http.createServer((req, res) => {
  let b = '';
  req.on('data', c => { b += c; });
  req.on('end', () => {
    fs.appendFileSync(out, JSON.stringify({ method: req.method, url: req.url, headers: req.headers, body: b }) + "\n");
    res.writeHead(200); res.end('ok');
  });
});
server.listen(0, '127.0.0.1', () => {
  fs.writeFileSync(out + '.port', String(server.address().port));
});
EOF
REQS="$T/requests.jsonl"
"$NODE_BIN" "$T/server.js" "$REQS" &
SRV_PID=$!
for _ in $(seq 1 50); do [ -f "$REQS.port" ] && break; sleep 0.1; done
[ -f "$REQS.port" ] || { echo "listener failed to start"; exit 1; }
PORT=$(cat "$REQS.port")

H="$T/home"; mkdir -p "$H"

# --- endpoint.env ------------------------------------------------------------
TOKEN="test-token-zg7-51"
EP="$T/endpoint.env"
cat > "$EP" <<EOF
ORCA_AGENT_HOOK_PORT=$PORT
ORCA_AGENT_HOOK_TOKEN=$TOKEN
ORCA_AGENT_HOOK_ENV=test
ORCA_AGENT_HOOK_VERSION=9
EOF

req_count() { [ -f "$REQS" ] && wc -l < "$REQS" | tr -d ' ' || echo 0; }

# decode the last captured request into: method,url,token,ctype + fields map
last_request() {
    "$NODE_BIN" -e '
    const fs = require("fs");
    const lines = fs.readFileSync(process.argv[1], "utf8").trim().split("\n");
    const r = JSON.parse(lines[lines.length - 1]);
    const f = {};
    for (const part of r.body.split("&")) {
        const i = part.indexOf("=");
        // standard form decoding (as Orca listener performs):
        // plus-sign is space, percent-sequences decode
        f[decodeURIComponent(part.slice(0, i))] =
            decodeURIComponent(part.slice(i + 1).replace(/\+/g, " "));
    }
    console.log(JSON.stringify({ method: r.method, url: r.url,
        token: r.headers["x-orca-agent-hook-token"], ctype: r.headers["content-type"], fields: f }));
    ' "$REQS"
}

run_hook() { # fixture-file; EXTRA_ENV may carry additional K=V assignments
    env ${EXTRA_ENV:-} HOME="$H" PATH="$PATH" \
    ORCA_AGENT_HOOK_ENDPOINT="$EP" \
    ORCA_AGENT_HOOK_PORT="$PORT" ORCA_AGENT_HOOK_TOKEN="$TOKEN" \
    ORCA_PANE_KEY=pk-1 ORCA_TAB_ID=tb-2 ORCA_AGENT_LAUNCH_TOKEN=lt-3 \
    ORCA_WORKTREE_ID=wt-4 ORCA_AGENT_HOOK_ENV=test ORCA_AGENT_HOOK_VERSION=9 \
    sh "$HOOK" < "$1"
}

FIX="$T/fixture.json"
check_event() { # desc, fixture-json, expected-payload-json
    desc=$1; fixture=$2; expected=$3
    printf '%s' "$fixture" > "$FIX"
    before=$(req_count)
    run_hook "$FIX"
    rc=$?
    after=$(req_count)
    if [ $rc != 0 ]; then bad "$desc" "hook exited $rc"; return; fi
    if [ "$after" != $((before + 1)) ]; then bad "$desc" "expected 1 new request, got $((after - before))"; return; fi
    got=$(last_request)
    payload=$(printf '%s' "$got" | jq -r '.fields.payload')
    trans_ok=1
    [ "$(printf '%s' "$got" | jq -r '.method')" = "POST" ] || trans_ok=0
    [ "$(printf '%s' "$got" | jq -r '.url')" = "/hook/pi" ] || trans_ok=0
    [ "$(printf '%s' "$got" | jq -r '.token')" = "$TOKEN" ] || trans_ok=0
    [ "$(printf '%s' "$got" | jq -r '.ctype')" = "application/x-www-form-urlencoded" ] || trans_ok=0
    for kv in "paneKey=pk-1" "tabId=tb-2" "launchToken=lt-3" "worktreeId=wt-4" "env=test" "version=9"; do
        k=${kv%%=*}; v=${kv#*=}
        [ "$(printf '%s' "$got" | jq -r ".fields.$k")" = "$v" ] || trans_ok=0
    done
    if [ "$trans_ok" = 1 ] && [ "$payload" = "$expected" ]; then
        ok "$desc"
    else
        bad "$desc" "payload=$(printf '%s' "$payload" | head -c 300) expected=$expected trans_ok=$trans_ok"
    fi
}

# --- mapped events: exact payload translation --------------------------------
# Polytoken 0.8.x session storage: sessions-v1/ (current) vs sessions/ (legacy)
SFV="$H/.local/share/polytoken/sessions-v1"
SFL="$H/.local/share/polytoken/sessions"
mkdir -p "$SFV/s-111" "$SFL/s-222"
: > "$SFV/s-111/log.jsonl"
: > "$SFL/s-222/log.jsonl"

check_event "session_start prefers existing sessions-v1 path" \
    '{"event":"session_start","matcher_subject":"session_start","session_id":"s-111"}' \
    "{\"hook_event_name\":\"session_start\",\"session_id\":\"s-111\",\"session_file\":\"$SFV/s-111/log.jsonl\"}"

EXTRA_ENV="POLYTOKEN_SESSION_ID=s-222"
check_event "session_start falls back to legacy sessions path" \
    '{"event":"session_start","matcher_subject":"session_start"}' \
    "{\"hook_event_name\":\"session_start\",\"session_id\":\"s-222\",\"session_file\":\"$SFL/s-222/log.jsonl\"}"
EXTRA_ENV=""

check_event "session_start with no stored dir defaults to sessions-v1" \
    '{"event":"session_start","matcher_subject":"session_start","session_id":"s-333"}' \
    "{\"hook_event_name\":\"session_start\",\"session_id\":\"s-333\",\"session_file\":\"$SFV/s-333/log.jsonl\"}"

check_event "pre_user_prompt -> before_agent_start with prompt" \
    '{"event":"pre_user_prompt","matcher_subject":"pre_user_prompt","prompt_id":"p1","prompt":"Fix the flaky test"}' \
    '{"hook_event_name":"before_agent_start","prompt":"Fix the flaky test"}'

check_event "pre_user_prompt missing prompt -> empty string" \
    '{"event":"pre_user_prompt","matcher_subject":"pre_user_prompt","prompt_id":"p2"}' \
    '{"hook_event_name":"before_agent_start","prompt":""}'

check_event "pre_tool_use ask_user_question passes through (-> blocked)" \
    '{"event":"pre_tool_use","matcher_subject":"ask_user_question","tool_name":"ask_user_question","call_id":"c1","input":{"questions":[{"id":"q1","question":"Deploy now?","mode":"single_select"}]}}' \
    '{"hook_event_name":"tool_call","tool_name":"ask_user_question","tool_input":{"questions":[{"id":"q1","question":"Deploy now?","mode":"single_select"}]}}'

check_event "pre_tool_use shell_exec -> working with tool info" \
    '{"event":"pre_tool_use","matcher_subject":"shell_exec","tool_name":"shell_exec","call_id":"c2","input":{"command":"echo hi","timeout_seconds":30}}' \
    '{"hook_event_name":"tool_call","tool_name":"shell_exec","tool_input":{"command":"echo hi","timeout_seconds":30}}'

check_event "notification with summary -> blocked with message" \
    '{"event":"notification","notification_type":"job_complete","source":"shell_exec","summary":"job x finished"}' \
    '{"hook_event_name":"tool_call","tool_name":"ask_user_question","tool_input":{"questions":[{"question":"job x finished"}]}}'

EXTRA_ENV="POLYTOKEN_HOOK_EVENT=notification"
check_event "notification without summary -> fallback message (env event name)" \
    '{}' \
    '{"hook_event_name":"tool_call","tool_name":"ask_user_question","tool_input":{"questions":[{"question":"Polytoken needs attention"}]}}'
EXTRA_ENV=""

check_event "post_tool_use -> tool_execution_end" \
    '{"event":"post_tool_use","matcher_subject":"shell_exec","tool_name":"shell_exec","call_id":"c3","input":{"command":"echo hi"}}' \
    '{"hook_event_name":"tool_execution_end"}'

check_event "post_tool_use_failure -> tool_execution_end" \
    '{"event":"post_tool_use_failure","matcher_subject":"shell_exec","tool_name":"shell_exec","call_id":"c4","failure":{"kind":"execution","error_message":"exit_code=7"}}' \
    '{"hook_event_name":"tool_execution_end"}'

check_event "stop -> agent_end" \
    '{"event":"stop","matcher_subject":"stop","prompt_id":"p3"}' \
    '{"hook_event_name":"agent_end"}'

# --- unmapped / negative cases --------------------------------------------------
printf '%s' '{"event":"pre_model_turn","matcher_subject":"pre_model_turn","prompt_id":"p9"}' > "$FIX"
before=$(req_count)
run_hook "$FIX"; rc=$?
if [ $rc = 0 ] && [ "$(req_count)" = "$before" ]; then
    ok "unmapped event (pre_model_turn) -> no request, exit 0"
else
    bad "unmapped event" "rc=$rc"
fi

: > "$FIX"
before=$(req_count)
run_hook "$FIX"; rc=$?
if [ $rc = 0 ] && [ "$(req_count)" = "$before" ]; then
    ok "empty stdin -> exit 0, no request"
else
    bad "empty stdin" "rc=$rc"
fi

printf '%s' '{"event":"stop"' > "$FIX"   # invalid JSON
before=$(req_count)
run_hook "$FIX"; rc=$?
if [ $rc = 0 ] && [ "$(req_count)" = "$before" ]; then
    ok "invalid JSON stdin -> exit 0, no request"
else
    bad "invalid JSON" "rc=$rc"
fi

before=$(req_count)
HOME="$H" ORCA_AGENT_HOOK_ENDPOINT="$EP" sh "$HOOK" < "$FIX"   # no pane key et al
rc=$?
if [ $rc = 0 ] && [ "$(req_count)" = "$before" ]; then
    ok "missing ORCA_PANE_KEY -> exit 0, no request"
else
    bad "missing pane key" "rc=$rc"
fi

before=$(req_count)
HOME="$H" sh "$HOOK" < "$FIX"   # no endpoint file, no port/token in env
rc=$?
if [ $rc = 0 ] && [ "$(req_count)" = "$before" ]; then
    ok "no endpoint file -> exit 0, no request"
else
    bad "no endpoint" "rc=$rc"
fi

# oversized payload (>256 KiB cap) -> silent exit 0, no request
before=$(req_count)
awk 'BEGIN { s = "{\"event\":\"pre_tool_use\",\"tool_name\":\"t\",\"input\":{\"blob\":\""; for (i = 0; i < 300000; i++) s = s "x"; s = s "\"}}" ; printf "%s", s }' > "$FIX"
sz=$(wc -c < "$FIX" | tr -d ' ')
[ "$sz" -gt 262144 ] || { echo "fixture generation failed ($sz bytes)"; exit 1; }
run_hook "$FIX"; rc=$?
if [ $rc = 0 ] && [ "$(req_count)" = "$before" ]; then
    ok "oversized payload ($sz bytes) -> exit 0, no request"
else
    bad "oversized payload" "rc=$rc"
fi

# xtrace must never leak the token into stderr
printf '%s' '{"event":"stop"}' > "$FIX"
before=$(req_count)
env HOME="$H" PATH="$PATH" ORCA_AGENT_HOOK_ENDPOINT="$EP" \
    ORCA_PANE_KEY=pk-1 ORCA_TAB_ID=tb-2 ORCA_AGENT_LAUNCH_TOKEN=lt-3 \
    ORCA_WORKTREE_ID=wt-4 sh -x "$HOOK" < "$FIX" > "$T/xtrace.out" 2> "$T/xtrace.err"
rc=$?
if ! grep -q "$TOKEN" "$T/xtrace.err" && ! grep -q "$TOKEN" "$T/xtrace.out"; then
    ok "sh -x invocation never leaks the token"
else
    bad "xtrace token leak" "token visible in output"
fi

# --- transport selection (re-verified vs Orca 1.4.205 claude-hook.sh) ---------

# raw record reader: last captured request verbatim
last_raw() {
    "$NODE_BIN" -e '
    const fs = require("fs");
    const lines = fs.readFileSync(process.argv[1], "utf8").trim().split("\n");
    console.log(lines[lines.length - 1]);
    ' "$REQS"
}

EP_RAW="$T/endpoint-raw.env"
cat > "$EP_RAW" <<EOF
ORCA_AGENT_HOOK_PORT=$PORT
ORCA_AGENT_HOOK_TOKEN=$TOKEN
ORCA_AGENT_HOOK_ENV=test
ORCA_AGENT_HOOK_VERSION=9
ORCA_AGENT_HOOK_TRANSPORT=raw-json-v1
EOF

EXPECT_META=$(printf '%s\037%s\037%s\037%s\037%s\037%s' "pk-1" "tb-2" "lt-3" "wt-4" "test" "9" | base64 | tr -d '\n')

before=$(req_count)
printf '%s' '{"event":"stop","matcher_subject":"stop","prompt_id":"p3"}' > "$FIX"
env HOME="$H" PATH="$PATH" \
    ORCA_AGENT_HOOK_ENDPOINT="$EP_RAW" \
    ORCA_AGENT_HOOK_PORT="$PORT" ORCA_AGENT_HOOK_TOKEN="$TOKEN" \
    ORCA_PANE_KEY=pk-1 ORCA_TAB_ID=tb-2 ORCA_AGENT_LAUNCH_TOKEN=lt-3 \
    ORCA_WORKTREE_ID=wt-4 ORCA_AGENT_HOOK_ENV=test ORCA_AGENT_HOOK_VERSION=9 \
    sh "$HOOK" < "$FIX"; rc=$?
after=$(req_count)
raw=$(last_raw)
if [ $rc != 0 ] || [ "$after" != $((before + 1)) ]; then
    bad "raw-json-v1 endpoint transport sends one request" "rc=$rc delta=$((after - before))"
else
    trans_ok=1
    [ "$(printf '%s' "$raw" | jq -r '.method')" = "POST" ] || trans_ok=0
    [ "$(printf '%s' "$raw" | jq -r '.url')" = "/hook/pi" ] || trans_ok=0
    [ "$(printf '%s' "$raw" | jq -r '.headers["x-orca-agent-hook-token"]')" = "$TOKEN" ] || trans_ok=0
    [ "$(printf '%s' "$raw" | jq -r '.headers["content-type"]')" = "application/json" ] || trans_ok=0
    [ "$(printf '%s' "$raw" | jq -r '.headers["x-orca-agent-hook-meta-encoding"]')" = "base64" ] || trans_ok=0
    [ "$(printf '%s' "$raw" | jq -r '.headers["x-orca-agent-hook-meta"]')" = "$EXPECT_META" ] || trans_ok=0
    [ "$(printf '%s' "$raw" | jq -r '.body')" = '{"hook_event_name":"agent_end"}' ] || trans_ok=0
    if [ "$trans_ok" = 1 ]; then
        ok "raw-json-v1 endpoint transport: JSON body + base64 meta header"
    else
        bad "raw-json-v1 endpoint transport: JSON body + base64 meta header" "raw=$raw"
    fi
fi

# ambient transport var must NOT select raw-json when the endpoint file
# does not set it (hook unsets before sourcing — endpoint value wins)
before=$(req_count)
EXTRA_ENV="ORCA_AGENT_HOOK_TRANSPORT=raw-json-v1"
run_hook "$FIX"; rc=$?
after=$(req_count)
got=$(last_request)
if [ $rc = 0 ] && [ "$after" = $((before + 1)) ] && \
   [ "$(printf '%s' "$got" | jq -r '.ctype')" = "application/x-www-form-urlencoded" ]; then
    ok "ambient ORCA_AGENT_HOOK_TRANSPORT ignored (endpoint file wins) -> form fallback"
else
    bad "ambient transport ignored" "ctype=$(printf '%s' "$got" | jq -r '.ctype')"
fi
EXTRA_ENV=""

# unknown transport value -> form fallback
EP_BAD="$T/endpoint-bad.env"
cat > "$EP_BAD" <<EOF
ORCA_AGENT_HOOK_PORT=$PORT
ORCA_AGENT_HOOK_TOKEN=$TOKEN
ORCA_AGENT_HOOK_ENV=test
ORCA_AGENT_HOOK_VERSION=9
ORCA_AGENT_HOOK_TRANSPORT=morse-code
EOF
before=$(req_count)
env HOME="$H" PATH="$PATH" \
    ORCA_AGENT_HOOK_ENDPOINT="$EP_BAD" \
    ORCA_AGENT_HOOK_PORT="$PORT" ORCA_AGENT_HOOK_TOKEN="$TOKEN" \
    ORCA_PANE_KEY=pk-1 ORCA_TAB_ID=tb-2 ORCA_AGENT_LAUNCH_TOKEN=lt-3 \
    ORCA_WORKTREE_ID=wt-4 ORCA_AGENT_HOOK_ENV=test ORCA_AGENT_HOOK_VERSION=9 \
    sh "$HOOK" < "$FIX"; rc=$?
after=$(req_count)
got=$(last_request)
if [ $rc = 0 ] && [ "$after" = $((before + 1)) ] && \
   [ "$(printf '%s' "$got" | jq -r '.ctype')" = "application/x-www-form-urlencoded" ]; then
    ok "unknown transport value -> form fallback"
else
    bad "unknown transport value" "ctype=$(printf '%s' "$got" | jq -r '.ctype')"
fi

# loopback delivery must survive proxy env (--noproxy 127.0.0.1)
before=$(req_count)
env HOME="$H" PATH="$PATH" \
    http_proxy=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9 \
    ALL_PROXY=http://127.0.0.1:9 all_proxy=http://127.0.0.1:9 \
    ORCA_AGENT_HOOK_ENDPOINT="$EP" \
    ORCA_AGENT_HOOK_PORT="$PORT" ORCA_AGENT_HOOK_TOKEN="$TOKEN" \
    ORCA_PANE_KEY=pk-1 ORCA_TAB_ID=tb-2 ORCA_AGENT_LAUNCH_TOKEN=lt-3 \
    ORCA_WORKTREE_ID=wt-4 ORCA_AGENT_HOOK_ENV=test ORCA_AGENT_HOOK_VERSION=9 \
    sh "$HOOK" < "$FIX"; rc=$?
after=$(req_count)
if [ $rc = 0 ] && [ "$after" = $((before + 1)) ]; then
    ok "dead proxy env does not break loopback delivery (--noproxy)"
else
    bad "dead proxy env" "rc=$rc delta=$((after - before))"
fi

# --- listener down: fail-open + spool fallback ---------------------------------
kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null; SRV_PID=""
DEAD_EP="$T/endpoint-dead.env"
cat > "$DEAD_EP" <<EOF
ORCA_AGENT_HOOK_PORT=$PORT
ORCA_AGENT_HOOK_TOKEN=$TOKEN
ORCA_AGENT_HOOK_ENV=test
ORCA_AGENT_HOOK_VERSION=9
EOF
SPOOL_FILE="$T/spool/pane-pk-1.jsonl"
before=$(req_count)
printf '%s' '{"event":"stop"}' > "$FIX"
HOME="$H" ORCA_AGENT_HOOK_ENDPOINT="$DEAD_EP" \
    ORCA_PANE_KEY=pk-1 ORCA_TAB_ID=tb-2 ORCA_AGENT_LAUNCH_TOKEN=lt-3 \
    ORCA_WORKTREE_ID=wt-4 sh "$HOOK" < "$FIX"
rc=$?
spool_ok=1
[ $rc = 0 ] || spool_ok=0
[ -f "$SPOOL_FILE" ] || spool_ok=0
if [ "$spool_ok" = 1 ]; then
    line=$(tail -n 1 "$SPOOL_FILE")
    [ "$(printf '%s' "$line" | jq -r '.source')" = "pi" ] || spool_ok=0
    [ "$(printf '%s' "$line" | jq -r '.paneKey')" = "pk-1" ] || spool_ok=0
    [ "$(printf '%s' "$line" | jq -r '.payload.hook_event_name')" = "agent_end" ] || spool_ok=0
    fmode=$(stat -f '%Lp' "$SPOOL_FILE" 2>/dev/null || stat -c '%a' "$SPOOL_FILE" 2>/dev/null)
    case "$fmode" in 600|rw-------) ;; *) spool_ok=0 ;; esac
fi
if [ "$spool_ok" = 1 ]; then
    ok "listener down -> exit 0 + event spooled (source=pi, mode 0600)"
else
    bad "listener down spool" "rc=$rc file=$SPOOL_FILE"
fi

# tool events are never spooled (high-volume polarity, claude-hook parity)
printf '%s' '{"event":"pre_tool_use","matcher_subject":"shell_exec","tool_name":"shell_exec","call_id":"c9","input":{"command":"echo hi"}}' > "$FIX"
HOME="$H" ORCA_AGENT_HOOK_ENDPOINT="$DEAD_EP" \
    ORCA_PANE_KEY=pk-1 ORCA_TAB_ID=tb-2 ORCA_AGENT_LAUNCH_TOKEN=lt-3 \
    ORCA_WORKTREE_ID=wt-4 sh "$HOOK" < "$FIX"
rc=$?
# NOTE: each spool record is written as "\n{json}\n" (leading newline guards
# against a prior file not ending in one), so wc -l counts 2 per record.
lines=$(wc -l < "$SPOOL_FILE" | tr -d ' ')
if [ $rc = 0 ] && [ "$lines" = 2 ]; then
    ok "tool event not spooled (file unchanged)"
else
    bad "tool event spool skip" "rc=$rc lines=$lines"
fi

# gating failure with endpoint+pane present (e.g. missing PORT) -> spool
EP_GATED="$T/endpoint-gated.env"
cat > "$EP_GATED" <<EOF
ORCA_AGENT_HOOK_TOKEN=$TOKEN
ORCA_AGENT_HOOK_ENV=test
ORCA_AGENT_HOOK_VERSION=9
EOF
printf '%s' '{"event":"stop"}' > "$FIX"
HOME="$H" ORCA_AGENT_HOOK_ENDPOINT="$EP_GATED" \
    ORCA_PANE_KEY=pk-1 ORCA_TAB_ID=tb-2 ORCA_AGENT_LAUNCH_TOKEN=lt-3 \
    ORCA_WORKTREE_ID=wt-4 sh "$HOOK" < "$FIX"
rc=$?
lines=$(wc -l < "$SPOOL_FILE" | tr -d ' ')
if [ $rc = 0 ] && [ "$lines" = 4 ]; then
    ok "gating failure (no PORT) -> spooled, exit 0"
else
    bad "gating failure spool" "rc=$rc lines=$lines"
fi

# spool file/dir must be private (0600 file, 0700 dir)
fmode=$(stat -f '%Lp' "$SPOOL_FILE" 2>/dev/null || stat -c '%a' "$SPOOL_FILE" 2>/dev/null)
dirmode=$(ls -ld "$T/spool" | cut -d' ' -f1)
spool_perm_ok=1
case "$fmode" in 600|rw-------) ;; *) spool_perm_ok=0 ;; esac
case "$dirmode" in drwx------|drwx------@) ;; *) spool_perm_ok=0 ;; esac
if [ "$spool_perm_ok" = 1 ]; then
    ok "spool file 0600, spool dir 0700"
else
    bad "spool permissions" "file=$fmode dir=$dirmode"
fi

echo "----"
echo "pass=$PASS fail=$FAIL"
[ "$FAIL" = 0 ]
