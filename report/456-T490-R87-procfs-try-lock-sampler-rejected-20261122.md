# T490 R87 procfs try-lock sampler candidate rejected（2026-11-22）

R87 tested a procfs candidate that exposed a non-blocking address-space lock and retried bulk tree snapshots five times. It reduced the observed resident-walk median to about 171 ms, but increased unavailable/incomplete samples.

- Evidence: evidence/2026-11-22_t490-r87-perf-after-r4/
- Memory export: complete and hash verified, but sampler invalid;
- Errors: 328 memory/tree errors, including 108 bulk-unavailable and 87 overrun;
- Sampler result: FAIL, no valid four-metric sample admitted;
- Candidate source was removed from the T490 worktree afterward;
- Base procfs source path was restored.

This candidate is retained as a rejected optimization experiment and is not part of the final version.

