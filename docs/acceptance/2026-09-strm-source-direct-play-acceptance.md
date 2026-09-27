# STRM 源站直连实施与验收记录

日期：2026-09-27。唯一设计依据：`docs/plans/2026-09-26-strm-source-direct-play-plan.md` v3。

**IMPLEMENTATION_STATUS=RUNTIME_IMPLEMENTED / PLATFORM_VALIDATION_PENDING**

本轮已把 STRM 接到实际播放链路：Bootstrap → 严格 Emby 元数据协商 →
受控 Range 输入 → libmpv 自定义流 → 解码、seek、续播。不是替换 source.path，
也不再走旧 Emby 视频路径。Windows 锁定原生库已验证实际解码、seek、续播、
外挂字幕实际 sid，以及缓存重开前后 Start/Stopped 各一次。
平台 CI 结果与最终 IPA 的 SHA、校验值由对应提交的 Actions/交付报告记录；
不能把本文件提交时尚未执行的移动端测试写成通过。

## 工作区与历史

- 当前用户明确授权直接在 main 修改、提交、普通推送和构建 IPA；替代旧分支限制。
- 工作区：`C:/Users/jsdfhasuh/my_scripts/emby_my_client_strm_main`，main 跟踪 origin/main。
- 本轮实际开发起点：`6131663eaf13e3033137a6c1f6bbd13ee89c5356`，保留此前基础改动。
- 最早计划起点 cf65dc1，固定源码基线 ab530365；此前只有计划差异。
- 原工作区仍为 wip/full-diagnostic-export-20260827 / f80546d；七项无关改动未动。
- 无适用 AGENTS.md。没有升级依赖、改写锁文件/保护基线、引入视频代理或更换播放器。
- 旧构建 run 152 / 6131663 是基础 IPA，不是本轮直连交付物。

## P0：机制、版本和原生证据

| 层/平台 | 锁定版本 | 当前执行机制 |
|---|---|---|
| Flutter / Dart | 3.38.9 / 67323de285b00232883f53b84095eb72be97d35c；Dart 3.10.8 | 原始 path/query 经 OpaqueHttpUri 写实际 HTTP request line |
| media_kit | 1.2.6；video 2.0.1；libs_video 1.0.7 | 同一个 Player/VideoController，受跟踪的 loadfile；不传源 URL 到 Media |
| Windows | libs_windows_video 1.0.11；mpv 0.36.0-403-g652a1dd907 / FFmpeg 6.0 | 实际 stream_cb + Dart Range 网络 + 原生解码 |
| iOS | libs_ios_video 1.1.4 / libmpv-darwin-build v0.6.0；mpv 0.36.0 / FFmpeg 6.0 | Runner 编译同一 C 桥；进程 FFI；新增模拟器原生视频解码/seek/重开 XCTest |
| Android | libs_android_video 1.3.8 / native v1.1.7；FFmpeg 6.0 | app CMake 打包每 ABI libstrm_input.so；不重编 mpv/FFmpeg |
| Linux CI | 既有 ubuntu-24.04 libmpv-dev | 编译同一 C 桥运行全部 Flutter/原生测试；不冒充移动端版本 |

Windows 锁定 DLL SHA256：
`d5f0694b08c124e785d858d00082f3e3b158dd9138bfc48c0382bf1eb443a5fc`。
C 验证编译器 Zig 0.13.0 仅作主机测试工具；未变更 app 工具链。

旧直接 FFmpeg HTTP 的反例保留在 `evidence/strm-windows-native-probe.json`：
跨 origin 仍转发自定义 Authorization，允许六跳，media_kit 规范化 URL。
该路径仍 **unsupported**，不能用旧探针退出成功声明安全支持。
本轮替代方案是已存在的 `mpv_stream_cb_add_ro`，没有本地视频代理或通用网络内核重写。

`native/strm_input.c` 在原生读取线程等待有界事件；Dart 非阻塞轮询后提供最多 256 KiB。
每一次实际 Range 都重新验证目的、DNS 结果及认证范围；最多五跳，拒绝 HTTPS 降级，
跨 origin 后剥离所有资源头。独立 HttpClient 不保存/复用 Emby Cookie jar。
HTTPS 在已验证 IP 的 socket 上使用原始主机名执行证书校验和 SNI。
libmpv 只看到 `embyinput://整数`；C 复制缓冲区，不保存 Dart/原生调用方读缓冲指针。
取消唤醒原生；仅在真正 Player.dispose 完成后释放 context。

已失败并修正的方案：media_kit.open 的临时 playlist 被 access-references/安全协议限制
拒绝。没有启用 load-unsafe-playlists；改为同一个 Player 内受跟踪 loadfile。
强制视频 demuxer 会干扰外挂字幕，现于唯一字幕操作中临时使用已验证文本格式，
完成后恢复；保持 protocol_whitelist=none。原生 sid/track-list 不确认则不报成功。

| 能力/组合 | Windows 实际运行 | iOS / Android 提交时状态 |
|---|---|---|
| 原始签名、重复键、大小写编码、上游 api_key | tested：原始 socket request line | unverified：待 CI/目标端 |
| OpenList 风格 302 + 重复 Range + 原生解码/seek/续播 | tested：真实 HTTP、两个 LAN origin、生成 AVI | iOS 原生桥 XCTest 已加入；实际 Dart 网络/设备 NOT_RUN |
| 跨 origin 头隔离、最多五跳、回环目的拒绝、取消 | tested：真实 HTTP，不是 HEAD/fake | 相同实现，目标端网络 NOT_RUN |
| 外挂 SRT 实际选中和关闭 sid | tested：锁定 Windows libmpv | NOT_RUN（实机轨道/画面） |
| HTTPS 证书/SNI/降级 | tested：独立 TLS 夹具验证证书拒绝、可信证书 Range、降级前阻断；DNS 名 SNI 样本 NOT_RUN | NOT_RUN |
| MP4/MKV/AVI/188-byte TS 有限渐进媒体 | sniff/格式约束已实现；AVI 实际解码 tested，其他格式 unverified | 待平台与真实样本 |
| 无 Range 206、未知总长度、其他容器 | unsupported：明确失败，不能转 Emby | 同一限制 |
| HLS/DASH/外部引用/分片/密钥 | unsupported：不交给不受控网络；禁外部引用和协议 | 同一限制 |
| 真实 Emby/OpenList、物理 iPad/Android | NOT_RUN：无目标服务/设备 | NOT_RUN |

## P1/P2 实际实现

- `resolveOnlinePlayback` 是共用在线入口：源级三态分类、正向普通证据、固定 source ID，
  详情最多一次、严格组最多三次、普通组最多三次、整体 30 秒和取消。
  已确认 STRM 的首次请求就禁止 DirectStream/Transcoding/AutoOpenLiveStream；
  unknown 不授权普通组；普通响应新出现 STRM 证据后保持同 ID 进入严格组。
- 请求快照绑定 ServerScope/API 对象/item/source/播放任务代次，URL/headers/元数据
  整体替换。API dispose 后快照不能再次读取。源 URL 不经 Emby 参数重写。
- 全屏和内嵌都走 PlaybackSessionBootstrap。SourceDirectPlaybackEngine 用自定义输入；
  禁止首播失败、音轨/码率动作、恢复及缓存重开回退 Emby 视频。UI 标识“源站直连”，
  禁用该路由的服务器码率动作；仍保留鉴权媒体信息、上报、Trickplay 和字幕请求。
- 源快照、本地 native input/open 实例和 reporting cycle 分开：同源本地重开复用快照，
  不再次 activate、不产生中间 Stopped；最终一次停止。真实原生测试核对网络请求序列。
- reporter 每周期 Start 只尝试一次，Progress/Stopped 有序；新 Start 等旧实际退场。
  调用方等待超时不释放 HTTP 退场屏障；视频准备的 Start 等待有界。
- 跨版本第一次请求没有旧显式数字轨道；预检失败保留旧播放。TrackMapper 只采纳正向
  匹配证据；不得凭数字相等。当前已应用轨道用于上报，旧字幕完成不覆盖新音轨。
- 新字幕 loader 只下载/管理文件；现有状态机和每引擎唯一队列控制实际应用。
  首播不等外挂字幕网络；15 秒、五跳、10 MiB 实际解压字节、32 MiB 文件+在途预留。
  第三方 URL 保真且没有 Emby 头；只有匹配的 Emby 字幕端点授权，跳转重新核对。
- 文件 .part 完成后发布；交原生前挂租约；取消等待不删仍在使用的文件。
  真正引擎销毁才释放已挂租约。旧原生字幕未完成，新媒体 open 等实际完成，不能越过。
  无法确认 sid/external-filename 不显示成功。

## 测试矩阵映射和剩余边界

| 计划行 | 证据/状态 |
|---|---|
| A01/A06/A07，B01/B05/B13/B18 | `strm_custom_input_native_test`：真实 Bootstrap、strict flags、paused resume、无 Emby 视频请求、实际解码/seek、同周期缓存重开 |
| A02/A03/A04/A17/A18/A19 | `strm_online_resolver_test` + policy/API：普通 A 与 STRM B、响应重排、A 消失不切 B、普通证据变 STRM、unknown 拒绝普通组 |
| A05/A09/A10/A11/A12/A13/A14/A15/A16/A20 | `strm_api_snapshot_test`、`strm_direct_play_policy_test` 和在线入口测试；真实服务错误/意外资源行为仍 NOT_RUN |
| B02/B03/B04/B09/B21/B22 | TrackMapper、controller 与普通音轨/字幕/切源回归；新版本请求清旧索引、预检失败不动旧视频 |
| B07/B08/B10/B11/B23/B24 | 新 loader 真实 socket 测试；controller B23 使用真实下载文件，fake 在 native A 完成时改变实际状态，最新 off 生效，无双载、退出释放文件 |
| B14/B15 | identity/API + source sessionActive + 多服务器既有回归；真实双服务器运行 NOT_RUN |
| B16/B25 | 既有 native timeout/retirement、唯一队列阻塞测试；真实原生永不返回/物理设备隔离 NOT_RUN |
| B19 | reporter 实际 Dio 请求：Stopped 调用方超时→新周期等待→旧实际完成→新 Start，迟到响应不串周期 |
| B20 | 本地同周期复用已实现；没有自动刷新 URL 功能，源拒绝有界失败而不伪装新会话延续；真实签名过期刷新验收 NOT_RUN |
| B12/B17/C09 | 既有普通媒体、离线、全屏、内嵌、混合媒体焦点、下一集、Trickplay、生命周期/缓存全量回归；设备快滑验收 NOT_RUN |
| C01/C02/C03/C05/C06/C07 | `source_http_input_test`、原生测试及 loader：原始请求、重定向、Range、剥离资源头、HTML/gzip 拒绝；DNS 名 SNI/全部平台组合 NOT_RUN |
| C04/C08 | 首版仅有限 Range 渐进输入；HLS/DASH unsupported；保守内存缓存，不将 unknown 长度当磁盘缓存证据 |
| C10 | 固定异常分类、不传源 URL 到 mpv，现有日志/完整导出回归；真实服务敏感字段样本 NOT_RUN |
| C11 | Windows sid/track-list tested，A/B/off fake 副作用 tested；iOS/Android 实际字幕画面 NOT_RUN |
| C12 | 合成鉴权 API + 真实原生播放上报顺序 tested；真实 Emby 服务访问序列 NOT_RUN |

这是一条已可执行的直连实现，但不等于完整 v3 实机验收或全容器支持。
不宣称自动 URL 刷新、所有 TLS/CDN 组合、所有平台字幕画面已经验证。
签名失效可退出重新播放获取新严格快照；不使用旧 Emby 视频兜底。

## 验证命令和证据

本机 SDK 位于 `C:/Users/jsdfhasuh/.codex/tmp/strm-flutter`，测试 PATH 包含
`C:/Users/jsdfhasuh/.codex/tmp/strm-native`。日志位于同一 tmp 目录。

| 验证 | 本轮结果 |
|---|---|
| C bridge：zig cc -shared -O2 -Wall -Wextra -Werror | PASS |
| dart format --output=none --set-exit-if-changed lib test | PASS，0 changed；strm-runtime-format-check.log |
| flutter analyze --no-pub | PASS，No issues found；strm-runtime-analyze.log |
| flutter test --no-pub --reporter expanded | PASS，1269 passed / 3 existing Windows skips；strm-runtime-full.log |
| loader/controller targeted | PASS，54 tests；strm-loader-tests.log |
| online resolver/reporter targeted | PASS，39 tests；strm-protocol-runtime.log |
| Windows actual native/Bootstrap | PASS，2 tests；strm-reopen-native.log |
| git diff --check | PASS |
| 本地 Android SDK/Xcode | NOT_RUN：Windows 无 Android SDK/Xcode；由固定 CI 工具链执行 |
| GitHub iOS Core | 提交后跟踪该 SHA，保留 Android 启动、XCTest、entitlement/ldid/负向和 checksum 所有旧门槛 |

新增 CI：Linux 编译 C 桥用于真实输入测试；Android CMake 打包桥；iOS Runner 编译桥，
模拟器使用同桥实际视频解码/seek/重开；release nm 验证 FFI 符号未被裁剪。
最终 IPA 必须与最终 main SHA 一致，下载后核对 ZIP/Info.plist/build/诊断 commit/锁文件/checksum。

最小下一步：用真实 Emby STRM/OpenList 的有限 MP4/MKV（含 HTTPS/CDN）在设备验收，
抓取不含凭据的 origin/Range/会话事件计数，检查字幕画面和快滑焦点，再补真实签名过期样本。

## 后续验证与 CI 修正

- TLS 探针实际通过，见 `evidence/strm-windows-controlled-tls.json`。执行：
  `dart --packages=.dart_tool/package_config.json scripts/diagnostics/probe_strm_controlled_tls.dart <output.json>`。
  测试证书仅加入独立探针进程的信任上下文，产品没有忽略证书校验。
- run 153：Linux 1271 通过，新增 Bootstrap 原生测试 1 失败；格式、分析和 C 桥编译通过。
  保留失败断言和原生日志诊断，继续修复该失败后构建最终提交。
- run 154：保留原断言、仅增加失败原生日志的第二次 Linux 全量通过，说明首轮失败有时序/环境因素，不能据此宣称已定位产品根因。
  将两项原生夹具显式设为 vo=null/ao=null，仍要求真实 video-params、位置、请求和上报断言，
  避免依赖 CI 的显示/声音设备；Windows 重新执行两项原生测试通过。
