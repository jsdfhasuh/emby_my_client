# STRM 直连诊断实施记录

日期：2026-09-27。实施起点 `83327cb17f1f9c81f384948d56ffe94735944a42`（build 155）。沿用用户授权，在干净的 `emby_my_client_strm_main` 工作区直接修改 main；另一个工作区的七项未提交修改保持不动。没有修改依赖、锁文件、保护基线或扩大 STRM 功能范围。

## 日志链路与事件

`main → DiagnosticLog.initialize → Resolver/API → Bootstrap → SourceHttpInput → MpvSourceInput → Engine → Controller/Reporter` 共用原来的本机日志文件、750 KiB 容量及轮转。字幕仍由原下载器和唯一应用队列处理；没有另建用户不可见的产品调试文件。安全登录诊断 JSONL 保持独立。

`StrmDiagnosticSchema` 定义事件白名单、每个事件的字段、枚举、布尔值和受限整数。任何未知字段/重复字段/非法值都会拒绝整条结构化事件。原生完整导出校验使用同一闭合 schema 的镜像；Dart 测试逐项核对一致性。

| 事件 | 内容 |
|---|---|
| strm_entry | fullscreen / inline 入口 |
| strm_resolve | 开始/完成/失败/取消，分类、固定源、detail/strict/regular 组、兼容次数、实际 HTTP 状态和耗时；最终 `route=source_direct inputMode=stream_cb` |
| strm_input | 输入准备、容器、已知长度、资源头数量 |
| strm_http | DNS 地址族/数量、连接/TLS结果、跳转次数/跨源/剥离结果、Range 验证；不含地址与头值 |
| strm_native | 桥注册、打开命令完成、首次实际交付、输入取消、实际 core 销毁后的桥释放 |
| strm_failure | 白名单 stage/reason、可用 HTTP 状态、failure/request/attempt、取消/过期、恢复资格及实际执行 |
| strm_recovery | 本地重开开始/结束、是否延续上报周期 |
| strm_reporting | Start/Stopped 实际发起、成功完成或失败；发起不表示服务器确认 |
| strm_subtitle | 下载、排队、原生应用完成、迟到、取消/过期、确认和租约释放；下载成功不代表画面显示 |
| strm_summary | 5 秒活动窗口、每个输入关闭一次、逻辑播放终结一次 |

原有 `playback_ready`、字幕及缓存事件继续保留。`native_open succeeded` 表示原生打开命令完成，播放 ready 仍由控制器原有状态机决定；日志不参与控制状态判断。

## 错误传递与恢复

`SourceInputException → SourceInputFailure → MpvSourceInput.onReadFailure → SourceFailureEmitter → Controller` 保留类型和不可变操作身份。首播打开失败携带同一个 failure 对象，重复记录相同状态会合并。受控读取先报告错误，再向 C 回调返回失败，因此后续通用原生错误不能先抢占恢复路径。原生重复失败有计数；恢复资格/执行状态不会被迟到日志清零。切回普通打开清除直连去重状态。

| 原因 | 阶段/恢复策略 |
|---|---|
| source_denied | range_response / 保留 401、403；不作为 Emby 登录过期，不自动恢复 |
| range_unsupported、source_changed | range_response / 不恢复、不换源 |
| truncated | body_read / 仅允许进入既有 seek 时间窗口、次数和同源预算判断；实际获准才记录恢复，绝不转码 |
| dns_failed、connect_failed、tls_certificate | 各自 dns/connect/tls；依据异常类型，状态缺失为 unavailable；不猜测原始文本 |
| timeout、cancelled、unknown | 保守失败/取消；不伪装 I/O 错误申请恢复 |
| redirect_limit、redirect_loop、tls_downgrade、destination | 保留原目的及跳转门槛，不放宽 |
| native_registration、native_policy_option | 原生注册/安全选项失败，打开前终止 |
| subtitle_format、subtitle_budget、subtitle_unconfirmed | 字幕下载/应用阶段，不改唯一应用队列或租约归属 |

未知异常不调用其 toString() 生成诊断 reason，不记录签名 URL、媒体 ID、服务器会话 ID、headers、Cookie、域名或 IP。非 HTTP 错误不虚构 500。所有跨层错误 reason/stage 通过统一白名单验证。

## 匿名关联和计数

每次 Bootstrap 创建随机 64 位十六进制 trace，不使用业务数据或其散列。同源本地重开保留 trace、递增 openAttempt。请求、字幕任务、上报周期各自有局部编号；异步操作捕获本次 trace/attempt，旧任务不会读取新全局播放。新 Bootstrap/账号/条目自然使用新 trace。原生输入和字幕租约迟到释放仍记旧 trace。

- 单调 Stopwatch 测量耗时与活动窗口；不依赖墙钟。
- 原生 4ms 轮询不写日志；read 和数据块只累计。
- 每类成功网络阶段首次记录，跳转状态变化另记；读取汇总最短 5 秒，无新增网络读取时不重复输出。
- `nativeReads`、发起 HTTP 数、跳转、成功 Range、应用层实际收到的 payload 字节、交给 C 的字节、prefix 命中、累计请求耗时、窗口速率分别统计。prefix 再交付不增加网络字节。HTTP 数在实际发起请求时累计，失败 DNS 不算发出 HTTP。
- 网络字节不声称包括 TCP/TLS/HTTP 头开销。没有测到的原生交付/读取字段为 unavailable，不能冒充 0。
- 输入关闭等待其在途读取的逻辑收尾后写一次摘要；逻辑播放最终摘要聚合已关闭输入。超时隔离后的迟到工作不修改已经终结的统计。
- 写入队列新增 256 KiB 上限（文件容量未扩大），超过上限合并计数，排空后记录 `diagnostic_entries_dropped`。写入失败有状态，不抛进播放。读/导出等待调用时已排队的有限快照，不追逐持续新写入。

## 导出与隐私

修复原整行正则中无边界的 `ip/host/url` 等匹配；`event=playback_subtitle_apply_skipped_stale generation=3` 现在能穿过本地写入、读取、完整报告、Dart 验证和原生验证。保留整体敏感信息扫描，已知 event 不享有跳过检查的特权。

本地写入先检查结构化消息是否包含控制字符，再严格解析字段。URL、Token、Cookie、CRLF、编码凭据、未知字段、重复字段、超长/越界值不能借合法 event 混入日志。完整导出再次脱敏并校验摘要；iOS `FullDiagnosticExportValidator` 增加结构化 schema 验证，原分享通道在写入和分享前的验证均保留。未知自由文本仍走原保守脱敏。

用户操作：打开「诊断日志」→「导出完整调试日志」→预览并分享。日志读取失败显示可重试状态，写入失败/队列丢弃显示提示，播放不受影响。测试证据中的固定版本/构建是测试夹具值，正式 IPA 导出仍从原生元数据读取真实版本及构建号。

## 验证及证据

测试通过真实 Resolver、LAN HTTP 输入、锁定 libmpv 回调、Controller、文件日志和完整报告验证接线，而非仅格式化字符串：

- 成功：2,001 次 read，2 次实际 HTTP，网络 payload 263,144 字节、native 交付 33,000 字节、prefix 命中 2,000；阶段日志少于 25 行，输入/播放终结摘要各一次。
- 实际 native Bootstrap：同 trace 串起 strict 协商、打开/首次交付、缓存重开 attempt 2、一次 Start 和最终一次 Stopped。
- 实际 401/403/200/非法 206，DNS lookup 失败、拒绝连接、TLS 不可信证书及降级；原生读取截断保留 body_read/truncated/206，未用原始文本猜测。
- 控制器：截断先到、通用原生错误后到只恢复一次；403/TLS/未知无恢复；取消不把当前播放标成致命失败。
- 文件写失败/抛异常 sink/队列压力不改变成功输入；5 秒汇总、空闲不刷屏、既有轮转/快照测试保留。
- 导出误过滤、注入回归、Dart/Swift schema 镜像、原生 full-export 校验/分享既有测试保留，并新增 STRM 安全字段/注入 XCTest。

验证命令：

```
dart format --output=none --set-exit-if-changed .
flutter analyze --no-pub
flutter test --no-pub --reporter expanded
flutter test --no-pub scripts/diagnostics/probe_strm_controlled_tls.dart
git diff --check
```

TLS 探针现在通过 Flutter 测试运行，以接入实际 DiagnosticLog；设置 `STRM_DIAGNOSTIC_EVIDENCE` 可保存测试文件日志/完整报告/TLS JSON。不设置时测试清理自己的临时文件；产品没有新增明文日志开关。测试目录的实际日志片段随最终交付附件保存，不把示例模板当证据。

本地全量、静态和 TLS 结果，以及最终 SHA 对应的 Android 构建、iOS XCTest/IPA、包校验与 SHA-256，在最终 Actions 和下载目录 DELIVERY.md 记录。提交时不预先宣称尚未执行的 CI 通过。

NOT_RUN：真实 Emby/OpenList 部署、物理 iPad/Android、实际分享面板操作及真实字幕画面。原生/网络夹具不替代设备验收。本轮只完善诊断，不解决之前记录的自动签名 URL 刷新、多容器/分片支持或其他功能审查问题；原 sourceDirectOnly、认证/TLS/目的限制、退出屏障、资源租约和多服务器隔离保留。
