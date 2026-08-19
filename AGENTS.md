# AGENTS.md — polytoken-orca

Repo that lets Polytoken masquerade as Orca's Pi agent entry (wrapper +
status bridge). No Orca fork; everything here is shell scripts, a JSON
fragment, tests, and docs.

## Layout

- `bin/pi-polytoken` — the `pi` masquerade wrapper Orca launches. NEVER
  log stdin here; argv logging to `pi-polytoken.argv.log` is intentional
  and bounded.
- `bridge/orca-pi-hook.sh` — Polytoken hook → Pi-dialect payload → POST to
  Orca's agent-hook listener. Must ALWAYS `exit 0` within ~2s.
- `bridge/hooks.fragment.json` — the seven managed hook entries. Their
  exact `name`s are the ownership marker: install/uninstall touch only
  these names. Keep names in sync with `MANAGED`/`MANAGED_NAMES` in the
  four installer scripts.
- `bridge/install-wrapper.sh` / `uninstall-wrapper.sh` — v0 standalone.
- `bridge/install-bridge.sh` / `uninstall-bridge.sh` — v1; owns wrapper +
  hook + hooks.json merge. Transaction contract: validate everything
  before mutating; stage on the destination fs; commit scripts first,
  `hooks.json` LAST; rollback restores prior files byte+mode identical.
- `bridge/test/` — four suites, plain `sh`, no Orca required.
- `docs/orca-pi-contract.md` — pinned Orca contract + provenance + smoke
  log. Update it whenever Orca behavior is re-verified.

## Contracts

- **Tests**: run all suites before committing script changes —
  `for t in bridge/test/test_*.sh; do sh "$t" || exit 1; done`
  (71 assertions total). Failure-injection tests PATH-override `mv`/`ln`; keep
  installers calling plain `mv`/`cp`/`rm` by name so injection keeps
  working.
- **POSIX sh, macOS-first**: scripts run under `/bin/sh` = bash 3.2. No
  `set -u` around possibly-empty `"$@"` expansions (fatal on bash 3.2);
  no bashisms in `bin/` or `bridge/` scripts.
- **Secrets**: `ORCA_AGENT_HOOK_TOKEN` is sourced at runtime from
  `$ORCA_AGENT_HOOK_ENDPOINT`. It must NEVER be echoed, logged, committed,
  or written anywhere. Never commit endpoint.env or real capture files.
- **Fail-open**: the hook bridge reports status only; worst case is a
  stale chip. Never add anything that can block the agent (keep curl
  timeouts 0.5/1.5s, always exit 0).
- **hooks.json safety**: the operator's live file is user config. Only the
  seven managed names may be added/removed; unrelated entries — including
  other `orca-*` names — must survive byte-for-byte semantically. Any
  change to merge logic requires the failure-injection tests to still
  pass.

## Version status

- v0 (launch) / v1 (status) / v2 (resume): mechanisms verified against
  production Orca 1.4.184 on 2026-08-18 via `orca` CLI (see README
  "Verification status"); git tags land after the operator picker-entry
  smoke (enable Pi in Settings → Agents, then launch from the combobox).
