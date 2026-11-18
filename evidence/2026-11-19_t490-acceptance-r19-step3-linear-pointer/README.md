# R19 input round evidence

T490 2 GiB AArch64 pure TCG run. Strict readiness passed at sample 45; JavaScript self-test and keyboard echo passed. The counter remained at 0, the CSS link did not navigate, and Input scored 0/4.

The launcher started just before midnight. `run_input_final.sh` logged its date-18 output path, while `run-session.py` created the date-19 QEMU session directory. The local bundle groups the date-19 session and its temporary input-work directory under one folder. The original PPM frames remain on T490; their per-file hashes are listed in the parent `_ppm-sha256-...txt` file and included in this acceptance folder's SHA-256 chain.

See [report 322](../../report/322-T490-2GiB输入尝试r19两点外推指针落至屏幕外计数与导航失败-20261119.md) for the measured outcome.
