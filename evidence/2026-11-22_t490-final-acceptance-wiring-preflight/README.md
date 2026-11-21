# Unified acceptance entry preflight

The updated `scripts/final-acceptance.sh` passed remote `bash -n`, `--help`, a safe `all` dry-run and a focused stability-stage dry-run. The stability command includes the selected `T490_KERNEL_DIR` and forwards `T490_EXPECTED_KERNEL_SHA256` to the runner. A malformed hash (`bad`) was rejected before the remote command could run.

The all-stage dry-run returned `ACCEPTANCE_RC=0` and expanded baseline, precheck, six score items, stability, perf and report commands. Its `BROWSER_SCORE=NOT_RUN/20` is intentional; dry-run results do not represent browser or performance PASS. No QEMU process was started. See `all-stage/`, `stability-stage/` and `invalid-hash-rejection.log` for full output.
