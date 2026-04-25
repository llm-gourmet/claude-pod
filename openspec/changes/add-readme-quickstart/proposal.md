## Why

New users land on the README, see Installation followed by hundreds of lines of reference documentation, and have no clear path from zero to a working session. A focused quickstart lowers the time-to-first-session by giving a single end-to-end flow with no decisions required.

## What Changes

- Add a **Quickstart** section near the top of `README.md`, between the intro line and the Installation section
- The section covers five steps: install prerequisites, clone + install, create a profile, start a session, and (optional) add a secret
- The installation and profile sections remain unchanged — quickstart links to them for deeper reference
- No code changes; documentation only

## Capabilities

### New Capabilities

- `readme-quickstart`: A self-contained quickstart section in README.md that walks a new user from clone to first Claude Code session in five steps, with copy-paste commands and no decisions required

### Modified Capabilities

<!-- None — no existing spec requirements are changing -->

## Impact

- `README.md` only — no code, no configuration, no installed files affected
