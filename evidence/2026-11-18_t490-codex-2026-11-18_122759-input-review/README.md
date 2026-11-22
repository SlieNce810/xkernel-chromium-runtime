# R2 source snapshot

`run_input_final.t490-r2.sh` is the exact T490 runner fetched after the failed R2 session. Its SHA-256 is `4b4ae102260a4de997448895bce9b9868928a75a54b95216a1acb1c917a56c09`. It defaulted `ABS_POINTER=1` and did not pass `--force-hmp`; the QEMU session contained `virtio-mouse-pci`, which rejected the absolute `abs` event. The repository runner now defaults to HMP relative mouse movement with no-clamp behavior; keyboard events remain QMP send-key. The JavaScript runner and final acceptance input command use the same setting.

`runner-fix-preflight.txt` and `runner-fix-*` record the post-R2 syntax/help, invalid-mode rejection, no-QEMU check, and fixed-configuration dry-run. They are not runtime PASS evidence; the 2 GiB Input gate still needs a real re-run.
