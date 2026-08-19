#!/bin/sh
# orca-pi-hook.sh — Polytoken hook handler bridging to Orca's agent-hook
# listener in the Pi dialect (v1 bridge).
#
# Invoked by Polytoken for each subscribed event with the event JSON on
# stdin and POLYTOKEN_SESSION_ID / POLYTOKEN_HOOK_EVENT in the env.
# Translates the payload to the Pi hook dialect and POSTs it to Orca at
# /hook/pi using the exact transport of Orca's own claude-hook.sh:
#   - source $ORCA_AGENT_HOOK_ENDPOINT only when set and readable
#   - silent exit 0 unless PORT + TOKEN + ORCA_PANE_KEY are all present
#   - curl --connect-timeout 0.5 --max-time 1.5, output discarded
#   - always exits 0 (never fails the hook, never blocks the agent)
#
# Payload mapping (see docs/orca-pi-contract.md §2/§4.1):
#   session_start         -> session_start {session_id, session_file}
#   pre_user_prompt       -> before_agent_start {prompt}
#   pre_tool_use          -> tool_call {tool_name, tool_input}  (ask_user_question => blocked)
#   notification          -> tool_call ask_user_question {questions:[{question}]} (=> blocked)
#   post_tool_use         -> tool_execution_end
#   post_tool_use_failure -> tool_execution_end
#   stop                  -> agent_end (=> done)
#   anything else         -> no request
#
# Security: ORCA_AGENT_HOOK_TOKEN is only ever passed to curl (as Orca's
# own claude-hook.sh does — pinned transport); it is never logged, echoed,
# or written anywhere.
#
# NOTE: stdin is capped at 256 KiB (head -c) — oversized tool inputs parse
# as invalid JSON and degrade to a silent exit 0 rather than burning the
# hook deadline.

payload=$(head -c 262144)
if [ -z "$payload" ]; then
  exit 0
fi

# Disable xtrace BEFORE sourcing so neither the endpoint's own assignment
# lines nor any later expansion of the token can be traced by a debugging
# shell (`sh -x`). The endpoint file is owned and written by Orca (same
# trust model as Orca's own claude-hook.sh, which sources it identically —
# pinned contract, docs/orca-pi-contract.md §1).
{ set +x; } 2>/dev/null || :
if [ -n "$ORCA_AGENT_HOOK_ENDPOINT" ] && [ -r "$ORCA_AGENT_HOOK_ENDPOINT" ]; then
  . "$ORCA_AGENT_HOOK_ENDPOINT" 2>/dev/null || :
fi
if [ -z "$ORCA_AGENT_HOOK_PORT" ] || [ -z "$ORCA_AGENT_HOOK_TOKEN" ] || [ -z "$ORCA_PANE_KEY" ]; then
  exit 0
fi
command -v jq >/dev/null 2>&1 || exit 0

pi_payload=$(printf '%s' "$payload" | jq -c \
  --arg evt "${POLYTOKEN_HOOK_EVENT:-}" \
  --arg sid "${POLYTOKEN_SESSION_ID:-}" \
  --arg home "$HOME" '
  (.event // $evt) as $e |
  if $e == "session_start" then
    (.session_id // $sid) as $id |
    {
      hook_event_name: "session_start",
      session_id: $id,
      session_file: ($home + "/.local/share/polytoken/sessions/" + $id + "/log.jsonl")
    }
  elif $e == "pre_user_prompt" then
    { hook_event_name: "before_agent_start", prompt: (.prompt // "") }
  elif $e == "pre_tool_use" then
    { hook_event_name: "tool_call", tool_name: (.tool_name // ""), tool_input: (.input // {}) }
  elif $e == "notification" then
    {
      hook_event_name: "tool_call",
      tool_name: "ask_user_question",
      tool_input: { questions: [ { question: (.summary // "Polytoken needs attention") } ] }
    }
  elif $e == "post_tool_use" or $e == "post_tool_use_failure" then
    { hook_event_name: "tool_execution_end" }
  elif $e == "stop" then
    { hook_event_name: "agent_end" }
  else
    empty
  end
' 2>/dev/null) || exit 0
if [ -z "$pi_payload" ]; then
  exit 0
fi

printf '%s' "$pi_payload" | curl -sS -X POST "http://127.0.0.1:${ORCA_AGENT_HOOK_PORT}/hook/pi" \
  --connect-timeout 0.5 --max-time 1.5 \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "X-Orca-Agent-Hook-Token: ${ORCA_AGENT_HOOK_TOKEN}" \
  --data-urlencode "paneKey=${ORCA_PANE_KEY}" \
  --data-urlencode "tabId=${ORCA_TAB_ID}" \
  --data-urlencode "launchToken=${ORCA_AGENT_LAUNCH_TOKEN}" \
  --data-urlencode "worktreeId=${ORCA_WORKTREE_ID}" \
  --data-urlencode "env=${ORCA_AGENT_HOOK_ENV}" \
  --data-urlencode "version=${ORCA_AGENT_HOOK_VERSION}" \
  --data-urlencode "payload@-" >/dev/null 2>&1 || true
exit 0
