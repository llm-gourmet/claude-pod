---
phase: quick
plan: 260410-ic4
subsystem: proxy
tags: [logging, security, redaction]
dependency_graph:
  requires: []
  provides: [redaction-map-logging]
  affects: [proxy/proxy.js]
tech_stack:
  added: []
  patterns: [partial-masking-for-log-safety]
key_files:
  modified: [proxy/proxy.js]
decisions:
  - Masked prefix uses min(8, floor(length/3)) chars to balance identification vs safety
metrics:
  duration: 47s
  completed: 2026-04-10T11:14:29Z
---

# Quick Task 260410-ic4: Log Redacted Secret Mappings in Anthropic Proxy Summary

JWT-style partial masking of secret values logged as redaction_map array in anthropic.jsonl for operator visibility into which secrets are being caught per request.

## What Was Done

### Task 1: Add redaction map logging to proxy.js

- Added `logPairs` array to `buildMaps()` function that captures masked secret prefixes alongside placeholders and env var names
- Each log entry shows `masked` (first N chars + "..."), `placeholder`, and `env_var` fields
- Masking uses `Math.min(8, Math.floor(realValue.length / 3))` to show enough for identification without leaking usable secret material
- Updated destructuring at call site from `{ redactMap, restoreMap }` to `{ redactMap, restoreMap, logPairs }`
- Added conditional log call: when `logPairs.length > 0`, logs info-level "Active redaction mappings" with `redaction_map` array
- Commit: b77f0cc

## Deviations from Plan

None - plan executed exactly as written.

## Known Stubs

None.

## Verification Results

- `node -c proxy/proxy.js`: No syntax errors
- All 4 automated checks passed: logPairs exists, redaction_map logged, masked field present, slice used for partial masking
- No full secret values appear in log output (only first N chars + "...")

## Self-Check: PASSED
