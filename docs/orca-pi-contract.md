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

From **[LOCAL-HOOK]** — the bridge mirrors this transport (re-verified against
production Orca 1.4.205's `claude-hook.sh` on 2026-09-17):

1. `unset ORCA_AGENT_HOOK_TRANSPORT` then `source
   "$ORCA_AGENT_HOOK_ENDPOINT"` only when that variable is set AND the file
   it names is readable. Unsetting first means the endpoint file's
   `ORCA_AGENT_HOOK_TRANSPORT` (if any) wins over the ambient environment.
   (Live value of the referenced file, **[LOCAL-ENV]**, 2026-09-17: contains
   `ORCA_AGENT_HOOK_PORT`, `ORCA_AGENT_HOOK_TOKEN`,
   `ORCA_AGENT_HOOK_ENV=production`, `ORCA_AGENT_HOOK_VERSION=1`,
   `ORCA_AGENT_HOOK_TRANSPORT=raw-json-v1`.)
2. Silent no-op (`exit 0`) unless **all** of
   `ORCA_AGENT_HOOK_PORT`, `ORCA_AGENT_HOOK_TOKEN`, `ORCA_PANE_KEY` are
   present in the environment (on gating failure Orca's own hooks spool the
   event instead; see step 6).
3. POST to `http://127.0.0.1:${ORCA_AGENT_HOOK_PORT}/hook/pi`
   (**[UPSTREAM-TEST]**: `/hook/<source>` maps to source; `pi` confirmed in
   the v1.4.205 tag's `agent-hook-listener.ts` provider list and live probed
   2026-09-17: form and raw-json POSTs to `/hook/pi` both return 204).
4. Transport selection by `ORCA_AGENT_HOOK_TRANSPORT` (from the endpoint
   file):
   - `raw-json-v1` (current live value): payload POSTed verbatim as
     `Content-Type: application/json` `--data-binary @-`, with the six
     pane/env values base64-packed US-separator (`\037`) style into headers
     `X-Orca-Agent-Hook-Meta-Encoding: base64` and
     `X-Orca-Agent-Hook-Meta: <base64(paneKey \037 tabId \037 launchToken
     \037 worktreeId \037 env \037 version)>`.
   - anything else (or missing `base64`/`tr`): classic form POST,
     `Content-Type: application/x-www-form-urlencoded`, fields
     `paneKey`, `tabId`, `launchToken`, `worktreeId`, `env`, `version`,
     `payload@-` (URL-encoded). Still accepted by the live 1.4.205 listener
     (probed 2026-09-17, HTTP 204).
5. curl flags: `--connect-timeout 0.5 --max-time 1.5 --noproxy 127.0.0.1`.
   Deliberate divergence from Orca's own hook: 1.4.205's `claude-hook.sh`
   allows the endpoint file to override `${connect_timeout}`/`${max_time}`;
   the bridge hardcodes 0.5/1.5 so no endpoint value can ever extend a
   hook's blocking window (AGENTS.md fail-open contract). The hook script
   **always exits 0** and never emits output (agent running outside Orca =
   silent no-op).
6. Spool fallback (Orca 1.4.205 hooks): when delivery is impossible (gating
   failure) or the POST fails, Orca's own hooks append the event to
   `<endpoint dir>/spool/pane-<paneKey-tail>.jsonl` (JSONL records
   `{"paneKey",...,"source","receivedAt","payload"}`, mode 0600 in a 0700
   dir, 5 MiB/pane cap, 7-day age reset, tool events never spooled) for the
   listener to drain later. The bridge mirrors this mechanism with
   `"source":"pi"` and the translated Pi-dialect payload. Spooled payloads
   contain prompt/tool-input text — same trust model as Orca's own hooks.

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
Resume is unavailable. The bridge resolves `session_file` against Polytoken's
current storage layout (see §7.3): `sessions-v1/<id>/log.jsonl` when it
exists, legacy `sessions/<id>/log.jsonl` otherwise, defaulting to the
`sessions-v1` layout for brand-new sessions.

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
- Sessions live at `~/.local/share/polytoken/sessions-v1/<id>/log.jsonl`
  (Polytoken 0.8.10, re-verified 2026-09-17; 0.7-era layouts used
  `sessions/<id>/log.jsonl` and the old dir still exists); launch
  `polytoken new`; resume `polytoken continue <id>`.
- Tool events expose `.tool_name` and `.input` (object) on stdin.
- Polytoken's interactive-question tool is literally named
  `ask_user_question` → maps to Orca's blocked state natively.
- Operator's live global `hooks.json` content at plan time: `[]`.

### 4.1 Empirically captured stdin shapes (Phase 0 step 4)

Captured 2026-08-18 with a scratch **project-level** hooks file
(`/tmp/pt-capture/work/.polytoken/hooks.json`) driving `polytoken exec` —
the operator's global `~/.config/polytoken/hooks.json` was never touched
(empty array, verified before and after). Project-level hooks load for
runtime commands when the working dir contains `.polytoken/hooks.json`;
the global file loads before any project file.

Every payload carries `event` (event name) and `matcher_subject`
(the matcher key: event name for lifecycle events, tool name for tool
events), plus:

| Event | Extra fields (exact observed shapes) |
|---|---|
| `session_start` | `session_id` |
| `pre_user_prompt` | `prompt_id`, **`prompt`** (the prompt text — this is the undocumented path) |
| `pre_model_turn` | `prompt_id` |
| `pre_tool_use` | `prompt_id`, `tool_name`, `call_id`, **`input`** (object) |
| `post_tool_use` | same as `pre_tool_use` |
| `post_tool_use_failure` | same as `pre_tool_use` + `failure: {kind, error_message}` |
| `stop` | `prompt_id` |
| `notification` | see below |

Example `pre_tool_use`:
`{"event":"pre_tool_use","matcher_subject":"shell_exec","prompt_id":"…","tool_name":"shell_exec","call_id":"call_…","input":{"command":"echo hello-capture","timeout_seconds":30,"background":false,"name":"hello-capture"}}`

**`notification` semantics (important correction to the original plan
assumption):** Polytoken notifications are **harness events** —
`job_complete`, `subagent_complete`, `hook_result`, `service_restart`,
`service_failed`, `service_health_check_passed`, `extension_message`,
`unknown` (daemon `NotificationType` schema, OpenAPI `Notification`:
required `id`, `notification_type`, `source`, `summary`, `timestamp`;
optional `detail`). They are queued and **drained into a model turn**
(scheduler auto-drain), not permission prompts. No `notification` hook
event fires in single-prompt `exec` mode, so the payload shape above is
**inferred from the daemon schema + binary strings, not empirically
captured**; the bridge reads the message from `.summary` (primary) with a
fallback to the literal string `Polytoken needs attention`. Consequence
for the bridge: `notification` → blocked is *not* a permission-prompt
signal; it surfaces background-event attention (e.g. a finished job) as a
blocked flash that the following drain turn overwrites with working.
Blocked-state coverage for real interaction remains `ask_user_question`
(pass-through). Chip behavior (working/blocked/done) was verified live
against production Orca on 2026-08-18 (§9); the picker-entry smoke with an
operator-visible chip remains the final witness.

## 5. Pi picker entry override mechanism

Recon 2026-08-18 (operator's live `profiles/local-default/orca-data.json` +
upstream `stablyai/orca` repo + onorca.dev docs):

- Per-agent settings in `settings.`: `agentDefaultArgs.<agent>` (yolo-family
  flag strings — e.g. claude `--dangerously-skip-permissions`, gemini
  `--yolo`; **no `pi` entry set** on this machine) and
  `agentDefaultEnv.<agent>` (only goose). No per-agent launch **command**
  key exists in the live settings object. Upstream issue #6281 references
  an internal `agentCmdOverrides[session.agent]`, suggesting the data model
  supports command overrides, but no Settings surface for it was found.
  ⇒ **Primary mechanism: PATH shim `~/.local/bin/pi` → installed wrapper**
  (the machine already keeps `node`/`polytoken` in `~/.local/bin`, which
  login shells put on PATH; Orca panes run the user's shell).
- `settings.disabledTuiAgents` currently includes `pi` — the Pi entry must
  be re-enabled in Settings → Agents before it appears in the picker.
- `settings.agentStatusHooksEnabled` is already `true`.
- Default flags Orca appends to Pi launches: the argv log recorded two
  real invocations so far — a bare `pi` (no flags; via `terminal create
  --command` / login shell) and the resume form
  `pi --session <path>/log.jsonl`. Orca's picker-entry launch flags (if
  any) get recorded automatically at the operator smoke.

## 6. Session-history panel scan (Phase 0 step 3)

Recon 2026-08-18 (upstream `stablyai/orca`): the session-history/AI-Vault
panel uses **provider-specific scanners**; upstream issues (#9876, #5376)
classify `pi` among "one file per session; trashing `filePath` is complete"
providers — i.e. the Pi store is a set of session files (JSONL) and the
panel lists them per file. The exact filesystem glob was NOT recoverable
from public source (would need app.asar extraction or a clone). Resume
identity, however, is pinned independently: `session_start`'s
`session_file` becomes `providerSession.transcriptPath`, and
`hook-provider-session-invalidation.ts` (+ its test, using `/pi/a.jsonl`)
confirms transcriptPath is the durable provider-session identity. Decision
for v2: **resume-only** (default); the history panel's Pi listing stays
empty for Polytoken sessions unless the stretch stub item is later proven
trivially safe — see README known limitations.

## 7. Re-verification after Orca 1.4.184 → 1.4.205 (2026-09-17/18)

Re-checked after production Orca auto-updated (1.4.184, verified
2026-08-18 → 1.4.205, released 2026-09-17). Findings:

### 7.1 The Pi integration is unchanged and still supported

- The v1.4.205 tag contains `agent-hook-listener-pi-compatible.test.ts`
  (Pi dialect: `tool_call`/`tool_execution_start`, `ask_user_question` →
  literal `blocked`, normal tools → `working`, tool end clears blocked,
  `agent_end` → `done`, Pi `session_start` resume identity) and lists `pi`
  in `agent-hook-listener.ts`'s provider sources. No public deprecation
  marker.
- Live probes (2026-09-17, running 1.4.205 listener): POSTs to `/hook/pi`
  return **204** via BOTH the form transport and the raw-json-v1 transport
  (with a junk pane key; auth accepted, unknown pane ignored).

### 7.2 Orca 1.4.205 has NO native Polytoken agent

- `/hook/polytoken` returns **404** on the live 1.4.205 listener, and the
  installed app bundle (`app.asar`, `app.asar.unpacked`) contains zero
  `polytoken` strings.
- Upstream: native Polytoken support exists only as **open, unreleased
  contributor PR #18577** (branch of `sjennings/orca`): launch
  `polytoken new [--prompt …]`, resume `polytoken continue <id>` from the
  `session_start` id, `/hook/polytoken` accepting raw Polytoken event JSON,
  seven registered events (`notification` deliberately unregistered,
  `post_model_turn` unmapped, `ask_user_question` → state `waiting`). When
  a release ships it, the masquerade can be retired in favor of the native
  entry — until then `/hook/pi` is the only working path.

### 7.3 Machine-level findings (2026-09-17/18)

- **Polytoken 0.8.10 migrated session storage** to
  `~/.local/share/polytoken/sessions-v1/<id>/` (legacy `sessions/` still
  holds migrated-era leftovers). The bridge now resolves `session_file`
  v1-first (§3); reporting the stale legacy path would point Orca's
  `providerSession.transcriptPath` at a nonexistent file.
- The live `~/.config/polytoken/hooks.json` contains seven **foreign**
  entries named `orca-managed-polytoken-*` (installed 2026-09-03/04,
  originating from the unreleased PR #18577's hook scripts in
  `~/.orca/agent-hooks/polytoken-*.sh`). They POST raw Polytoken events to
  `/hook/polytoken`, which 404s on 1.4.205 — they are harmless (fail-open)
  but dead weight. Our installers preserve them byte-for-byte as unrelated
  entries; removal is an operator decision (they are not ours to touch).
- Orca's own hook transport gained `ORCA_AGENT_HOOK_TRANSPORT` (live:
  `raw-json-v1`), `--noproxy 127.0.0.1`, and the spool fallback (§1.6).

## 8. Security review dispositions (2026-08-18)

An adversarial review pass over the wrapper/bridge/installers produced a
FIX-FIRST verdict; findings and dispositions:

**Fixed (covered by new tests, 71 assertions total):**
- xtrace (`sh -x`) could trace token expansions → `set +x` now precedes
  endpoint sourcing (test asserts no token in `sh -x` output).
- Standalone installer could leave a committed wrapper on shim failure →
  post-commit rollback now restores prior wrapper byte+mode or removes a
  fresh one (ln-failure injection tests).
- Bridge uninstall was not transactional after the hooks.json commit →
  reworked: owned files are renamed aside (same filesystem), hooks.json
  commits LAST, any pre-commit failure restores everything including our
  shim (mv-failure injection at the commit ordinal).
- Malformed-but-parseable hooks arrays (e.g. a scalar element) collapsed
  jq errors to "no managed entries" → both uninstallers now fail closed on
  any non-`{name: string}` element and refuse to mutate.
- Unbounded stdin → hook caps stdin at 256 KiB (`head -c`); oversized
  payloads degrade to silent exit 0.
- Uninstall staged in TMPDIR (cross-fs mv) → stages beside hooks.json.
- Signal + EXIT traps ran rollback twice → traps reset on rollback entry.
- Wrapper argv log: now created mode 0600 with control chars stripped
  (single-line records; boundary-proving stub records argc + per-arg).

**Rebutted (pinned-contract constraints, documented residual risks):**
- "Do not source the endpoint file": sourcing is byte-for-byte Orca's own
  claude-hook.sh transport (§1); the file is Orca-owned trusted input.
  Parsing it as data would deviate from the pinned contract.
- "Token visible in curl argv during ≤1.5 s": identical to Orca's own
  transport; a same-user observer can read the endpoint file itself, and
  the pinned contract fixes the mechanism. No `curl -v` anywhere.
- "Make argv logging opt-in": default-on argv capture is a design
  requirement (it recorded the real launch and resume argv shapes in §7);
  mitigated to 0600 + sanitization instead.

## 9. Smoke log

| Version | Date | Orca app version | Result |
|---|---|---|---|
| v1 core (launch via shim + chip cycle) | 2026-08-18 | 1.4.184 | ✅ self-served via `orca` CLI, scratch worktree `bridge-smoke` (removed after): `terminal create --command 'pi'` in a login-shell pane → shim resolved → `polytoken new` (session `08x64j-crowd`); during a tool turn `worktree ps` showed `state: working` (worktree status `working`); after turn `state: done` |
| v1 blocked state | 2026-08-18 | 1.4.184 | ✅ `ask_user_question` overlay in the live pane → `state: blocked`, worktree status `permission`; after answering (Enter on the overlay) → `state: done` |
| v2 resume | 2026-08-18 | 1.4.184 | ✅ recorded real resume argv: `pi --session /Users/wire2k/.local/share/polytoken/sessions/08x64j-crowd/log.jsonl` → wrapper → `polytoken continue 08x64j-crowd` → same session, prior conversation (tool output + question + answer) present |
| v1 core re-check (launch + chip cycle) | 2026-09-18 | 1.4.205 | ✅ self-served via `orca` CLI, scratch worktree `bridge-smoke-1420` (removed after): `terminal create --command 'pi'` → shim resolved (argv log `$0 = ~/.local/bin/pi`) → `polytoken new`; worktree `ps` showed the agent registered (`agentType: pi`, sent prompt recorded) and `state: done` after the turn |
| v1 blocked state re-check | 2026-09-18 | 1.4.205 | ✅ `ask_user_question` in the pane → `state: blocked`, `toolName: ask_user_question`. (Answering the overlay from the CLI was not possible — the overlay ignores pasted/terminal-sent keystrokes; same operator-GUI behavior as before, see README known limitations) |
| v2 resume re-check | 2026-09-18 | 1.4.205 | ✅ `pi --session …/sessions-v1/0bccpb-slug/log.jsonl` → `polytoken continue 0bccpb-slug` → same session id; prior conversation present (the resumed agent recalled the earlier exchange and the pending question) |
| v0 picker entry (AC.2) | 2026-09-18 | 1.4.205 | ✅ delegated — operator accepted the CLI verification (launch, chips, blocked, resume) as smoke witness for v0/v1/v2; the combobox path itself was NOT exercised (Pi remains in `disabledTuiAgents`, `--agent pi` refuses while disabled) |
| v2 Resume UI click (AC.6) | 2026-09-18 | 1.4.205 | ✅ delegated — same basis; the `pi --session` resume relaunch itself was verified live in a real Orca pane (row above), only the UI button click was not performed |

Additional live findings (2026-08-18):

- **Shim PATH resolution works in real Orca panes** both through a login
  shell (`zsh -l` → `pi`) and with direct exec (`terminal create --command
  'pi'`): argv log recorded `$0 = /Users/wire2k/.local/bin/pi` in both.
- **Direct-exec caveat**: in a never-displayed (headless) worktree pane,
  `polytoken new` failed its TUI cursor-position probe once
  ("cursor position could not be read"); login-shell/visible panes were
  unaffected. Suspect pane visibility rather than exec style.
- Orca pane env in agent terminals includes the `ORCA_*` hook variables
  (implied by the live chip transitions above — the hook's gating on
  `ORCA_PANE_KEY` passed).
