# STRM 源站直连实施记录（部分完成）

日期：2026-09-27。依据：`docs/plans/2026-09-26-strm-source-direct-play-plan.md` v3。

**IMPLEMENTATION_STATUS=PARTIAL / BLOCKED_NATIVE_REQUEST_POLICY**

本次不是源站直连功能的完成版本。严格元数据 API 尚未接入 Bootstrap，
现有 STRM 播放仍走原有 Emby 路径；新功能没有启用，也没有用“全部 STRM
不支持”替换旧运行路径。此提交对应的构建是基础改动的阶段 IPA，不能据此宣称
sourceDirectOnly、OpenList 链路或计划 P0—P3 已全部验收。

## 工作区与授权

- 后续用户粘贴请求明确授权在 main 修改、提交、正常推送和运行 iOS Core，
  替代先前功能分支限制及计划的历史文档授权限制。
- 原工作区分支 `wip/full-diagnostic-export-20260827`，HEAD
  `f80546d9d196368c1941b7ae3852dc647789845b`；七个无关未提交文件保留。
- 隔离工作区 `C:/Users/jsdfhasuh/my_scripts/emby_my_client_strm_main`，分支 main，
  上游 origin/main；开始时干净，起始 HEAD/origin/main 均为
  `cf65dc1c01b331b3256090f9ece3f9df25267525`。
- 固定源码基线 `ab5303652269b3ae9f9d85f5b4d3de96376a9e0e` 到起始 HEAD
  只有 v3 计划文档变化，没有待复用的直连代码。未发现适用 AGENTS.md。
- 已确认 GitHub 读取、push、Actions 和 artifact API 权限。未改依赖锁、
  受保护平台配置、IMPLEMENTATION_START_HEAD 或既有工作流门槛。
- 最终提交、远端回读、运行 ID 和下载校验由交付报告记录；本文件提交时 CI 尚未运行，
  不把预期结果写成已通过。

## P0：锁定依赖与机制

| 平台/层 | 实际锁定版本 | 执行机制与证据 |
|---|---|---|
| Flutter/Dart | Flutter 3.38.9 / 67323de285b00232883f53b84095eb72be97d35c；Dart 3.10.8 | 使用精确 revision 安装 SDK，pub get --enforce-lockfile 成功 |
| Dart 播放器 | media_kit 1.2.6，media_kit_video 2.0.1，media_kit_libs_video 1.0.7 | Media 经 URIParser/Uri.toString；百分号编码大小写会规范化 |
| Windows | libs_windows_video 1.0.11；mpv-dev-x86_64-20230924-git-652a1dd.7z | 实测 mpv v0.36.0-403-g652a1dd907 / FFmpeg n6.0 |
| iOS | libs_ios_video 1.1.4 → libmpv-darwin-build v0.6.0 | downloads.lock 指向 mpv 0.36.0 / FFmpeg 6.0；包 SHA256 a95bc18508af26136b8a408341c05b5585d644ec013f00ac07db09d2e28d36ae |
| Android | libs_android_video 1.3.8 → libmpv-android-video-build v1.1.7 | depinfo.sh：FFmpeg 6.0；mpv 78d43740f52db817d98bcf24fb30a76ab6fa13ff |

Windows 原生探针使用锁定 DLL、两个合成 HTTP origin 和内存生成 WAV，直接通过
ctypes 调用 libmpv。它不是 HEAD 探测或 Dart fake，不接触真实服务器凭据。
测试专用 loopback 是观察原生行为的夹具，不是产品允许的源目的。

```powershell
python scripts/diagnostics/probe_strm_native_network.py <locked-libmpv-2.dll>
```

下载包 MD5 与依赖声明一致：`a832ef24b3a6ff97cd2560b5b9d04cd8`。
DLL SHA256：`d5f0694b08c124e785d858d00082f3e3b158dd9138bfc48c0382bf1eb443a5fc`。
脱敏结果：`evidence/strm-windows-native-probe.json`。脚本退出成功只代表取得证据。

| 能力 | Windows 锁定原生库 | Android / iOS 目标库 | 结论 |
|---|---|---|---|
| 直接 libmpv raw path/query | tested：本次编码、重复参数、上游 api_key 样本保留 | unverified / NOT_RUN | 不证明经 media_kit 后保真 |
| media_kit 原始 URL 保真 | unsupported：Dart 测试确认编码被规范化 | 同版本 Dart 路径同样存在问题 | 需要不透明字符串入口 |
| 跨 origin 自定义 Authorization | tested：观察到转发，因此隔离 unsupported | unverified / NOT_RUN；共同 FFmpeg 源码没有所需门槛 | 不能启用目标链路 |
| 最多五跳 | tested：六跳仍被跟随，因此约束 unsupported | unverified / NOT_RUN | 源码 MAX_REDIRECTS=8 |
| 显式空 http-header-fields | tested：本次手动清空后无 Authorization | unverified / NOT_RUN | 不等于所有 media_kit reopen 或 Cookie 已清理 |
| Cookie jar / 全部属性清理 | unverified / NOT_RUN | unverified / NOT_RUN | 不能由空 headers 推导 |
| Range 再请求目的与认证 | unverified / NOT_RUN | unverified / NOT_RUN | 没有逐请求策略桥 |
| HLS/DASH 子清单、分片、密钥 | unverified / NOT_RUN | unverified / NOT_RUN | 不声明支持 |
| HTTPS 降级、DNS 后实际地址限制 | unverified / NOT_RUN | unverified / NOT_RUN | 初始 Dart 校验不是原生保证 |
| 原生字幕实际轨道/画面 | unverified / NOT_RUN | unverified / NOT_RUN | fake 副作用测试不能替代 |
| 真实 OpenList 渐进媒体及跳转 | unverified / NOT_RUN | unverified / NOT_RUN | 未提供真实服务器/设备；现有原生机制已证明不够 |

源码依据：

- media_kit `lib/src/models/media/media_native.dart` 的 URL 规范化；
  `lib/src/player/native/player/real.dart` 的 on_load/on_unload 使用全局
  http-header-fields，卸载 reset 的 native 错误没有成为可靠清理确认。
- 同文件 setSubtitleTrack 使用 synchronized，命令 Future 等待响应，但底层负返回值
  可能只记日志；因此串行化完成不等于实际选轨确认。
- FFmpeg n6.0 `libavformat/http.c`：MAX_REDIRECTS=8；http_open_cnx
  的跳转复用 custom headers；http_connect 再次附加 s->headers。
- mpv 0.36.0 `stream/stream_lavf.c` 经 avio_open2，未提供计划所需每次 HTTP
  发送前的目的/认证回调。media_kit on_load 不是每个重定向/Range 请求回调。

最小下一步是为锁定 FFmpeg/libmpv 增加**逐次 HTTP 请求的目的和认证策略桥**，
让初始、重定向及 Range 重开都在发送前执行五跳/降级/目的限制、凭据作用域和取消，
并提供 raw URL 通道、每次 open 的可确认清头/Cookie 重置。
这需要目标原生二进制重建和相应平台包/保护配置的有据更新，不是 app 中替换 path
或设置一个 mpv 属性可以完成。本次没有擅自重写网络内核、新增代理、更换播放器、
升级依赖或绕过保护。目标平台原生验证仍是下一阶段启用的前置条件。

## 已实施与尚未实施

| 阶段 | 状态 | 本次结果 |
|---|---|---|
| P0 | 部分验证，存在真实阻塞 | 锁定依赖、源码机制、Windows 原生反例和平台能力矩阵；移动端及真实链路未验证 |
| P1 | PARTIAL | 三态分类/固定源、严格元数据 API、取消/30 秒预算、原始 URL/不可变 headers/同源快照与强身份；未接 Bootstrap |
| P2 | PARTIAL | 轨道正向证据、换源预检和选择 draft、每引擎字幕队列、当前已应用轨道上报快照；直连生命周期仍未实现 |
| P3 | 本地自动化通过；CI 提交时待执行 | 全量基线与新测试、format/analyze/diff；平台 Actions 及 IPA 由交付报告补证 |

`getSourceDirectSnapshot` 是显式调用的元数据基础 API，只接收已固定 source 身份，
最多一次详情和一个严格组（三次），不自行探测源站。它拒绝 forceTranscode、错误响应、
无权开启的流与过期身份，空头按新响应整体替换。它不构成播放授权。
尚未实现 unknown identification → 普通组的完整七请求编排，普通媒体旧路径
也尚未切换到新三态分类；不能将这些单元测试当成完整首播协商测试。

实际运行路径中的独立修复：

- 普通兼容请求也携带指定 MediaSourceId；指定源丢失/重复明确失败，禁止静默换版本。
- 新版本先以无旧显式轨道数字的草稿预检；失败保留旧视频。提交时重置旧选择与已应用标记，
  保留字幕关闭/默认意图。候选只消费一次，不再次请求首个 plan。
- TrackMapper 不再以 Index==native id 判定；语言/编码/标题/声道正向证据及冲突检查，
  多候选返回 ambiguous。原 fixture 补充真实匹配元数据，没有弱化原断言。
- 字幕 embedded/external/off 统一经每引擎队列，等待真实 nativeFuture；逻辑 timeout
  不释放队列，A 晚完成后仅执行最新意图。保留原生操作跟踪及退出屏障。
- 字幕完成基于当前 plan 更新，避免覆盖期间的新音轨；Start/Progress 不使用未应用的
  期望轨道数字。实际 native readback 仍待补齐，不能声称全平台实际状态已确认。

仍未实现：sourceDirect route/约束与 Bootstrap 双入口接入；封闭首播/恢复/seek/缓存
等全部 Emby 回退；EngineOpenAttempt 与 PlaybackReportingCycle 分离及周期退场；
受控异步字幕下载、15 秒/10 MiB/32 MiB 限额和文件租约；原生实际字幕确认；直连 UI。
计划 7.3 明确只给 sourceDirect 新增周期延续，本次未将它无条件改写到普通媒体生命周期。
受控 loader 尚未接入，因此没有新旧 loader 双载，也没有宣称远程字幕已完全非阻塞。

## 计划第 11 节逐项验收映射

状态含义：TESTED 仅限注明层次；PARTIAL 表示存在测试但整行门槛未满足；
NOT_RUN 表示未实现或缺少运行环境；UNSUPPORTED 表示有反例，不能启用。

| ID | 状态与证据 |
|---|---|
| A01 | NOT_RUN：未接 sourceDirect open/route |
| A02 | PARTIAL：policy 源证据 sticky/多源 fixture，运行编排未接 |
| A03 | PARTIAL：policy A/B 证据、snapshot API 响应重排；跨普通/严格组未接 |
| A04 | PARTIAL：policy/API 缺失重复固定源，完整恢复未接 |
| A05 | PARTIAL：非法目的拒绝、详情整包 fallback；运行 open 未接 |
| A06 | PARTIAL/UNSUPPORTED：raw string 单测、Windows native 原样；Media 规范化失败 |
| A07 | TESTED（policy）：LAN 允许，不借 IsRemote 拒绝 |
| A08 | PARTIAL：初始目的单测；后续请求未受控 |
| A09 | TESTED（metadata API）：三个实际 Dio payload 保留 flags/ID/-1 |
| A10 | PARTIAL：snapshot API forceTranscode 零 I/O；unknown 流程未接 |
| A11 | PARTIAL：单详情/单严格组预算、取消触达 Dio；双组七请求/总时序未验收 |
| A12 | TESTED（policy/API）：401/403/429 和固定 ErrorCode 拒绝 |
| A13 | PARTIAL：STRM NoCompatibleStream 拒绝；普通识别特例未编排 |
| A14 | PARTIAL：snapshot 源轨道/时长隔离，不代表实际播放器元数据已迁移 |
| A15 | TESTED（snapshot/API）：URL/headers 整包替换，包括详情替代 |
| A16 | PARTIAL：拒绝需开启/无限流；意外资源归属账本未实现 |
| A17 | PARTIAL：普通扩展名/File 正向分类表；正常组路由未接 |
| A18 | PARTIAL：固定选择及严格兼容响应重排；跨协商组未实现 |
| A19 | PARTIAL：按具体源分类，指定源缺失拒绝；完整普通组集成未实现 |
| A20 | TESTED（request）：非法/冲突/保留头拒绝、空集合、不可变副本 |
| B01 | NOT_RUN：strict 运行入口未实现 |
| B02 | TESTED（TrackMapper）：数字相同但语言冲突不匹配 |
| B03 | TESTED（mapper/controller）：歧义/缺证据，默认音轨保留且不报成功 |
| B04 | PARTIAL：新源候选失败保留视频；strict 码率入口未接 |
| B05 | NOT_RUN：直连恢复/缓存周期未接 |
| B06 | NOT_RUN：原生源站错误分类未接 |
| B07 | PARTIAL：已应用上报快照；受控非阻塞下载未实现 |
| B08 | PARTIAL：选择/禁用队列单测；新 loader 网络取消未实现 |
| B09 | PARTIAL：当前 plan 更新修复及已有 controller 回归；完整下载交错未接 |
| B10 | NOT_RUN：新 loader 大小/期限/解压限制未实现 |
| B11 | NOT_RUN：文件租约/空间预算未实现 |
| B12 | PARTIAL：既有 mixed viewer/焦点测试回归，STRM 实际直连未接 |
| B13 | PARTIAL：既有双入口/暂停准备测试回归，sourceDirect 未接 |
| B14 | PARTIAL：身份/snapshot API 和既有多服务器回归；直连文件/原生隔离未验收 |
| B15 | TESTED（identity/API）：同 scope 新 API、失效晚响应不可发布 |
| B16 | PARTIAL：既有原生屏障回归及新队列超时/retirement fixture；设备 NOT_RUN |
| B17 | PARTIAL：跨源草稿清索引；下一集重判直连策略未接 |
| B18 | NOT_RUN：同周期本地重开 Start/Stopped 各一次未实现 |
| B19 | NOT_RUN：新周期退场时序/晚响应矩阵未实现 |
| B20 | NOT_RUN：URL 刷新周期证明与有界退场未实现 |
| B21 | TESTED（controller B21）：A/B 相同数字不同语言，新源首次请求无旧数字 |
| B22 | TESTED（controller B22 + 既有同源恢复）：预检失败保留旧播放、关闭意图保留 |
| B23 | TESTED（controller + queue fake）：A 的真实模拟副作用晚完成，B 合并，最终 off |
| B24 | PARTIAL：唯一 native 通道，不以 timeout 放行；loader 迁移未实现 |
| B25 | PARTIAL：队列不因等待超时放行；原生永不完成的实际隔离验收 NOT_RUN |
| C01 | PARTIAL：证据门槛默认 unverified 拒绝单测；生产适配未接 |
| C02 | UNSUPPORTED（Windows 合成原生）：跨 origin 凭据转发且超过五跳；其余矩阵 NOT_RUN |
| C03 | NOT_RUN：Range 原生目的限制 |
| C04 | NOT_RUN：HLS/DASH 子请求 |
| C05 | PARTIAL：仅显式空 headers 原生样本；Cookie/全平台轮换 NOT_RUN |
| C06 | NOT_RUN：视频/字幕原生认证隔离 |
| C07 | NOT_RUN：实际源/字幕错误内容识别 |
| C08 | PARTIAL：既有缓存策略全量回归；直连传输分类未接 |
| C09 | PARTIAL：普通/离线/Trickplay/会话现有测试通过；直连实际状态 NOT_RUN |
| C10 | PARTIAL：固定错误分类、现有日志测试通过；全新原生链路诊断 NOT_RUN |
| C11 | NOT_RUN：原生实际字幕轨道/画面；B23 fake 不替代 |
| C12 | NOT_RUN：真实 Emby 重开/周期网络访问序列 |

## 本地验证与构建边界

使用精确锁定 SDK，原生测试 PATH 指向上述 Windows DLL。结果日志保留在
`C:/Users/jsdfhasuh/.codex/tmp/`，没有将构建物/凭据加入仓库。

| 命令/场景 | 结果 |
|---|---|
| pristine cf65dc1：flutter test --reporter expanded | 1196 通过，3 既有 Windows skip，0 失败；strm-baseline-tests.log |
| 当前修改：flutter test --reporter expanded | 1252 通过，3 同样 skip，0 失败；strm-final-tests.log |
| dart format --output=none --set-exit-if-changed . | 277 files，0 changed；strm-format-check.log |
| flutter analyze | No issues found；strm-analyze.log |
| git diff --check | 通过 |
| Windows 原生网络探针 | 已执行并发现阻塞，见脱敏 JSON；不是支持通过 |
| flutter build apk --debug（本地） | 环境失败：No Android SDK found；strm-local-android.log |
| Android 工作流构建/启动性 | 提交时 NOT_RUN；推送后由 iOS Core Quality and Android 执行 |
| iOS Core / TrollStore IPA | 提交时 NOT_RUN；要求最终 SHA 的 Actions 和下载校验，详见交付报告 |
| 真实 Emby/OpenList、Android/iPad 设备 | NOT_RUN：未提供目标样本/设备及受控逐请求适配 |

三项跳过来自既有 `library_genre_navigation_integration_test.dart` 的 Windows 原生
UI 限制，未新增 skip。新增测试为政策/API/资源快照、Media 规范化证据、队列副作用和
controller 时序。现有普通媒体、离线、全屏、内嵌、服务器作用域、Trickplay、缓存、
生命周期测试随全量执行；这是自动化回归，不是上述功能的实机验收。

平台工作流保持既有 protected-files、Android native/启动性、iOS simulator native、
unsigned device、TrollStore entitlement/ldid/负向门槛和 checksum 检查。
其中 simulator native 测试针对已有缓存能力，不证明 STRM 网络或字幕最终状态。
后续必须先实现并验证目标原生策略桥，再接直连运行通路、完成剩余矩阵后宣称功能完成。
