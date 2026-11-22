# T490 Chromium 149 多进程基线诊断

The raw run, including PPM files, remains on T490 at:

```text
/home/mo/xk6/evidence/2026-11-23_t490-preload-exec149/
```

This run used the 2 GiB `pkg-installed.img` platform and Chromium 149.0.7827.53
(`d7d89bcb…`). Twelve screenshot verdicts returned `result=True`, Browser,
Zygote, and renderer processes were observed, and the session exited cleanly.
The remote autorun was the pre-preload version and recorded `LD_PRELOAD=<unset>`;
no lifecycle-ready event was expected from this run. It is a Chromium 149
multi-process baseline diagnostic, not a formal stability or performance sample.

See [report 481](../../report/481-T490-chromium149-multiprocess-baseline-20261123.md).
