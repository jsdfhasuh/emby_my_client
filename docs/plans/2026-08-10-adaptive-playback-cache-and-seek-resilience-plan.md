# 2026-08-10 自适应播放缓存与连续 Seek 稳定性整改计划（权威索引）

> 本文件是本轮整改计划的固定入口。由于计划正文较长，仓库内按章节拆分为 5 个连续部分；拆分仅用于 GitHub 传输与审阅，不改变正文内容、章节顺序或权威性。
>
> **执行者必须先阅读本索引，再按编号顺序完整阅读全部 5 个部分。任何部分都不是可选内容。**
>
> 5 个正文文件保留了最终计划的全部文字和顺序。物理拆分时，前 4 个文件各省略了原单文件在分界处额外保留的 1 个空白换行；这不改变 Markdown 语义。需要字节级还原原始单文件时，按以下规则拼接：
>
> ```text
> part1 + LF + part2 + LF + part3 + LF + part4 + LF + part5
> ```
>
> 还原后元数据：
>
> - 原始正文行数：2,991
> - 原始 UTF-8 字节数：78,619
> - 原始正文 SHA-256：`f32b997fcfd27cc0af3af01ffeb071690ecc52b7e34193e784a39842ca43aac0`

```text
plan_status = READY_FOR_OWNER_FREEZE
repository = jsdfhasuh/emby_my_client
implementation_branch = agent/ios-core-real-device-remediation
code_baseline = 66232fc4ff8cf1f71068322abf67a69cf82a687d
implementation_start_head = BRANCH_HEAD_AFTER_PLAN_FREEZE

STOP_GATE_B = BLOCKED_BY_RUNTIME_PLAYBACK_DEFECT
STOP_GATE_DISK_CACHE_CAPABILITY = NOT_RUN
STOP_GATE_SEEK_STABILITY = BLOCKED_BY_IMPLEMENTATION
IMPLEMENTATION_IN_PROGRESS
NOT_ACCEPTED
evidence_doc_head = NOT_CREATED
```

## 正文阅读顺序

1. [状态、故障证据、边界与 libmpv 能力门禁](2026-08-10-adaptive-playback-cache-and-seek-resilience-plan/01-status-evidence-capability.md)
2. [设置 Repository、缓存目录、设置 UI 与动态 Profile](2026-08-10-adaptive-playback-cache-and-seek-resilience-plan/02-settings-storage-profile.md)
3. [Engine Profile、状态监控、双层协调器与 Seek 调度](2026-08-10-adaptive-playback-cache-and-seek-resilience-plan/03-engine-monitoring-seek.md)
4. [运行时恢复、播放器集成、诊断与自动测试矩阵](2026-08-10-adaptive-playback-cache-and-seek-resilience-plan/04-recovery-integration-tests.md)
5. [实施阶段、CI、Actions A/B、真机 Gate 与最终边界](2026-08-10-adaptive-playback-cache-and-seek-resilience-plan/05-implementation-actions-gates.md)

## 权威性规则

- 本索引与上述 5 个文件共同构成唯一权威计划。
- 章节编号沿用原始正文；不得因物理拆分而重新解释阶段、门禁或优先级。
- 若索引摘要与正文冲突，以对应正文为准。
- 实施提示词必须固定“计划提交后的精确分支 HEAD”，不得回退到 `code_baseline`。
- 不得只实施缓存参数而跳过 Seek 调度、超时、恢复、设置并发、能力探测或 Gate B。
- 不得进入 `LEGACY_IOS_PHASE_8`，不得修改或合并 `main`，不得代填真机 PASS。
