# T490 Chromium 142 official index single-process cold starts

Kernel: a5b6d5ea6ff848253b5ceda07218be7216dfef3f1082c40e38dbefc041a37d76  /home/mo/x-kernel/target/xkmake/kplat-aarch64/release/kernel.bin
Rootfs: bb25e0b298d619a62df06b0ab044750c0885adc2d34602eb0c5875a022aaee09  /home/mo/x-kernel/images/agentos-weston.img
Definition: first 1280x800 screenshot passing official-index strict 7/7.
Run02 passed the pixel gate but its BROWSER_EXEC marker was interleaved by the QEMU monitor, so it is excluded from timing statistics.

|metric|value|
|---|---:|
|valid timing samples|5/6|
|median browser-to-frame (s)|100.467|
|min (s)|100.006|
|max (s)|101.472|
|range (s)|1.466|
