# Chromium 149 preload lifecycle v7

This bundle is a Chromium 149.0.7827.53 default multiprocess diagnostic on the
2 GiB T490 platform. The raw PPM files remain on T490:

```text
/home/mo/xk6/evidence/2026-11-23_t490-preload-exec149-v7/
```

The updated autorun streamed lifecycle JSONL incrementally, so the repository
copy includes `lifecycle-events.jsonl` plus the original console. It recovered
Browser preload attach, Browser main-loop ready, five zygote fork boundaries with
request IDs, and a file URL navigation request. Renderer-ready and first-valid-
frame events were still absent; the run is therefore mechanism evidence, not a
formal renderer or performance sample.

See [report 482](../../report/482-T490-chromium149-preload-lifecycle-v7-20261123.md).
