## 18. 实施阶段与提交建议

### C0：计划冻结、真实 libmpv 能力与双门禁

本文件冻结后状态应为 `READY_FOR_OWNER_FREEZE`；精确实施 SHA 仍只写入后续执行提示词和交接报告。

```text
docs: freeze final adaptive playback cache and seek plan
test: verify bundled mpv cache capabilities
```

完成：

- 记录分支/HEAD/upstream；
- 记录受保护文件 blob；
- 实现强类型 property access 和 timeout wrapper；
- 验证 option choices、reset 值和 Profile 切换策略；
- iOS native capability test；
- Android native capability smoke test；
- capability manifest；
- 分别设置 `STOP_GATE_DISK_CACHE_CAPABILITY` 与 `STOP_GATE_SEEK_STABILITY`。

若磁盘能力失败：

```text
STOP_GATE_DISK_CACHE_CAPABILITY = BLOCKED
```

但不得停止整个任务。继续完成 C1、C3 的内存 Profile、C4、C6 的 Seek/recovery、C7 和 C8。只有磁盘相关的正式能力声明保持 blocked。

### C1：设置 Repository 与迁移

```text
refactor: serialize playback settings updates
refactor: model adaptive playback cache settings
```

必须包含 clear/delete-account generation，证明旧 patch 不会在清理后复活。

### C2：安全缓存 session 与存储探测

```text
feat: prepare safe playback cache sessions
```

磁盘门禁 blocked 时，代码仍可实现和测试，但生产默认不得启用磁盘 Profile。

### C3：媒体资格、动态 Profile 与 metadata 内存预算

```text
feat: resolve media-aware playback cache profiles
```

必须关闭高码率最小时长冲突、独立前向/后向 metadata 映射、总 metadata cap 和 memory-pressure 策略。

### C4：稳定 Session、Seek 与两层操作协调器

```text
fix: serialize seek and playback session operations
```

先完成：

- PlaybackItemSessionId；
- automatic open 总预算；
- single-flight/latest-wins；
- absolute/relative 语义；
- SeekResult；
- operation timeout；
- shutdown 强制退出；
- recoveryPending/recovering 状态。

该阶段与磁盘缓存能力独立，是本轮必须完成的阻塞修复。

### C5：mpv 完整 Profile、切换策略与 native telemetry

```text
feat: configure and observe media kit playback cache
```

- `inPlaceAfterMediaStop` 时在同一 Player 完整重置；
- `requiresPlayerRecreation` 时由 PlayerSessionCoordinator 重建；
- `unsupported` 时生产降级内存；
- 缓存创建失败后验证 actual mode，不得直接伪称 memory fallback。

### C6：预算、低空间、内存压力与有界恢复

```text
fix: enforce cache safety and bounded playback recovery
```

包括提前 low-space guard、每 Session 一次安全重开、恢复窗口、稳定播放窗口、open 总预算和 reporter 事务。

### C7：设置、播放器状态与验收测试控制

```text
feat: expose adaptive playback cache controls
feat: add ephemeral playback acceptance overrides
```

Test Overrides 只能位于诊断页，重启/退出登录后自动清除。

### C8：诊断、压力测试与最终回归

```text
test: close adaptive cache and seek resilience gates
```

C8 只补遗漏和回归，不新增范围外功能。

每个生产提交必须同时包含对应测试，并可独立审查。

---

## 19. 本地与 CI 门禁

每个阶段至少运行：

```text
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
git diff --check
```

涉及 iOS 脚本：

```text
for file in scripts/ios/*.sh; do bash -n "$file"; done
shellcheck scripts/ios/*.sh
```

最终：

```text
flutter build apk --debug
flutter build apk --debug --split-per-abi
```

Actions 必须继续通过：

- Flutter tests；
- Swift XCTest；
- capability native tests；
- 负向 entitlement 门禁；
- 锁文件门禁；
- IPA checksum；
- 受保护文件零差异。

### 19.1 性能与终止门禁

- 100 个 Seek 请求不得触发 100 次 engine.seek；
- engine.seek 最大并发始终为 1；
- cache state 采样不得导致每秒整页重建；
- 每次 snapshot 只更新必要 ValueNotifier/state slice；
- 完成播放后无持续 Timer/native property poll；
- route close 后无网络恢复请求；
- 100 次打开/关闭后无 cache session、Timer、StreamSubscription 和 pending Future 残留；
- native property、Seek、stop、dispose、reporter 和 cleanup 的 timeout 测试必须证明路由可退出；
- automaticOpenCount 永不超过 6；
- clear/delete-account 后旧设置 patch 不得重新写入。

---

## 20. 新 Actions A/B 与门禁状态

由于代码 HEAD 会变化，Run 68/69 保留为历史候选。

完成所有代码和本地门禁后：

1. 记录新的 `implementation_code_head`；
2. 推送当前功能分支；
3. 等待自动 Run A 完整成功；
4. Run A 未结束前不得触发 Run B；
5. Run A 后不得再产生提交；
6. 对同一 HEAD 执行一次 workflow_dispatch；
7. 等待 Run B 完整结束；
8. 核验 A/B `head_sha` 完全相同；
9. 核验 Run B build > Run A；
10. 核验五类 Artifact、checksum、arm64、iPad-only、entitlement、签名顺序和锁文件。

Seek 自动化完成后：

```text
AUTOMATED_SEEK_STABILITY_GATE = PASSED
STOP_GATE_SEEK_STABILITY = WAITING_FOR_DEVICE_OWNER
```

磁盘能力通过时：

```text
STOP_GATE_DISK_CACHE_CAPABILITY = PASSED
STOP_GATE_B = WAITING_FOR_DEVICE_OWNER
```

磁盘能力 blocked 时：

```text
STOP_GATE_DISK_CACHE_CAPABILITY = BLOCKED
STOP_GATE_B = BLOCKED_BY_DISK_CACHE_CAPABILITY
STOP_GATE_SEEK_STABILITY = WAITING_FOR_DEVICE_OWNER
```

此时可以真机验证 Seek/内存缓存修复，但不得宣称完整磁盘缓存计划或完整 Gate B 已通过。两个门禁不得互相覆盖。

通用状态仍为：

```text
IMPLEMENTATION_IN_PROGRESS
NOT_ACCEPTED
evidence_doc_head = NOT_CREATED
```

不得进入 `LEGACY_IOS_PHASE_8`。

---

## 21. 真机验收

### 21.1 安全验收测试控制

开始真机测试前，在诊断页进入：

```text
播放验收测试
```

验证可以一次性设置：

- stream-buffer-size；
- 小会话目标；
- simulated storage snapshot；
- 下一次 executed Seek 后注入批准 fingerprint；
- 清除全部覆盖。

硬要求：

- 普通设置页不可见；
- UI 明确显示“测试覆盖已启用”；
- 覆盖不写入正常账号设置；
- 应用重启后全部清除；
- 退出登录/切换账号后全部清除；
- 正式验收结束前必须执行“清除全部测试覆盖”。

### 21.2 Run A：全新安装

1. 校验 IPA checksum；
2. TrollStore 全新安装；
3. 查看运行时 mpv capability manifest 和 Profile switch strategy；
4. 打开与 Build 56 故障同类的 DirectPlay MP4；
5. 确认 `Failed to create file cache` 不再反复出现；若出现，确认 actual mode 为 disk / memoryFallback / unconfirmed 中的真实状态；
6. 磁盘能力通过时确认磁盘缓存 actual mode 和本次目标可见；
7. 确认实际前向/后向范围可见或明确显示暂不可用；
8. 连续执行 100 次前进/后退 Seek 压力；
9. 验证播放器不退出；
10. 验证最终位置为最后目标；
11. 验证短距离回退可在 seekable range 内完成；
12. 验证设置自动、仅内存、平衡和自定义；
13. 使用小 session target 验证一次“正在调整缓存…”；
14. 使用 simulated storage 验证 low-space 提前保护；
15. 使用批准 fingerprint 注入验证 recoveryPending → recovering → ready/failed；
16. 验证退出后 session 目录清理；
17. 验证方向恢复、音轨、字幕、亮度和音量；
18. 清除全部 Test Overrides；
19. 重启应用确认覆盖已经自动清除；
20. 导出完整诊断并检查没有敏感数据。

### 21.3 stream-buffer-size 真机实验

通过一次性 Test Override，对同一测试 MP4、相同网络条件比较：

```text
128 KiB
512 KiB
1 MiB
2 MiB
```

记录：

- 启动耗时；
- 100 Seek 成功率；
- partial file / I/O error；
- CPU/卡顿主观观察；
- 最终选择值。

没有证据时保持 128 KiB。实验结束后必须清除覆盖。

### 21.4 Run B：覆盖安装

不退出、不卸载、不清数据：

- Session/Keychain 保留；
- cache settings 保留；
- Repository revision 正常；
- 旧 v1 JSON 迁移稳定；
- 播放、Seek、缓存和诊断回归；
- 无 stale cache session；
- 覆盖安装后能力 manifest 一致；
- Test Overrides 不应跨安装意外启用。

### 21.5 Owner 记录字段

```text
DISK_CACHE_CAPABILITY_GATE = PASS / BLOCKED / FAIL
SEEK_STABILITY_GATE = PASS / FAIL
PROFILE_SWITCH_STRATEGY = IN_PLACE / RECREATE / UNSUPPORTED
CACHE_DIRECTORY = PASS / FAIL / NOT_APPLICABLE
ACTUAL_CACHE_MODE = DISK / MEMORY / UNCONFIRMED / NOT_APPLICABLE
FILE_CACHE_BYTES = PASS / FAIL / UNAVAILABLE / NOT_APPLICABLE
SEEKABLE_RANGES = PASS / FAIL / UNAVAILABLE / NOT_APPLICABLE
FORWARD_CACHE_TARGET = PASS / FAIL / NOT_APPLICABLE
BACKWARD_CACHE_ACTUAL = PASS / FAIL / NOT_APPLICABLE
CUSTOM_TARGET = PASS / FAIL
SEEK_STRESS_100 = PASS / FAIL
PARTIAL_FILE_RECOVERY = PASS / FAIL / INJECTION_PASS / NOT_TRIGGERED
CACHE_BUDGET_FALLBACK = PASS / FAIL / NOT_APPLICABLE
LOW_SPACE_PROTECTION = PASS / FAIL / SIMULATION_PASS / NOT_TESTED
CACHE_CLEANUP = PASS / FAIL / NOT_APPLICABLE
TEST_OVERRIDE_RESET = PASS / FAIL
RUN_B_SETTINGS_CONTINUITY = PASS / FAIL
POST_PLAYBACK_ORIENTATION_RESTORE = PASS / FAIL
```

### 21.6 Gate 分类

| 项目 | 类型 | 允许通过状态 |
|---|---|---|
| `SEEK_STRESS_100` | Seek 硬门禁 | `PASS` |
| `SEEK_STABILITY_GATE` | Seek 硬门禁 | `PASS` |
| `TEST_OVERRIDE_RESET` | 安全硬门禁 | `PASS` |
| `RUN_B_SETTINGS_CONTINUITY` | 升级硬门禁 | `PASS` |
| `POST_PLAYBACK_ORIENTATION_RESTORE` | 既有硬门禁 | `PASS` |
| `PARTIAL_FILE_RECOVERY` | 条件门禁 | 真机 `PASS`，或安全故障注入 `INJECTION_PASS` |
| `LOW_SPACE_PROTECTION` | 条件门禁 | 真机 `PASS`，或安全模拟 `SIMULATION_PASS` |
| `DISK_CACHE_CAPABILITY_GATE` | 磁盘功能硬门禁 | 完整磁盘缓存计划必须 `PASS` |
| `ACTUAL_CACHE_MODE` | 磁盘功能硬门禁 | 声称磁盘启用时必须 `DISK`，不得 `UNCONFIRMED` |
| `FILE_CACHE_BYTES` | 磁盘功能硬门禁 | 声称动态磁盘预算时必须 `PASS` |
| `SEEKABLE_RANGES` | 磁盘功能硬门禁 | 声称实际范围可见时必须 `PASS` |
| `CACHE_BUDGET_FALLBACK` | 磁盘功能硬门禁 | 磁盘功能启用时必须 `PASS` |
| `CACHE_CLEANUP` | 磁盘功能硬门禁 | 磁盘功能启用时必须 `PASS` |

判定：

```text
所有 Seek 硬门禁和条件门禁通过
→ STOP_GATE_SEEK_STABILITY = PASSED
```

只有：

```text
STOP_GATE_SEEK_STABILITY = PASSED
且 STOP_GATE_DISK_CACHE_CAPABILITY = PASSED
且所有磁盘功能硬门禁通过
```

才允许：

```text
STOP_GATE_B = PASSED
```

若磁盘能力为 `BLOCKED`，Seek Gate 可以单独 PASSED，但完整 `STOP_GATE_B` 仍不得通过。

仍不得自动写：

```text
IMPLEMENTATION_COMPLETE
ACCEPTED
```

---

## 22. 最终交付目标

普通用户：

```text
默认自动缓存
→ 根据设备空间选择安全档位
→ 根据码率缩短实际目标
→ 前向和后向目标可设置
→ 实际可回退范围可见
→ 磁盘不可用时自动降级
→ 空间不足时受控切换内存
→ 退出视频后缓存释放
```

连续 Seek：

```text
用户快速滑动很多次
→ UI 持续更新预览
→ engine.seek 最大并发始终为 1
→ 中间目标自动合并
→ 相对 Seek 正确累积
→ 最终停在最后目标
→ 旧 Future 不覆盖新状态
→ Seek 后可恢复 I/O 错误只恢复一次
→ 不再因 partial file 直接退出播放器
```

设置一致性：

```text
设置页修改 cache
播放器修改倍速/字幕/码率
→ 所有字段均通过 Repository patch 保留
→ clear/delete-account 后旧 patch 不会复活
→ 不发生旧快照覆盖
```

门禁独立性：

```text
磁盘能力不足
→ 仍交付 Seek single-flight、内存缓存、超时退出和有界恢复
→ Seek Gate 可以单独完成真机验收
→ 但完整磁盘缓存能力与 STOP_GATE_B 继续 blocked

磁盘能力通过
→ actual mode、file-cache-bytes、seekable-ranges、预算降级和 cleanup 均通过后
→ 才允许完整 Gate B 通过
```

任何 `actual runtime mode = unconfirmed` 都不得作为“磁盘缓存已启用”的成功证据。

最终边界：

```text
未修改或合并 main
未提交 docs/test/
未升级依赖
未实现持久化媒体缓存
未实现本地 Range 代理
未代填真机 PASS
未进入 LEGACY_IOS_PHASE_8
未声明 IMPLEMENTATION_COMPLETE
未声明 ACCEPTED
```

---

## 23. 技术依据

本计划的 mpv 约束依据当前稳定版 mpv 手册中的：

```text
cache-on-disk
demuxer-cache-dir
demuxer-cache-unlink-files
demuxer-cache-state
file-cache-bytes
seekable-ranges
raw-input-rate
demuxer-max-back-bytes
demuxer-seekable-cache
stream-buffer-size
```

仓库当前锁定：

```text
media_kit 1.2.6
media_kit_video 2.0.1
media_kit_libs_video 1.0.7
```

因此 C0 必须以当前实际捆绑二进制为权威，最新手册仅作为候选能力和语义依据。
