# STRM 直连诊断实施记录

2026-09-28 修订；本轮起点 `ba5ee2774f65610fa6e29c0e6743b6f18016e31c`（build 160）。用户明确修订了此前的地址/业务字段隐藏要求：**本机日志、查看页面和完整调试日志只隐藏认证 Token 值**。这一修订不改变实际播放请求、sourceDirectOnly、目的校验、认证隔离、TLS、跳转上限或生命周期约束。

## Token 处理

统一入口 `TokenRedactor` 供 DiagnosticLog 写入/读取和 FullDiagnosticRedactor 使用。值替换成 `<redacted-token>`，字段名保留。覆盖 token、access_token、AccessToken、X-Emby-Token、认证 api_key、Bearer、X-Emby-Authorization 的 Token 部分，包括 JSON、头值数组、Cookie 内 Token、大小写、重复查询参数、多层百分号编码、JSON 转义和嵌套地址。

解码只生成带原文位置映射的匹配视图；仅替换命中的 Token 范围，不重新生成 URL，因此中文、百分号编码大小写、参数顺序和重复参数保持原样。会话及媒体请求中已识别的 Token 在进程内登记，使异常消息或 Cookie 中无字段名的同一值也能处理；不写入额外文件。

域名、IPv4/IPv6、端口、路径、文件名、媒体 ID、签名参数、session/key 字段、非 Token Cookie、相关头及异常详情保留。不能因含 URL/host/IP 或未知字段整行删除。只处理日志副本，不修改请求 URL、头、响应对象或源快照。

完整报告标记为 `redaction=token-only-v1`。独立的安全登录诊断 JSON 仍保留自己的闭合 schema，不再用它的敏感内容扫描规则限制完整调试日志。

## 接线和字段

继续使用原 DiagnosticLog → 文件轮转 → 查看页面 → FullDiagnosticExportService → iOS 分享通道，无额外地址隐藏开关。

| 事件/阶段 | 实际采集 |
|---|---|
| strm_resolve | 分类、固定源、协商组、请求次数、HTTP/耗时；实际 route=source_direct inputMode=stream_cb |
| strm_detail / metadata | 选中的 MediaSources.Path、itemId/sourceId、RequiredHttpHeaders |
| strm_detail / connect | getUrl 前的实际 raw URL、主机、端口，失败前已记录 |
| strm_detail / dns | lookup 前目标及实际候选地址 |
| strm_detail / connect_attempt | Socket.startConnect 前实际选择的 InternetAddress 与端口 |
| strm_detail / request_headers、response_headers | 实际请求对象的头、响应状态与头 |
| strm_detail / redirect | 原地址、原始 Location、用于下一跳的地址、状态码 |
| strm_detail / 失败阶段 | 原异常类型/消息/栈、可用系统错误码/消息、failure 编号、请求目标/耗时 |
| strm_failure | 原白名单 stage/reason/status、取消/过期、恢复资格及实际执行、去重 |
| strm_native、strm_recovery | 注册/打开/首次交付/释放，本地重开与周期延续 |
| strm_reporting、strm_subtitle | 上报发起/确认/失败，字幕下载/排队/应用/确认/过期/租约释放 |
| strm_summary | 5 秒活动窗口、输入关闭、逻辑播放终结统计 |

计数事件仍用既有枚举。strm_detail 公共字段为 trace、openAttempt、request/task、stage、elapsedMs；details= 后是 JSON，字段定义见 StrmDiagnosticSchema.detailFields。JSON 保留字段边界并转义控制字符，最终经过同一 Token 处理 sink。

SourceInputException 保留原始 cause/stack，原因分类和恢复规则不从原始文本猜测。原生重复错误补记一次原生文本后计数；Controller 的 fingerprint 与处理后的错误详情同时保留。403、TLS、取消、源变化、未知错误不新增恢复。

## 生命周期、频率与容量

- trace 只属于一次逻辑播放，同源本地重开递增 attempt；异步操作保留自己的身份，上报排队前捕获 attempt。
- 原生 4 ms 轮询及每块数据不写文件，仅累加。网络字节与重复交付字节分开，未测得值为 unavailable。
- 同目标的请求/头详情按至少 5 秒窗口采样；DNS/TCP 实际尝试、跳转和首次失败仍记录。错误去重不丢首次详情。
- 文件上限仍 750 KiB、异步队列 256 KiB。单条上限 16 KiB（小容量测试取更小值）；超限保留完整 UTF-8 前缀，标记截断及原字节数。队列过载明确记丢弃计数。
- 写入转义 CR/LF/TAB/控制字符，防止外部文本伪造日志行；查看和导出保留转义文本。读取/导出等待有限快照。
- 写入失败不改变播放；原生资源释放和字幕仍遵守既有屏障、唯一应用通道和租约。

## iOS 与验证

完整导出改用 TokenOnlyDiagnosticValidator：允许地址和错误栈，拒绝未处理 Token，扫描多层编码和多值头。摘要、字节上限、元数据、控制字符及分享前后的文件验证保留。

本轮针对性测试已经通过真实 Resolver、LAN socket、SourceHttpInput、文件日志及完整报告验证：

- 关闭监听端口后真实发起连接，最终报告含源 URL、目标、DNS 候选、尝试地址/端口、耗时、SocketException、系统错误码和调用栈。
- 真实 302 跳转，逐字核对线上请求目标、重复参数、编码（含非 UTF-8 的 `%FF`）和原认证头；仅日志 Token 被替换。凭据登记的解析失败不会影响播放请求；新增测试先复现该边界的 FormatException，再验证修复。
- Token 别名/大小写/重复参数/四层编码、JSON/头数组/Cookie、中文、编码保真、本机和导出一致、控制台无 Token。
- 2,001 次读取不产生逐块日志，保留原频率上界；容量、截断、队列压力、写失败和有限快照回归。
- 新增 iOS XCTest 验证同样的别名、多层编码、多值头，以及地址允许、原 Token 拒绝的完整报告。

命令：

```
dart format --output=none --set-exit-if-changed .
flutter analyze --no-pub
flutter test --no-pub --reporter expanded
flutter test --no-pub scripts/diagnostics/probe_strm_controlled_tls.dart
git diff --check
```

STRM_DIAGNOSTIC_EVIDENCE 只供测试保存本次实际日志与完整报告。测试报告使用合成 build 0，正式产品仍从 Bundle 读取构建号。最终测试数量、CI、提交 SHA、IPA 校验与实际日志节选随最终产物目录 DELIVERY.md 记录，不预先宣称未完成的 CI 通过。

NOT_RUN：真实 Emby/OpenList/CDN、物理 iPad/Android、设备分享面板及真实字幕画面。夹具/模拟器不替代设备验收。此前签名刷新、多容器/分片等限制不因本轮诊断完善而视为解决。

用户入口：「诊断日志」→「导出完整调试日志」。页面说明仅隐藏 Token，完整地址、路径、媒体 ID、相关头和错误栈会保留。
