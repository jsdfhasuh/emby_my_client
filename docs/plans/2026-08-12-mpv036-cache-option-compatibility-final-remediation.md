# 2026-08-12 mpv 0.36 缓存兼容、运行证据与跨来源 Seek 收口计划（Luna Max 权威索引）

> 本文件是本轮实施的唯一入口。设备所有者已对基础计划完成最后一轮 Luna Max 加固。
>
> **执行者必须按顺序完整阅读下列两份正文。第二份加固文档对第一份中冲突、含糊或不完整的条款具有覆盖效力；没有冲突的基础条款继续有效。任何一份都不是可选内容。**

```text
plan_status = READY_FOR_LUNA_MAX_IMPLEMENTATION
repository = jsdfhasuh/emby_my_client
implementation_branch = agent/ios-core-real-device-remediation
code_baseline = 705b1e0fab7b0d25d8372fa0cbcb1cf0bade9988
base_plan_commit = 556025d08c875eb8237ac2c17f4c3714907529c5
implementation_start_head = BRANCH_HEAD_AFTER_THIS_HARDENING_COMMIT

AUTOMATED_SEEK_STABILITY_GATE = PASSED
STOP_GATE_SEEK_STABILITY = WAITING_FOR_DEVICE_OWNER
STOP_GATE_CACHE_OPTION_BINDING_IMPLEMENTATION = BLOCKED_BY_IMPLEMENTATION
STOP_GATE_MEMORY_CACHE_PROFILE = BLOCKED_BY_IMPLEMENTATION
STOP_GATE_ACTIVE_CONTEXT_TELEMETRY_READER = BLOCKED_BY_IMPLEMENTATION
STOP_GATE_DISK_TELEMETRY_EVIDENCE = BLOCKED_BY_IMPLEMENTATION
STOP_GATE_CACHE_LOG_OBSERVATION = BLOCKED_BY_IMPLEMENTATION
STOP_GATE_CACHE_SESSION_SUMMARY = BLOCKED_BY_IMPLEMENTATION
STOP_GATE_DISK_CACHE_CAPABILITY = NOT_RUN
STOP_GATE_B = BLOCKED_BY_IMPLEMENTATION
IMPLEMENTATION_IN_PROGRESS
NOT_ACCEPTED
evidence_doc_head = NOT_CREATED
```

## 权威阅读顺序

1. [基础计划 v1](2026-08-12-mpv036-cache-option-compatibility-final-remediation/00-base-plan-v1.md)
2. [Luna Max 最终加固与覆盖条款](2026-08-12-mpv036-cache-option-compatibility-final-remediation/01-luna-max-hardening.md)

## 实施起点规则

本文档不写入自引用提交 SHA。计划提交并推送后，后续实施提示词必须写死当时远端分支的精确 HEAD，并先执行实时远端核验、`git fetch` 与 `--ff-only` 同步。

执行者不得仅凭本地过期的 `@{upstream}` 判断远端缺少计划提交。

第一个生产代码提交的 parent 必须精确等于实施提示词中的 `implementation_start_head`。

## 被替换的旧门禁名称

基础计划中的以下名称不再使用：

```text
STOP_GATE_CACHE_OPTION_ALIAS
STOP_GATE_CACHE_TELEMETRY
```

它们被拆分为：

```text
STOP_GATE_CACHE_OPTION_BINDING_IMPLEMENTATION
STOP_GATE_DISK_CACHE_CAPABILITY
STOP_GATE_ACTIVE_CONTEXT_TELEMETRY_READER
STOP_GATE_DISK_TELEMETRY_EVIDENCE
```

不得在最终报告中同时输出新旧门禁，避免 PASS/BLOCKED 语义冲突。

## 权威性与边界

- 加固文档明确关闭 Alias 选择、原生值等价、活动 mpv context、确定性 CI 夹具、Gate 语义、Observation 节流及 Session Summary 聚合等剩余歧义。
- 基础计划中未被覆盖的 Git 安全、受保护文件、范围边界、现有 Seek 架构、测试基线、Actions A/B 与真机 Gate 条款继续有效。
- 不得推倒已经通过的 Seek single-flight/latest-wins、PlaybackItemSessionId、有界恢复、设置 Repository、缓存目录安全和动态缓存策略。
- 不得修改或合并 `main`，不得提交 `docs/test/`，不得升级依赖，不能代填真机 PASS。
- 完成全部生产代码、测试和同一新 HEAD 的 Actions A/B 前，不得声明 `IMPLEMENTATION_COMPLETE` 或 `ACCEPTED`。
