# 基线测量说明（v0.1-first-runnable, f8b9224）

- 内核：af009c42（git_commit f8b92247922fb1127138bbd8830bec504913908f，
  git_describe v0.1-first-runnable）；镜像 bb25e0b2、overlay 56dba17c 与当前版本一致。
- 5 轮结果：single_gate=0、page_assertion=0 各 5 个样本——基线内核下 Chromium
  启动后中止（PulseAudio mutex 断言 + crashpad 缺凭据），页面加载未完成。
  每轮 console.log 与 guest/single-chromium.log 有完整失败现场。
- summary.json 由 raw-core.csv（仅含 5 样本指标）生成；raw.csv 保留全部行。
- 已知瑕疵（如实记录）：第 1 轮 host 观测器产出 peak_qemu_rss_kb/qemu_cpu_percent
  两个单样本指标（round 2-5 因测量脚本 set -e 与 pipefail 交互 bug 丢失观测器），
  仅作上下文，不参与中位数比较；该 bug 已于 10-13 修复（观测器子 shell 入口加
  set +e），当前版本测量轮不受影响。
