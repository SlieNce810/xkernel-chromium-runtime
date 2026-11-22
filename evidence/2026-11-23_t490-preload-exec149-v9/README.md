# Chromium 149 lifecycle sequence v9

This run validates the lifecycle event format after adding an explicit sequence
field. `seq` is the same monotonic timestamp used by the guest clock, so it is
globally ordered across Browser, Zygote, and Renderer fork descendants.

Fourteen recovered events passed the strict `collect_metrics.read_events()`
checks for schema, run ID, clock domain, monotonic sequence, and unique event
ID. The run still lacks a real `renderer_ready` and `first_valid_frame`, so it
is an event and collector diagnostic rather than a formal performance sample.

The reusable console extractor also returns:

```text
LIFECYCLE_VALID run=preload-exec149-v9 events=14
```

Its derived output and summary are kept beside the original evidence.

See [report 487](../../report/487-collector-lifecycle-seq-validation-v9-20261123.md).
