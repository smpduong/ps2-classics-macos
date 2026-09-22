# Project guidance

This folder stages a native macOS successor to PS2 Classics GUI. Read README.md and docs/PROJECT_PLAN.md before extending it.

- Target macOS 12.0+, both x86_64 and arm64. Client targets are the 2017 MacBook Air and 2024 M4 Mac mini; exact installed OS versions still need recording.
- Keep UI and conversion/inspection logic separate. Do not introduce Wine or require end-user development tools.
- Open source images read-only. Future preparation must use isolated workspaces. Never silently overwrite source or destination files.
- Do not infer CD/DVD media solely from image size. Preserve detection evidence and explicit user overrides.
- Bound memory use; default to a single conversion worker until benchmarks justify more.
- Invoke helpers with structured argument arrays, never shell-interpolated user filenames.
- Do not label output built, verified or console-tested unless that level has actually been established.
- Treat historical discussion findings as audit leads, not proof of defects in a newly selected source revision. Pin and record source revisions before reuse.
- Do not commit user game images, saves, keys, console-derived assets or personal paths/logs. Use generated test fixtures.
- Keep current implementation status accurate. No placeholder conversion should report success.
- Run swift test for core changes and the Universal build script for release or compatibility changes. Real Intel Monterey and PS3 testing remain separate acceptance gates.

- Use the four user-supplied images in ROMS for local workflow integration checks as stages become available; read docs/LOCAL_TEST_IMAGES.md for fixture roles and known observations. Keep them read-only and out of Git.
