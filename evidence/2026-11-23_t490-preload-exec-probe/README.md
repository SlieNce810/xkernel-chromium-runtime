# T490 preload-exec probe

This evidence bundle was collected on `mo@10.249.11.192` on 2026-11-23.
The complete raw run, including the ten PPM files, remains at:

```text
/home/mo/xk6/evidence/2026-11-23_t490-preload-exec-probe/
```

The repository copy keeps the command, environment, console, page manifest,
timestamps, strict PPM verdict JSON, and PPM summary. Raw PPM files remain on
T490 under the repository's evidence policy; their source hashes are recorded
in the remote `manifest.txt`/`ppm-summary.txt` and can be rechecked against the
original directory.

The run used the 2 GiB AArch64 pure-TCG platform configuration and ended with
`SESSION END (exit=0)`. Ten scheduled screenshot checks returned `result=True`.
The session is diagnostic-only: Browser and one `renderer-observed` process were
seen, but no Chromium `renderer_ready`/`renderer_exec` event was present;
multiple early monitor points reported `MP_RENDERER_COUNT=0`. The guest binary
was the existing Chromium 142 image, not the Chromium 149 build in progress.
It therefore does not count toward the three cold starts, the 30-minute
stability gate, or the four formal performance metrics.

See [report 479](../../report/479-T490-preload-exec-probe-20261123.md) for the
fixed parameters, evidence boundary, and hashes.
