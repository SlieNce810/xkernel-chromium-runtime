# WSL2 SCM_RIGHTS short-read Linux reference

The focused `compatprobe --scm-rights-shortread` passed 6/6 checks on WSL2 Linux 5.15.167.4: one fd is delivered on the first 1-byte `recvmsg`, not repeated on later 1-byte reads, and all 100 stream bytes are preserved.

This is a Linux reference only. It does not close the T490 native Linux/x-kernel comparison or Chromium Mojo regression. See [report 328](../../report/328-SCM_RIGHTS-stream-shortread-WSL2-Linux基线与T490待补-20261119.md).
