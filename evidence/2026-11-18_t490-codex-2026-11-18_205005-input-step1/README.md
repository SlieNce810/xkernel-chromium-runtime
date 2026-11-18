# R13 step1 请求未传到 T490 runner

R13 启动目录的 `cmd.txt` 和 `launcher.sh` 请求 `INTERACTION_POINTER_MODE=step1`；会话中的 QMP ledger 却记录 `pointer_mode=step4`，因为当时 T490 `run_input_final.sh` 仍把模式写死为 step4。不要将这轮作为 step1 模式的回归结果。

ready 在第 49 次采样通过；JS/Keyboard 子 gate 通过，mouse counter 与 CSS navigation 仍失败。下一轮前必须同步 runner 并比较仓库与 T490 的 SHA-256。

67 张原始 PPM 保存在 T490；仓库只收 PNG 查看副本、判据、完整 console、QMP ledger 与 `_ppm-sha256-2026-11-18_t490-codex-2026-11-18_205005-input-step1.txt` 哈希清单。

详见 [report 316](../../report/316-T490-2GiB输入尝试r13单像素模式未同步仍运行step4-20261118.md)。
