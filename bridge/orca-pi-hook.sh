#!/bin/sh
# orca-pi-hook.sh — Polytoken hook handler bridging to Orca's agent-hook
# listener in the Pi dialect (v1 bridge).
#
# Invoked by Polytoken for each subscribed event with the event JSON on
# stdin and POLYTOKEN_SESSION_ID / POLYTOKEN_HOOK_EVENT in the env.
# Translates the payload to the Pi hook dialect and POSTs it to Orca at
# /hook/pi using the transport of Orca's own claude-hook.sh (re-verified
# against production Orca 1.4.205, 2026-09-17 — docs/orca-pi-contract.md
# §1):
#   - source $ORCA_AGENT_HOOK_ENDPOINT only when set and readable; the
#     endpoint file's ORCA_AGENT_HOOK_TRANSPORT wins over the ambient
#     environment (unset before sourcing, as Orca's own hook does)
#   - transport selected by ORCA_AGENT_HOOK_TRANSPORT (from the endpoint
#     file): "raw-json-v1" POSTs the payload as application/json with the
#     six pane/env values base64-packed (US separator) into
#     X-Orca-Agent-Hook-Meta; any other value (or missing base64/tr)
#     falls back to the classic application/x-www-form-urlencoded POST
#     with the same six fields
#   - curl --connect-timeout 0.5 --max-time 1.5 (hardcoded — never
#     allow an override that could block the agent), --noproxy 127.0.0.1
#   - on curl failure OR missing PORT/TOKEN/ORCA_PANE_KEY gating, the
#     event is appended to Orca's spool dir (JSONL, 5 MiB/pane cap, 7-day
#     reset, mode 0600 in a 0700 dir) for the listener to drain — same
#     mechanism as Orca's own hooks; tool events are never spooled
#     (high-volume), matching claude-hook.sh's polarity
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
# or written anywhere. Spooled payloads contain prompt/tool-input text and
# are written 0600 into Orca's 0700 spool dir — the same trust model as
# Orca's own hooks on this machine.
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
# pinned contract, docs/orca-pi-contract.md §1). The transport variable is
# unset first so only the endpoint file's value can select it (Orca parity).
{ set +x; } 2>/dev/null || :
unset ORCA_AGENT_HOOK_TRANSPORT
if [ -n "$ORCA_AGENT_HOOK_ENDPOINT" ] && [ -r "$ORCA_AGENT_HOOK_ENDPOINT" ]; then
  . "$ORCA_AGENT_HOOK_ENDPOINT" 2>/dev/null || :
fi

command -v jq >/dev/null 2>&1 || exit 0

# Session transcript path for Orca's resume identity (session_start only).
# Polytoken 0.8.x stores sessions under sessions-v1/ (migrated from the
# legacy sessions/ dir, which still exists for old sessions); report the
# path that actually exists, defaulting to the current layout.
pt_session_file=""
case "$payload" in
  *'"session_start"'*)
    pt_id="${POLYTOKEN_SESSION_ID:-}"
    [ -n "$pt_id" ] || pt_id=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)
    pt_session_file="$HOME/.local/share/polytoken/sessions-v1/$pt_id/log.jsonl"
    if [ ! -f "$pt_session_file" ] && [ -f "$HOME/.local/share/polytoken/sessions/$pt_id/log.jsonl" ]; then
      pt_session_file="$HOME/.local/share/polytoken/sessions/$pt_id/log.jsonl"
    fi
    ;;
esac

pi_payload=$(printf '%s' "$payload" | jq -c \
  --arg evt "${POLYTOKEN_HOOK_EVENT:-}" \
  --arg sid "${POLYTOKEN_SESSION_ID:-}" \
  --arg sfile "$pt_session_file" \
  --arg home "$HOME" '
  (.event // $evt) as $e |
  if $e == "session_start" then
    (.session_id // $sid) as $id |
    {
      hook_event_name: "session_start",
      session_id: $id,
      session_file: (if $sfile != "" then $sfile else ($home + "/.local/share/polytoken/sessions-v1/" + $id + "/log.jsonl") end)
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

# Spool fallback — mirrors Orca's own claude-hook.sh: when delivery is
# impossible (gating vars missing) or the POST fails, append the event to
# Orca's spool dir so its listener can drain it later. Never runs for
# tool events (high volume). Best-effort by design: every step fails soft.
spool_hook_event() {
  [ -n "${pi_payload:-}" ] || return 0
  case "$payload" in
    *'"pre_tool_use"'*|*'"post_tool_use"'*|*'"post_tool_use_failure"'*) return 0 ;;
  esac
  [ -n "${ORCA_AGENT_HOOK_ENDPOINT:-}" ] || return 0
  [ -n "${ORCA_PANE_KEY:-}" ] || return 0
  [ -r "$ORCA_AGENT_HOOK_ENDPOINT" ] || return 0
  spool_base=${ORCA_AGENT_HOOK_ENDPOINT%/*}
  spool_dir="$spool_base/spool"
  mkdir -p "$spool_dir" 2>/dev/null || return 0
  chmod 700 "$spool_dir" 2>/dev/null || :
  spool_id=$(printf %s "${ORCA_PANE_KEY:-unknown}" | tail -c 36 | tr '/:' '__')
  spool_file="$spool_dir/pane-$spool_id.jsonl"
  if [ -f "$spool_file" ] && find "$spool_file" -mtime +7 -print -quit 2>/dev/null | grep -q .; then : > "$spool_file"; fi
  [ -f "$spool_file" ] || : > "$spool_file"
  spool_size=$(wc -c < "$spool_file" 2>/dev/null || printf 0)
  [ "$spool_size" -lt 5242880 ] || return 0
  spool_now=$(date +%s 2>/dev/null || printf 0)
  spool_now=$((spool_now * 1000))
  spool_json_escape() { printf %s "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/[[:cntrl:]]/ /g'; }
  { printf '\n{"paneKey":"%s","tabId":"%s","worktreeId":"%s","env":"%s","version":"%s","launchToken":"%s","source":"pi","receivedAt":%s,"payload":%s}\n' \
      "$(spool_json_escape "${ORCA_PANE_KEY:-}")" \
      "$(spool_json_escape "${ORCA_TAB_ID:-}")" \
      "$(spool_json_escape "${ORCA_WORKTREE_ID:-}")" \
      "$(spool_json_escape "${ORCA_AGENT_HOOK_ENV:-}")" \
      "$(spool_json_escape "${ORCA_AGENT_HOOK_VERSION:-}")" \
      "$(spool_json_escape "${ORCA_AGENT_LAUNCH_TOKEN:-}")" \
      "$spool_now" "$pi_payload"; } >> "$spool_file" 2>/dev/null || :
  chmod 600 "$spool_file" 2>/dev/null || :
}

if [ -z "$ORCA_AGENT_HOOK_PORT" ] || [ -z "$ORCA_AGENT_HOOK_TOKEN" ] || [ -z "$ORCA_PANE_KEY" ]; then
  spool_hook_event
  exit 0
fi

if [ "${ORCA_AGENT_HOOK_TRANSPORT:-}" = "raw-json-v1" ] && command -v base64 >/dev/null 2>&1 && command -v tr >/dev/null 2>&1; then
  orca_hook_metadata=$(printf '%s\037%s\037%s\037%s\037%s\037%s' \
    "$ORCA_PANE_KEY" "$ORCA_TAB_ID" "$ORCA_AGENT_LAUNCH_TOKEN" \
    "$ORCA_WORKTREE_ID" "$ORCA_AGENT_HOOK_ENV" "$ORCA_AGENT_HOOK_VERSION" \
    | base64 | tr -d '\n') && \
  [ -n "$orca_hook_metadata" ] && \
  printf '%s' "$pi_payload" | curl -sS -X POST "http://127.0.0.1:${ORCA_AGENT_HOOK_PORT}/hook/pi" \
    --connect-timeout 0.5 --max-time 1.5 \
    --noproxy "127.0.0.1" \
    -H "Content-Type: application/json" \
    -H "X-Orca-Agent-Hook-Token: ${ORCA_AGENT_HOOK_TOKEN}" \
    -H "X-Orca-Agent-Hook-Meta-Encoding: base64" \
    -H "X-Orca-Agent-Hook-Meta: ${orca_hook_metadata}" \
    --data-binary @-
else
  printf '%s' "$pi_payload" | curl -sS -X POST "http://127.0.0.1:${ORCA_AGENT_HOOK_PORT}/hook/pi" \
    --connect-timeout 0.5 --max-time 1.5 \
    --noproxy "127.0.0.1" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -H "X-Orca-Agent-Hook-Token: ${ORCA_AGENT_HOOK_TOKEN}" \
    --data-urlencode "paneKey=${ORCA_PANE_KEY}" \
    --data-urlencode "tabId=${ORCA_TAB_ID}" \
    --data-urlencode "launchToken=${ORCA_AGENT_LAUNCH_TOKEN}" \
    --data-urlencode "worktreeId=${ORCA_WORKTREE_ID}" \
    --data-urlencode "env=${ORCA_AGENT_HOOK_ENV}" \
    --data-urlencode "version=${ORCA_AGENT_HOOK_VERSION}" \
    --data-urlencode "payload@-"
fi >/dev/null 2>&1 || spool_hook_event
exit 0
