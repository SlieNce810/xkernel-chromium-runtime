# Repository Guidelines

## Project Structure & Module Organization

This repository records work for the x-kernel Chromium environment task. Keep each artifact in its intended area:

- `scripts/` contains Linux-host automation. `scripts/wsl2/` holds WSL2-specific build, injection, probe, and recovery scripts; `scripts/testpage/` contains guest test assets.
- `tools/` contains small local utilities, such as image/animation conversion helpers.
- `docs/` stores task instructions and competition materials; `report/` contains technical findings and validation reports.
- `evidence/<date>_<host>-<scenario>/` is an immutable evidence bundle: logs, environment data, commands, manifests, timestamps, and screenshots.
- `tmp/` is disposable local working output. Do not treat it as deliverable evidence.

## Build, Test, and Development Commands

Run build and QEMU commands on a Linux host, from the repository root:

```bash
bash scripts/env-check.sh --out evidence/s1-env/env.txt
python3 scripts/run-session.py --dry-run --cwd ~/x-kernel --out evidence/dry-run
bash scripts/wsl2/build_xk.sh
```

The environment check validates required tools and captures host facts. `--dry-run` validates session arguments without starting QEMU. The WSL2 build script prepares the x-kernel image, injects guest assets, and builds the kernel; review its fixed paths before use.

## Coding Style & Naming Conventions

Write Bash scripts with `#!/usr/bin/env bash`, four-space indentation, quoted variable expansions, and explicit failure handling (`set -u`, `set -o pipefail`, or guarded commands). Write Python for Python 3, with UTF-8 headers when Chinese text is present, type annotations where practical, and `snake_case` names. Keep comments focused on operational rationale and prerequisites.

Name evidence directories as `YYYY-MM-DD_<machine>-<scenario>` (for example, `2026-09-21_t490-p0-fix`). Preserve standard files such as `console.log`, `cmd.txt`, `env.txt`, `manifest.txt`, and `timestamps.csv` when applicable.

## Testing & Evidence Guidelines

Validate changed scripts with their safest mode first (`--help`, `--dry-run`, or a targeted probe). For runtime changes, capture reproducible evidence: exact command, host environment, timestamped console log, and QEMU-generated screenshots. Do not hand-edit evidence logs or overwrite a completed run; create a new scenario directory instead.

## Changes and Review

This checkout has no Git metadata, so no local commit-message history can be enforced. If version control is added, use concise imperative subjects such as `scripts: add DRM probe`, and keep each commit scoped to one change. Reviews should state the Linux/WSL2 host used, commands run, affected evidence directory, results, and screenshots for visual behavior. Never commit credentials, SSH keys, or machine-specific secrets.
