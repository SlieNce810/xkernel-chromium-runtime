# Aborted unified acceptance invocation

The orchestrated `final-acceptance.sh all` run began at 2026-11-17 23:53 +08 because Windows PowerShell variables were not exported into the WSL Bash process. The local baseline inventory and T490 read-only precheck completed successfully. HTML, tabs, input, CSS, and stability stages failed while the independent cold02 QEMU session held the shared disk lock or QMP endpoint. No browser-function or stability PASS was recorded. The report stage began at 23:55:43 and the invocation was interrupted before summary generation.

The corrected dry-run, with variables assigned inside WSL Bash, is recorded in `evidence/2026-11-18_wsl2-acceptance-dryrun-r1/`; it ends with `BROWSER_SCORE=NOT_RUN/20` and `ACCEPTANCE_RC=0`.
