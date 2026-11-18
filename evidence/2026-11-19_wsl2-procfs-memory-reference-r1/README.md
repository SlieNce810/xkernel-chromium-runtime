# WSL2 procfs memory reference probe

A standalone probe exercised anonymous/private-file/shared-file mappings, first touch, fork, private COW in parent and child, and unmap. On WSL2 Linux, `smaps_rollup` exposed RSS, PSS, USS, and shared fields. `/proc/<pid>/statm` and `VmRSS` appeared stale during some early touch phases; the raw values are preserved so the difference can be reviewed.

This is a Linux ABI reference and probe-development result only. It is not a T490 native baseline, x-kernel result, or valid Chromium performance sample. See [report 330](../../report/330-procfs-memory-WSL2-reference-and-T490-followup-20261119.md).
