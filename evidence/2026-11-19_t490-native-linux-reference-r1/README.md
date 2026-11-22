# T490 native Linux compatibility and memory reference

The same focused source used for the WSL2 references passed on T490's native Linux 7.0.0-43-generic host: inotify/timerfd 11/11 and SCM_RIGHTS short-read 6/6. The standalone procfs probe exercised anon/file/shared mappings, touch, fork, COW, and unmap and captured RSS/PSS/USS from host Linux.

This is the Linux side of the comparison only. No x-kernel guest or Chromium watcher regression ran in this evidence directory. See [report 331](../../report/331-T490-native-Linux-compat-memory-reference-20261119.md).
