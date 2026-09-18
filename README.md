# polytoken-orca

Run **Polytoken** as an agent inside the **Orca** desktop app — no Orca fork,
no upstream changes — by masquerading as the **Pi** agent entry. Polytoken
sessions launch from Orca's Pi entry, report live `working / blocked / done`
status to Orca's status chips, and resume into the same conversation via
Orca's Resume.

```
Orca Pi entry ──> ~/.local/bin/pi (shim)
                    └─> ~/.config/polytoken/orca-bridge/pi-polytoken   (wrapper)
                          ├─ no --session   ──> exec polytoken new
                          └─ --session P    ──> exec polytoken continue <id>   (P basename)

Polytoken hooks (~/.config/polytoken/hooks.json, 7 managed entries)
  └─> ~/.config/polytoken/orca-bridge/orca-pi-hook.sh
        ├─ session_start         -> session_start {session_id, session_file}
        ├─ pre_user_prompt       -> before_agent_start {prompt}
        ├─ pre_tool_use          -> tool_call {tool_name, tool_input}   (ask_user_question => blocked)
        ├─ notification          -> tool_call ask_user_question (=> blocked)
        ├─ post_tool_use(_fail)  -> tool_execution_end
        └─ stop                  -> agent_end (=> done)
             └─ POST http://127.0.0.1:$PORT/hook/pi  (Orca agent-hook listener)
```

The pinned Orca transport + dialect contract, with provenance for every
fact, lives in [`docs/orca-pi-contract.md`](docs/orca-pi-contract.md).

## Requirements

- macOS (POSIX) with `sh`, `curl`, `jq` (macOS ships `/usr/bin/jq`), `node`
  (only for the test-suite fake listener)
- `polytoken` on PATH
- Orca with **Settings → Agents → status hooks enabled** (already the
  default on this machine)

## Install

### v1 bridge (recommended; includes the v0 wrapper)

```sh
sh bridge/install-bridge.sh --path-shim-force
```

Installs `pi-polytoken` + `orca-pi-hook.sh` (0755) under
`~/.config/polytoken/orca-bridge/`, merges the seven managed hook entries
into `~/.config/polytoken/hooks.json` (validate → stage → commit; timestamped
backups in `orca-bridge/backups/`; idempotent; unrelated entries preserved),
and creates the PATH shim `~/.local/bin/pi -> pi-polytoken`.

`--path-shim-force` deliberately **shadows** a real `pi` elsewhere on PATH
(this machine has homebrew Pi at `/opt/homebrew/bin/pi` — it stays intact
and invocable by absolute path; only PATH resolution changes). Without
`--force` the installer refuses loudly if any other `pi` exists.

### v0 wrapper only (no status bridge)

```sh
sh bridge/install-wrapper.sh [--path-shim | --path-shim-force]
```

### One-time Orca setup (manual, in the Orca app)

1. **Settings → Agents: enable Pi** (it is disabled by default on this
   machine — `settings.disabledTuiAgents` contains `pi`; the picker entry
   and `--agent pi` CLI launches are refused while disabled).
2. Pick **Pi** from the agent combobox in any worktree. Orca's `pi` launch
   resolves through the shim to Polytoken. (Verified 2026-08-18: PATH
   resolution of the shim works in both login-shell panes and direct-exec
   panes; see "Verification status".)

## Daily use

- **Launch**: pick Pi in the agent combobox → Polytoken TUI starts in the
  worktree. Tabs/chips will say "Pi" (accepted trade-off).
- **Status**: the worktree chip shows `working` during turns, `blocked`
  (worktree status "permission") while a Polytoken question overlay is up,
  `done` at end of turn.
- **Resume**: close the pane, then use Orca's Resume — Orca relaunches
  `pi --session <log.jsonl>`, the wrapper maps it to
  `polytoken continue <session-id>`, and the prior conversation is back.
- Every wrapper invocation is recorded in
  `~/.config/polytoken/orca-bridge/pi-polytoken.argv.log` (bounded, stdin
  never logged) — useful to see exactly what Orca passed.

## Verification status

All logic is covered by 79 shell tests runnable anywhere
(`sh bridge/test/test_*.sh` — no Orca needed). Most recently re-verified
against **production Orca 1.4.205** (2026-09-18, self-served via `orca` CLI
in a scratch worktree; earlier full verification on 1.4.184, 2026-08-18 —
see `docs/orca-pi-contract.md` §7 for what changed between versions):

| Capability | Status |
|---|---|
| Shim PATH resolution in Orca panes | ✅ verified live (1.4.184 + 1.4.205) |
| `pi` → `polytoken new` in a real Orca pane | ✅ verified live (1.4.184 + 1.4.205) |
| Chip cycle `working → done` during a real turn | ✅ verified live (1.4.184 + 1.4.205) |
| Chip `blocked` on `ask_user_question` overlay | ✅ verified live (1.4.184 + 1.4.205; answering the overlay needs the GUI — terminal-sent keystrokes are ignored) |
| Resume: `pi --session <log.jsonl>` → `polytoken continue <id>`, same session + prior conversation | ✅ verified live (1.4.184 + 1.4.205, `sessions-v1` paths) |
| Launch from the **Pi picker entry** (AC.2) | ✅ delegated — operator accepted the CLI verification as witness (2026-09-18); the combobox path itself was not exercised (Pi remains disabled in Settings → Agents) |
| Orca **Resume UI click** (vs. the recorded argv shape, already proven) | ✅ delegated — same basis; the `pi --session` relaunch itself was verified live in a real Orca pane |

> Witness decision (2026-09-18): the operator judged the orca-CLI
> verification sufficient for v0/v1/v2; the tags are cut on that basis.
> The two UI interactions above remain available as optional extras.

Note: Orca 1.4.205 has **no native Polytoken agent** (the `polytoken`
hook files some tools install under `~/.orca/agent-hooks/` belong to an
unreleased upstream PR and their `/hook/polytoken` route 404s on 1.4.205).
The Pi masquerade remains the only working integration — details in
`docs/orca-pi-contract.md` §7.2.

## Operator finish line (RESOLVED 2026-09-18)

The operator accepted the orca-CLI verification as the smoke witness for
all three milestones; v0/v1/v2 are tagged on that basis (2026-09-18, Orca
1.4.205). Note AC.2's combobox launch path itself was never exercised —
Pi is still in `disabledTuiAgents` — so if you ever enable Pi and want
the UI witnessed too:

1. **Orca → Settings → Agents: enable Pi** (currently disabled; `--agent pi`
   CLI launches are refused until then).
2. **Picker smoke (AC.2)**: open any worktree, pick **Pi** from the agent
   combobox → the Polytoken TUI must start there. Watch the chip:
   `working` during a turn, `blocked` (worktree shows "permission") when
   you answer a question, `done` at rest. The exact launch argv is
   recorded automatically in
   `~/.config/polytoken/orca-bridge/pi-polytoken.argv.log`.
3. **Resume smoke (AC.6)**: exit the pane (Ctrl-C or /quit), then use
   Orca's **Resume** → the same session must come back (same session id,
   prior conversation visible).

If anything misbehaves: `sh bridge/test/test_orca_pi_hook.sh` re-validates
the dialect against pinned fixtures; uninstall is one command (below).

## Known limitations

- **Everything is labeled "Pi"** in Orca UI and telemetry (by design).
- **Session-history panel**: Polytoken sessions do **not** appear in Orca's
  Pi session-history listing (Orca scans a Pi-specific store we do not
  write). Sessions remain resumable via live/recent panes; this is the
  documented v2 decision (resume-only).
- **`notification` events** are Polytoken harness events (job completions,
  service restarts), not permission prompts; the bridge surfaces their
  `.summary` as a blocked flash. Real interaction blocking comes from
  `ask_user_question`.
- **Direct-exec panes** (`terminal create --command pi`, no shell): the
  Polytoken TUI's cursor-position probe can fail if the pane was never
  displayed (observed once in a headless worktree). Login-shell panes and
  visible panes are unaffected; if you hit it, open/switch to the tab and
  relaunch.
- macOS/POSIX only.

## Uninstall

```sh
sh bridge/uninstall-bridge.sh      # removes hooks entries, scripts, our shim
# or, for a wrapper-only install:
sh bridge/uninstall-wrapper.sh
```

Both refuse to touch anything they do not own (retargeted shims, unrelated
`orca-*` hook entries, real `pi` binaries). `uninstall-bridge.sh` is the
one to use once the bridge is installed.

## Re-checking after an Orca update

Orca auto-updates; the hook dialect/transport may drift. Re-verify in one
command: `sh bridge/test/test_orca_pi_hook.sh` (fixtures mirror Orca's own
listener expectations), then check `docs/orca-pi-contract.md` §7 (drift
notes per Orca release) and §9 (smoke log) for the Orca version each
verification ran against.
