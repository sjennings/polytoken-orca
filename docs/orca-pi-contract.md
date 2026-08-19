# Orca ⇄ Pi-Dialect Contract (pinned)

This document pins the externally-verified contract that the Polytoken→Orca
bridge depends on. Every fact lists its provenance so drift can be
re-verified quickly after a production Orca auto-update.

Provenance keys:

- **[LOCAL-HOOK]** — read from the operator's live install:
  `~/.orca/agent-hooks/claude-hook.sh` (Orca's own managed hook script).
- **[LOCAL-ENV]** — read from the operator's live endpoint file:
  `~/Library/Application Support/orca/agent-hooks/endpoint.env`.
- **[UPSTREAM-TEST]** — upstream Orca test
  `agent-hook-listener-transport.test.ts`
  (route `/hook/pi` → source `pi`).
- **[UPSTREAM-TEST]** — upstream Orca test
  `agent-hook-listener-pi-compatible.test.ts` (Pi payload dialect).
- **[ORCA-DOCS]** — Orca session-history docs (Pi resume behavior).
- **[PT-DOCS]/[PT-LOCAL]** — Polytoken docs / local verification.

---

## 1. Transport (how a hook POST reaches Orca)

From **[LOCAL-HOOK]** — the bridge copies this transport verbatim:

1. `source "$ORCA_AGENT_HOOK_ENDPOINT"` only when that variable is set AND
   the file it names is readable. Orca injects this variable into pane
   environments alongside the other `ORCA_*` vars; there is no hardcoded
   fallback path in the lookup. (Live value of the referenced file,
   **[LOCAL-ENV]**: contains `ORCA_AGENT_HOOK_PORT`, `ORCA_AGENT_HOOK_TOKEN`,
   `ORCA_AGENT_HOOK_ENV=production`, `ORCA_AGENT_HOOK_VERSION=1`.)
2. Silent no-op (`exit 0`, no request) unless **all** of
   `ORCA_AGENT_HOOK_PORT`, `ORCA_AGENT_HOOK_TOKEN`, `ORCA_PANE_KEY` are
   present in the environment.
3. POST to `http://127.0.0.1:${ORCA_AGENT_HOOK_PORT}/hook/pi`
   (**[UPSTREAM-TEST]**: `/hook/<source>` maps to source; `pi` is confirmed).
4. Headers: `X-Orca-Agent-Hook-Token: ${ORCA_AGENT_HOOK_TOKEN}`,
   `Content-Type: application/x-www-form-urlencoded`.
5. Form fields (URL-encoded):
   - `paneKey=${ORCA_PANE_KEY}`
   - `tabId=${ORCA_TAB_ID}`
   - `launchToken=${ORCA_AGENT_LAUNCH_TOKEN}`
   - `worktreeId=${ORCA_WORKTREE_ID}`
   - `env=${ORCA_AGENT_HOOK_ENV}`
   - `version=${ORCA_AGENT_HOOK_VERSION}`
   - `payload@-` — the event JSON read from stdin.
6. curl flags: `--connect-timeout 0.5 --max-time 1.5`; the hook script
   **always exits 0** and never emits output (agent running outside Orca =
   silent no-op).

The `ORCA_*` pane variables are injected into the terminal Orca launches and
therefore inherited by Polytoken and its hook subprocesses.

## 2. Pi hook dialect (payload JSON)

From **[UPSTREAM-TEST]** (`agent-hook-listener-pi-compatible.test.ts`).
Fields live inside the `payload` form field:

| Payload | Orca effect |
|---|---|
| `{"hook_event_name":"session_start","session_id":<id>,"session_file":<path>}` | registers provider session: `providerSessionOnly: true`, `providerSession: {key:"session_id", id, transcriptPath: session_file}` — this is the resume identity |
| `{"hook_event_name":"before_agent_start","prompt":<text>}` | state `working`, prompt shown |
| `{"hook_event_name":"tool_call","tool_name":<name>,"tool_input":<obj>}` | state `working` with tool info; **if `tool_name == "ask_user_question"` → state `blocked`**, `interactivePrompt` = JSON-stringified `tool_input` |
| `{"hook_event_name":"tool_execution_start", ...}` | same as `tool_call` |
| `{"hook_event_name":"tool_execution_end"}` | back to `working` (clears blocked/interactivePrompt) |
| `{"hook_event_name":"agent_end"}` | state `done` |

## 3. Pi resume

From **[ORCA-DOCS]**: Orca resumes Pi with `pi --session <session_file>`; the
path comes from the `session_start` payload above. If the file is missing,
Resume is unavailable.

## 4. Polytoken public surface

From **[PT-DOCS]/[PT-LOCAL]**:

- Hook config: `~/.config/polytoken/hooks.json` — top-level JSON **array** of
  `{name, event, matcher?, handler: {bash: "<script>"}}`. Unknown handler keys
  are rejected. Multiple entries per event coexist as separate array entries.
  The global file loads before any project-level file.
- Handler runtime: bash, event JSON on **stdin**; env
  `POLYTOKEN_SESSION_ID`, `POLYTOKEN_HOOK_EVENT`, `POLYTOKEN_PROJECT_DIR`;
  30 s deadline.
- Events: `session_start`, `pre_user_prompt`, `pre_model_turn`,
  `pre_tool_use`, `post_tool_use`, `post_tool_use_failure`, `stop`,
  `notification`, …
- Sessions live at `~/.local/share/polytoken/sessions/<id>/log.jsonl`;
  launch `polytoken new`; resume `polytoken continue <id>`.
- Tool events expose `.tool_name` and `.input` (object) on stdin.
- Polytoken's interactive-question tool is literally named
  `ask_user_question` → maps to Orca's blocked state natively.
- Operator's live global `hooks.json` content at plan time: `[]`.

### 4.1 Empirically captured stdin shapes (Phase 0 step 4)

_Status: pending capture._ The prompt-text path for `pre_user_prompt` and
the message path for `notification` are not documented; they are captured
empirically and recorded here. The bridge jq programs and the fixtures in
`bridge/test/` are written from these recorded shapes; a missing field
degrades to an empty string, never to handler failure.

## 5. Pi picker entry override mechanism

_Status: pending recon (Phase 0 step 2)._ Expected per Orca docs:
Settings → Agents, per-agent custom launch command/args/env. Fallback:
PATH shim at `~/.local/bin/pi`. Default flags Orca appends to Pi launches
are captured with a temporary argv-logging wrapper and recorded here.

## 6. Session-history panel scan (Phase 0 step 3)

_Status: pending recon._ Needed only for the Phase 3 history decision;
resume does not depend on it.

## 7. Smoke log

| Version | Date | Orca app version | Result |
|---|---|---|---|
| v0 | — | — | pending |
| v1 | — | — | pending |
| v2 | — | — | pending |
