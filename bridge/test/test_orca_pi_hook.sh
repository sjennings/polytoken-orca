#!/bin/sh
# test_orca_pi_hook.sh — bridge hook translation + transport tests (AC.3).
#
# Runs bridge/orca-pi-hook.sh against a local fake Orca listener (node),
# with a generated endpoint.env, and asserts for every mapped Polytoken
# event: method, path /hook/pi, token header, all six pane/env form fields,
# and the exact translated Pi-dialect payload. Negative cases assert
# silent exit 0 with no request.

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
SFH="$H/.local/share/polytoken/sessions"

check_event "session_start -> identity registration" \
    '{"event":"session_start","matcher_subject":"session_start","session_id":"s-111"}' \
    "{\"hook_event_name\":\"session_start\",\"session_id\":\"s-111\",\"session_file\":\"$SFH/s-111/log.jsonl\"}"

EXTRA_ENV="POLYTOKEN_SESSION_ID=s-222"
check_event "session_start without .session_id uses env" \
    '{"event":"session_start","matcher_subject":"session_start"}' \
    "{\"hook_event_name\":\"session_start\",\"session_id\":\"s-222\",\"session_file\":\"$SFH/s-222/log.jsonl\"}"
EXTRA_ENV=""

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

# listener down: point at a port nothing listens on
kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null; SRV_PID=""
DEAD_EP="$T/endpoint-dead.env"
cat > "$DEAD_EP" <<EOF
ORCA_AGENT_HOOK_PORT=$PORT
ORCA_AGENT_HOOK_TOKEN=$TOKEN
ORCA_AGENT_HOOK_ENV=test
ORCA_AGENT_HOOK_VERSION=9
EOF
before=$(req_count)
printf '%s' '{"event":"stop"}' > "$FIX"
HOME="$H" ORCA_AGENT_HOOK_ENDPOINT="$DEAD_EP" \
    ORCA_PANE_KEY=pk-1 ORCA_TAB_ID=tb-2 ORCA_AGENT_LAUNCH_TOKEN=lt-3 \
    ORCA_WORKTREE_ID=wt-4 sh "$HOOK" < "$FIX"
rc=$?
if [ $rc = 0 ]; then
    ok "listener down -> still exit 0"
else
    bad "listener down" "rc=$rc"
fi

echo "----"
echo "pass=$PASS fail=$FAIL"
[ "$FAIL" = 0 ]
