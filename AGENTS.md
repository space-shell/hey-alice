# hey-alice agent notes

- All dependency management goes through the flake devshells (`nix develop` at the
  root for the Android app; `cd gateway && nix develop` for the gateway).
- Commit little, commit often. Milestones in `docs/plan.md` each get their own
  branch/commits; milestone exit criteria live in the plan.
- The Android app is service-first (foreground service + audio engine first, UI
  stays minimal). Paseo connection code is adapted from `space-shell/xagent`
  (branch `bluefox-nx1-voice-companion-plan`), not shared as a module.
- `docs/plan.md` is the source of truth for scope, ADRs, latency budgets, and
  milestone exit criteria. Update it when decisions change, not just code.
