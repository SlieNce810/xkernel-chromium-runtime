# WSL2 inotify/timerfd Linux reference

The focused compatibility probe passed 11/11 checks on WSL2 Linux 5.15.167.4. This is a host-side Linux reference; it does not close the T490 native Linux or frozen-hash x-kernel comparison, nor the Chromium watcher page regression.

The full legacy `compatprobe` run is retained separately and has one MADV_DONTNEED-over-hole expectation mismatch on this WSL kernel. See [report 327](../../report/327-inotify-timerfd-WSL2-Linux基线与T490待补-20261119.md) before interpreting it.
