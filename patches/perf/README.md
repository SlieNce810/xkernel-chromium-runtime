# Performance diagnostic patches

- `procfs-tree-rollup-timing.patch` adds compact guest-monotonic timing fields to the existing process-tree `smaps_rollup` endpoint. It reports the all-process resident-page walk, PFN mapcount pass, PSS/USS rollup, response formatting, total endpoint time, all-process snapshot counts, and resident-page count. The patch was built and exercised in the R21 T490 diagnostic run; it does not establish a formal performance result.
- The `process_count` value describes the all-process mapcount snapshot input, not the Chromium process-tree row count. `resident_pages` counts resident user mappings, including repeated shared-frame mappings. `sample_work_ns` stops before CSV row emission and flush; the sampler's overrun/error log records the end-to-end schedule misses separately.
- Reproduction requires the procfs tree-rollup endpoint and dense PFN mapcount changes recorded under `patches/compat/`, then this timing patch, on the T490 kernel worktree.
