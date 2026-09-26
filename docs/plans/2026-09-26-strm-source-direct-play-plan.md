# STRM 源站直连播放：实施计划 v3

日期：2026-09-26
项目：`jsdfhasuh/emby_my_client`
固定源码基线：`ab5303652269b3ae9f9d85f5b4d3de96376a9e0e`
文档状态：`PLAN_REVISED_V3 / P0_EVIDENCE_PENDING`
实现状态：`NOT_IMPLEMENTED / RUNTIME_TESTS_NOT_RUN`
仓库路径：`docs/plans/2026-09-26-strm-source-direct-play-plan.md`

本文件完整替代会话中的原计划与 v2，合并第二轮 R1—R6、第三轮 T1—T4 的修订要求。实施者以本文件为唯一计划，不需要自行拼接审查报告。旧稿与报告作为历史记录，不表示功能已经实现。

本次授权范围为完善并提交计划文档，不包括修改播放源码、升级依赖、合并其他分支或修改服务端。后续实现须另获授权。承载本文件的 Git 提交记录文档交付事实，不以文档状态冒充代码或实机验收结果。

## 1. 目标与范围

客户端通过正常鉴权的 Emby 接口取得 STRM 指向的 HTTP/HTTPS 媒体地址，再由现有播放器直接请求该地址。源站可以是 OpenList，不要求提前解析网盘最终 CDN 地址。不得改写 `/p/`、`/d/`、加密路径或签名。

已确认 STRM 采用 `sourceDirectOnly`：首播、续播、音轨/字幕切换、seek、运行恢复、缓存重开均不自动回到 Emby 视频 stream、remux、transcode 或下载接口。Emby 元数据、PlaybackInfo、会话上报、外挂字幕与 Trickplay 图片仍可使用。

已确认普通媒体保留原协商与允许的转码流程；离线媒体保持本地播放。路径被隐藏、证据不足的在线媒体按照第 5 节处理，不宣称这些未知样本也完全不受影响。

不另建播放器、视频代理或全局状态系统；不修改 STRM/NFO、Emby Server、OpenList、Nginx；不扩展离线直链下载。第一版没有隐藏的自动中转开关，不默认升级 Flutter/media_kit/iOS 工具链。

验收区分应用构造地址、原生后续请求、源站内部代理三层。不能只看 UI 的 DirectPlay，也不能仅凭 URL 保证源站内部没有再代理。Emby 后台扫描和媒体探测不属于“客户端视频不经 Emby”的零流量保证。

## 2. 基线、审查闭环与当前事实

### 2.1 基线和提交边界

本次提交计划前重新读取远端 main，仍为上述固定提交，包含 PR #9 的混合媒体播放、诊断与多服务器切换。[S1] 后续实施前记录实际分支、HEAD、上游与工作区状态，对相关文件比较新增差异；不硬重置、不擅自切分支或合并。

原 v2 文件 SHA-256：`292cae8cc81d1c38f7410c99eaf4485e8d2214e28e70fe76ca227039be9dfde5`。第三轮报告 SHA-256：`e93d7c0c6c88cf7baf4c6186f47b7f210d432ff1cc6e99bce98270905d8011f5`。这两个摘要仅用于定位本轮输入，不是源码或测试证据。

### 2.2 审查意见与正文对应

| 意见 | 本版确定的规则 | 对应位置 |
|---|---|---|
| R1：新入口、多服务器、原生生命周期 | Bootstrap 共用接入；绑定 ServerScope/API 会话；保留原生屏障和租约。 | 第 3、4、10、11 节 |
| R2：首次协商尚无 plan | I/O 前建立上下文；严格 flags 覆盖所有兼容请求；有界识别与错误表。 | 第 4、5 节 |
| R3：重定向缺实际执行者 | P0 明确原生执行机制，未验证或不支持的组合发送前拒绝。 | 第 6、10 节 |
| R4：URL 正确但元数据混源 | 原子源快照；URL/headers 成对更新；同源元数据有据补齐。 | 第 4、7 节 |
| R5：索引数字误匹配 | TrackMapper 必改；有证据唯一匹配，否则未找到/歧义。 | 第 8 节 |
| R6：字幕阻塞启动 | 下载不进入视频 ready 等待链；独立状态、文件租约与实际状态上报。 | 第 9 节 |
| T1：普通媒体正向证据不清 | 分类决策表、候选排序、跨协商组固定 MediaSourceId；未知样本显式受限。 | 第 5.1—5.3 节 |
| T2：快照复用与上报结束冲突 | 源快照、引擎打开代次、上报周期分离；本地重开延续周期。 | 第 4.3、7.3 节 |
| T3：跨版本沿用旧轨道索引 | 新源首次请求前清除旧显式索引；只迁移明确关闭/跟随默认意图。 | 第 8.2 节 |
| T4：旧原生字幕操作晚完成 | loader 不拥有选择状态；唯一原生应用通道、合并最新意图、跟踪真实副作用。 | 第 9.2—9.4 节 |

“已纳入”只表示设计条款进入正文。原生能力、真实响应和测试结果仍待 P0—P3 取得，不因本轮不再扩大范围就视为通过。

### 2.3 固定提交的相关代码事实

`getPlaybackPlan()` 当前把 STRM 构造为 Emby 静态视频接口；选中源 ID 在响应后匹配。`getPlaybackInfo()` 当前允许转码与自动打开 LiveStream；`_streamUri()` 会重建查询参数。模型尚无完整 RequiredHttpHeaders 通路。[S2][S10]

新基线已有 `PlaybackSessionBootstrap`，内嵌会话通过它创建控制器；控制器和引擎已有原生操作跟踪、quiesce、retirement 与资源租约。不能用旧版本的直接 player.open 路径覆盖这些机制。[S3][S4][S5][S6]

当前 TrackMapper 先按 Emby index 与原生 id 数字相等返回；当前元数据还会合并条目级轨道、优先条目时长。当前 reconfigure 仅切 source ID 时不自动重置旧显式轨道选择。[S2][S5][S7]

当前缓存重开会经 `_stopForControlledRestart()` 停止 reporter，而 `activate()` 会新建 reporting cycle。当前也已有 `_lateSubtitleTask`、延迟外挂/内嵌字幕路径；外挂字幕加载返回受跟踪的原生 Future。[S5][S6][S13] 下文据此定义增量改动，不声称这些风险已经在用户设备复现。

## 3. 共用接入与生命周期

全屏 PlayerScreen 与家庭媒体内嵌播放统一经 `PlaybackSessionBootstrap → PlaybackController → EmbyStreamResolver/EmbyApi → 资源策略 → MediaKitPlaybackEngine`。页面不自行组装源 URL 或认证头。

Bootstrap 注入请求上下文、资源策略、字幕 loader 及原有超时配置。内嵌会话、照片页与租约组件以接口适配和回归为主，不各自实现一套解析。保留 `playAfterReady=false`，视频准备完成不自动获得播放焦点。

打开、播放、暂停、seek、轨道应用、停止和销毁仍走现有原生跟踪路径。逻辑超时不等于原生完成；未确认销毁不得释放唯一播放器租约或复用仍可能产生旧副作用的引擎。

账号切换时新增任务捕获原 API 和作用域，不读取动态“当前全局 API”。合法旧周期停止使用旧身份；晚结果只清理自己的资源，不向新账号上报或改变新播放器。适用原控制器退出、原生输出静默与前后台规则。[S3][S4][S5][S6][S8][S9]

## 4. 请求上下文、身份与源快照

### 4.1 请求前上下文

在第一次 I/O 前建立不可变 `PlaybackResolveContext`，语义至少包含：

```text
ServerScope(serverId, userId) + API/账号会话有效性绑定
ItemId + requested/selected MediaSourceId（未确定时可空）
PlaybackItemSessionId + 请求代次 + cancellation
classification = confirmedStrm / confirmedRegular / unknown
constraint = sourceDirectOnly / serverManaged / identificationOnly
```

重新登录后即使 ServerScope 相同，也不能继承旧 API 的请求头或晚响应；复用现有会话对象/有效性标记，不新建账号系统。confirmedStrm 在同一源恢复中保持严格策略，不因后续响应把容器解析成 mp4 就普通化。

### 4.2 资源身份和单一请求对象

完成选源后，资源与异步任务绑定 `scope + API 会话 + item + source + PlaybackItemSessionId + generation`。字幕另带选择 revision 和绑定引擎身份。只用媒体数字 ID 或局部 generation 不能作为跨账号共享键。

媒体请求只有一个事实来源：原始 rawUrl、不可变 headers、授权目标与资源身份。旧 `uri`/`usesServerAuthentication` 如保留，必须派生或明确迁移，不能成为另一组可独立修改的值。第一版不持久缓存 URL、签名和头。

完成态 `PlaybackPlan.routeKind = serverMedia / sourceDirect / offlineLocal`，与 Emby PlayMethod 分离。sourceDirect 仍使用合法的 DirectPlay 上报，但必须来自严格上下文。构造器拒绝 route/constraint 冲突；copyWith、fake、离线解析器均保留新契约。

### 4.3 三种生命周期不得混为一个 plan

| 对象 | 内容与身份 | 何时变化 |
|---|---|---|
| SelectedSourceSnapshot | 授权响应来源、scope/item/source、rawUrl 与同响应 headers、源轨道/时长/大小/协议等。 | 合法解析或刷新时原子替换。 |
| EngineOpenAttempt | 新 generation、绑定引擎、当前取消与原生操作身份；引用有效快照。 | 缓存重开、同源恢复或引擎重建。 |
| PlaybackReportingCycle | 本地唯一 cycle ID、绑定 API/item/source、可空服务端 PlaySessionId、Start/Progress/Stopped 状态。 | 第一次逻辑观看、明确换源/新会话或结束；不因纯本地重开而变化。 |

快照可记录产生它的响应代次和会话证据，但不拥有 reporter 的 Start/Stopped 状态，也不决定是否再次 activate。复用有效快照时建立新打开代次，不能复用旧 cancellation/generation。

URL 与 headers 成对更新，新响应空头集合必须清掉旧集合。详情可提供同一源的完整候选，不能以详情 URL 拼接旧 PlaybackInfo 的头。服务端会话 ID 只来自已授权且同源的 PlaybackInfo；本地 cycle ID 不能冒充或作为服务端 PlaySessionId。

## 5. 分类、选源、协商与失败规则

### 5.1 分类决策表（T1）

输入必须是同一 scope/API/item/候选源及其证据来源。分类依据是服务端声明，不声称客户端已访问服务器文件系统核实真实文件。

| 正向证据或缺口 | 第一版结果 |
|---|---|
| 候选源自己的路径/容器明确为 strm；或同 ID 新鲜详情源有 STRM 证据。 | confirmedStrm。解析后 URL 为 mp4/mkv、Protocol=Http 不消除这一证据。 |
| 新鲜详情只有一个有效唯一源，顶层 STRM 路径可无歧义关联到它。 | confirmedStrm。多源顶层 Path 不扩散给所有版本。 |
| 新鲜详情同一源：Protocol 明确为 File，Path 为绝对本地/共享视频文件路径，扩展名属于受支持普通视频集合且非 strm，无对应 STRM 冲突。 | confirmedRegular，允许原有服务端协商。 |
| 新鲜详情只有一个有效唯一源，源声明 File，顶层普通本地/共享视频路径可唯一补齐该源，且源字段不冲突。 | confirmedRegular；必须有单源关联 fixture。 |
| 只有 mp4/mkv 容器、HTTP URL、IsRemote、SupportsDirectPlay/Transcoding。 | unknown，不单独作为普通媒体证明。 |
| 源隐藏 Path、Protocol 缺失、条目多源而只有顶层 Path、关联证据不足。 | unknown；最多一次详情补取，用完仍不足则 sourceIdentityUnresolved。 |
| 同 ID 存在重复、不可解释的源身份变化或互斥证据。 | sourceIdentityConflict；不通过挑一个字段忽略冲突。 |

普通本地/共享路径只用于分类 serverManaged，绝不能直接交给移动客户端作为 HTTP 地址。普通视频扩展名采用仓库已支持的明确集合并建 fixture，至少覆盖 mp4/mkv/mov/m4v/webm/ts/m2ts/avi；新格式通过显式样本补充，不把任意非 strm 后缀都视作视频。

STRM 解析前路径与解析后 HTTP 媒体 URL 是合法的不同阶段，不自动当作互斥证据。跨 API 会话或无法解释的同 ID 源变更则不沿用旧授权。未知普通媒体也可能被首版限制，应在兼容表列出，不能同时宣称所有普通样本完全无影响。

### 5.2 候选选择与跨组固定点（T1）

有用户指定源时仅接受该唯一 ID；已固定源缺失/重复就失败。不能用另一个版本继续播放，也不能伪造 ID。

未指定时，仅从当前有效响应中选择一次候选。沿用现有优先级：支持 DirectPlay → 有可用 DirectStreamUrl → 有 STRM 正向证据 → 有可用 TranscodingUrl → 首个有效源；同级保持响应顺序。这个排序只选身份，不授权实际播放或绕过严格策略。[S2]

只要已经取得可用源列表，在最终协商前固定 selectedSourceId。没有列表时，可用唯一一组严格 identificationOnly 请求发现源；成功响应后立即固定。进入另一组协商、兼容重试、刷新和恢复全部携带该 ID，只匹配同一源，不重跑默认选源。无 ID 的识别结果不具备普通协商授权。

普通证据只能授权对应源。例如普通源 A 与 STRM 源 B 共存，A 证据不能让 B 进入正常组。最终响应顺序或 flags 改变不改变候选。已固定源失败后要改版，属于新的显式选择，不是本次重试。

### 5.3 三类请求与严格 flags

| 上下文 | 请求与结果 |
|---|---|
| confirmedStrm | 严格 PlaybackInfo；有效结果用于同源直连；缺地址/不支持明确失败。 |
| confirmedRegular | 原有正常 PlaybackInfo 与普通媒体转码规则。 |
| unknown | 优先共用的一次新鲜详情 GET；仍需发现源才发严格识别组。确认普通后只对固定源进入正常组；仍未知则失败。 |

严格/识别组的完整、去 Profile、最小 payload 均保持：

```text
EnableDirectPlay = true
EnableDirectStream = false
EnableTranscoding = false
AutoOpenLiveStream = false
UserId = 绑定用户
MediaSourceId = 固定候选（尚未发现候选时不得伪造）
```

关闭字幕保持 SubtitleStreamIndex=-1；跨源请求的轨道参数按第 8.2 节重置。参数位置以官方请求模型和锁定服务端 fixture 为准。[S11] 不靠极大码率或虚构 DeviceProfile 强制获取 DirectPlay。

兼容组只对原有 400/422/500 分级；不得删严格 flags 求成功。已确认 STRM 的 forceTranscode 在 I/O 前拒绝；unknown 的 forceTranscode 先安全识别，只有 confirmedRegular 才执行。普通组意外返回明确 STRM 证据时不得打开服务端视频，进入尚未使用的严格组；预算耗尽或身份冲突就失败。

### 5.4 请求预算与错误表

每次逻辑 resolve 最多：详情 GET 一次（识别与补齐共用）、严格 PlaybackInfo 组一次且最多三请求、普通组一次且最多三请求。正常启动新增的源站 HEAD/探测/读取 STRM 文本为零。unknown 最坏七次元数据请求，不是每次固定七次；组间不得循环。

涉及严格/未知识别的总墙钟预算 30 秒，包含转为普通组的时间；每次 HTTP 不超过剩余预算，取消传播到底层请求。直接确认为普通的旧路径保持原超时行为。以上是实施上限，不是协议限制。

额外地址重新协商最多一次，并占用现有恢复额度；纯本地重开可复用同 API 会话中仍有效的授权快照，不消耗这次刷新，也不因重开新建上报周期。新鉴权失败或 API 失效不能借旧快照绕过。源站 403/404、解码不支持默认不触发刷新。

| 结果 | 严格/识别路径处理 |
|---|---|
| Emby HTTP 401/403、NotAllowed | 拒绝优先，终止；不使用 Path/旧快照绕过。 |
| HTTP 429、RateLimitExceeded | 终止并提示限制；不立即自动重试。 |
| STRM 最终 NoCompatibleStream | 首版失败，不凭 Path 覆盖，不转码。 |
| identificationOnly 的 NoCompatibleStream | 只有已取得同一固定普通源正向证据时，允许一次正常组；不直接播放失败响应地址。 |
| 其他非空 ErrorCode | 保守失败，固定错误类别。 |
| 无 ErrorCode、有效源，SupportsDirectPlay=false | 不单独解释为权限拒绝；STRM 其余规则通过可交给本机解码，失败不中转。 |
| 源 ID/地址缺失、相对路径或仅磁盘路径 | 共用详情额度仍无解则失败；不请求 Download/File/stream 读取“STRM 文本”。 |
| 源站 401/403 | 资源认证失败，不触发 Emby 全局登出。 |
| 源不可达、TLS、404、解码失败 | 明确失败，不关闭 TLS 校验、不改 IP、不转码。 |
| 原生能力 unverified/unsupported | 不允许的请求发出前返回 nativeRequestPolicyUnsupported。 |

NoCompatibleStream 的保守策略可能限制某些本机可解码的 STRM，真实兼容报告必须体现，不将其与权限拒绝混为一谈，也不在实现时擅改为忽略错误。

### 5.5 服务端资源归属

首版排除需要 RequiresOpening/OpenToken/服务端 LiveStream 打开的 STRM，以及明确无限直播源。未知时长不单独证明是真直播：可播放，但保守缓存。

严格组关闭 AutoOpenLiveStream。响应中意外资源只有在确属本次请求创建且拥有清理权时，才记录到绑定旧 API 的幂等清理账本；失败、取消、晚响应均处理自己的资源。单凭 LiveStreamId/PlaySessionId 不盲目关闭别人的流。归属不明停止接受该源并记录异常。普通媒体原资源管理回归不变。

## 6. URL、认证与原生网络门槛

### 6.1 原始 URL 与资源头

rawUrl 作为不透明标识，解析副本只做校验。不得经 `_streamUri()`/queryParameters 重建；不排序、合并重复键、互换 +/%20/%2F，不删上游 api_key，不加 Emby Token、Static、源 ID 或轨道索引。必要时调整引擎入参传原始字符串，仍走原生屏障；同时验证 Dart 与原生实际 path/query。

支持合法 HTTP/HTTPS LAN 和公网地址，IsRemote=false 不能排除 LAN。源站直连拒绝盘符/UNC/file/相对 Path、嵌套远程 .strm 文本、userinfo、控制字符、localhost、回环和未指定目的。初始与后续目的同策略；不替换服务器本机地址，不一概禁止 RFC1918。

| 资源 | 认证来源 |
|---|---|
| Emby 元数据/会话 | 创建请求时绑定的 Emby API 会话。 |
| STRM 源视频 | 当前同源快照 RequiredHttpHeaders，经校验和授权范围限制。 |
| Emby 字幕/Trickplay | 明确属于该服务器资源的独立认证。 |
| 第三方字幕 | 字幕自身可证明的授权；无声明不继承视频或 Emby 头。 |
| 离线文件 | 无网络认证。 |

headers 不可变、大小写不敏感处理冲突；拒绝非法键值/CRLF、Host、Content-Length、hop-by-hop 及保留认证字段。Range 由播放器管理。非法必需头使源失败，不能悄悄删掉后声称支持。

源请求不得自动取得 X-Emby-Token/X-Emby-Authorization。Authorization/Cookie/自定义头按可能含凭据处理；UA/Referer 也检查值，禁止无边界传播签名或会话内容。与 Emby 同 origin 不代表可继承其认证；识别 Emby 视频端点须结合 base path 和资源语义，不误拦字幕或 Trickplay。

### 6.2 运行时执行者与支持矩阵

原生能力在 open 前判定，按平台、锁定二进制记录，未验证默认 unverified。必须核对：原始 URL 保真、每次打开（含空头）清理前一源头/Cookie、逐请求目的限制、逐目标认证、取消及有界跳转。检查覆盖初始请求、Range 再开、重定向、manifest/子清单/分片/密钥和相关子资源。

共享资源层产生策略，后续请求由真正具备约束能力的原生网络机制执行；仅 Dart 检查初始 URL 不算。P0 按证据选择：

| 模式 | 可交付范围 |
|---|---|
| 逐请求受控 | 已验证原生机制或小范围适配在每次发送前校验目的与认证，覆盖声明的重定向/分段形式。 |
| 受限单资源 | 原生机制可靠禁止跳转和外部子资源；只支持该受限范围，不能仅凭 mp4 后缀推断。 |
| 不支持 | 两者均无法兑现时，相应平台/组合在请求前拒绝并报告技术阻塞。 |

用户目标 OpenList 需要跳转时，必须达到对应逐请求受控门槛。受限单资源不能冒充 OpenList 已验收；也不把重写整个 HTTP 内核自动加入任务。[S6][S12]

无额外头源仍需保真、清头和目的约束；普通头再核对值和转发；敏感头必须逐目标控制；签名 query 不人为复制到新 URL；HLS/DASH 必须覆盖所有实际子请求。缺少授权声明不从其他资源补凭据。

实际执行层最多五次跳转、拒绝 HTTPS 降级；相对 Location 按当前请求解析并重新校验。不能以一次 HEAD 或先解析最终地址替代运行约束。安全机制不能通过把 unverified 改成 supported 或删除失败测试绕开；目标以 OpenList 渐进媒体为先，非目标组合明确限制，不无限扩大范围。

## 7. 元数据、恢复与播放上报周期

### 7.1 同源元数据

sourceDirect 不再无条件 mergeMediaStreams(source,item)。源快照优先；只有证明属于同一源，才补条目级轨道。多版本顶层数据、默认版字幕、index/type 相同均不是充分证据。

时长优先当前源，单源可证明关联才用条目时长；否则保持 unknown，必要时采用原生已确认时长，不能用其他剪辑版限制续播。Size/Bitrate 同理，不把 STRM 文本大小当视频大小。更新请求时同步替换该源元数据集合，普通媒体另做回归。

### 7.2 所有重开保持路由与身份

启动失败、轨道失败、码率、seek、运行恢复、缓存安全重开、前后台和引擎重建都检查严格策略。检查顺序：目标身份/请求约束 → 原生能力 → 重试额度 → 停止或提交新请求。禁止的音轨或码率动作不能先停掉有效视频。

解析器在 plan 不存在时也约束请求；不全局关闭 canForceTranscode。允许有限同源重开/内存降级，固定 source ID、API、严格约束，恢复位置和暂停/播放意图。原生自动重开仍计入既有预算；地址刷新与上报周期分别按第 5.4、7.3 节管理。

显式换源采用候选预检和提交两步：预检不修改当前生效源/轨道，不创建第二播放器；确认目标可接受且 lease 有效后，再退场旧源、递增代次并提交。预检失败保留旧可用播放。下一集是新媒体身份，重新计算路由和认证。

### 7.3 上报周期延续、切换与退场（T2）

本节新增的周期延续规则用于 sourceDirect。共享 reporter 接口按需适配，普通 serverMedia 生命周期不得被无条件替换。冻结事件表：

| 事件 | 快照/引擎 | reporter 行为 |
|---|---|---|
| 首次逻辑观看 | 接受新快照，媒体就绪并完成必要续播。 | activate 一次；逻辑 Start 至多发起一次，携带真实暂停状态。 |
| 同源同 API 的纯缓存重开或引擎重建 | 有效快照可复用，建立新 EngineOpenAttempt。 | 延续原 cycle；不再次 activate，不发中间 Stopped/Start，不清理该观看仍需的资源。 |
| 刷新 URL，返回相同非空 PlaySessionId 且同 API/item/source | 原子更新请求，重新核实已应用轨道。 | 延续 cycle；不得复位 startAttempted/started。 |
| 刷新取得不同 PlaySessionId，或无法证明仍属原周期 | 新解析结果与旧周期明确分离。 | 先有界退场旧周期，再建立新周期；已结束的 ID 不无条件复用。 |
| 显式换源、下一集、退出 | 目标身份变化或结束。 | 按对应身份结束/新建；最终停止与自有资源清理幂等。 |

没有再请求 PlaybackInfo 的本地重开，即使原服务端 ID 为 null，也可延续同一本地 cycle。发生新协商后 null==null 不能证明服务器周期相同；不得造 ID。服务端 ID 可空与本地周期必须唯一是不同要求。

实施时拆分“停止/重建引擎”与“结束 reporter/清理服务端资源”。sourceDirect 本地重开不能无条件调用原复合 `_stopForControlledRestart()`，启动也不能无条件 activate。普通媒体原有生命周期保持独立回归。[S5][S13]

reporter 每个周期独立保存 startAttempted、已确认 started、terminal 状态、in-flight 请求和不可变请求快照。Start 已发但回执失败不能自动当成从未上报；终止时保留一次保守 Stopped 的现有原则。没有发起 Start 的失败会话不虚构 Start/Stopped。

同周期事件按 Start → 已应用状态 Progress → Stopped 排序；终止后不再发 Progress。恢复期间可暂停定时上报，恢复后继续原周期；不能伪称有不存在的 buffering 协议字段。状态更新只作用当前 cycle，迟到回执只能完成自己的周期。

停止的逻辑等待超时不等于 HTTP 已取消。绑定旧 API 的退场队列须等待实际请求完成或执行可观察的取消，禁止稍后以新 plan 重发旧 Stopped。自动刷新需要更换周期时，旧周期退场纳入本次恢复剩余预算；预算内无法完成/隔离，停止本次自动刷新，不激活新周期、不无限等待。当前仍可用的旧播放可保留，否则显示有界恢复失败。

显式换源/下一集可建立候选，但新 cycle 的 Start 不越过仍未终结的旧退场队列；超时显示上报降级，视频准备不因此无限阻塞。若后续不能有据建立 Start，就不能单发无对应 Start 的 Progress。服务端是否按会话或设备关联事件由真实验收确认，不凭本地 cycle ID 承诺服务器端恰好一次。

强制验收：首次 Start 后发生纯本地缓存降级/引擎重开，最后退出，同一延续周期仅一次逻辑 Start 和一次逻辑 Stopped；测试同时核对网络请求序列，不只计本地 activate 次数。

## 8. 音轨、内嵌字幕与跨版本选择

### 8.1 可靠映射

TrackMapper 必改。Emby 容器 Index 不等同原生 id；可信 ff-index 也必须验证解复用器和锁定依赖语义，不假设已暴露。[S7][S11][S12]

匹配返回 matched/unavailable/ambiguous。可信同源索引可按类型匹配并拒绝元数据冲突；否则用当前源与原生的语言、编码、标题、可用声道形成实际正向证据。双方 null 不算证据；语言别名使用明确测试表；多候选不猜。数字巧合不能覆盖语言/编码冲突。

默认音轨未匹配保留本机可用默认，状态记服务器默认未应用；显式选择失败保留原轨并提示，不转码、不上报期望索引已生效。内嵌字幕同规则；关闭字幕是实际动作，不等同映射不到。

### 8.2 跨源迁移规则（T3）

显式数字选择绑定 scope/API/item/source，而非只存一个 int。冻结迁移表：

| 变化 | 新请求之前的选择处理 |
|---|---|
| 同一源、同一授权身份的本地恢复 | 可保留显式选择，重新验证存在及实际应用结果。 |
| 换 MediaSourceId、换 ItemId 或换 API/账号 | 清除旧显式音轨/字幕数字与旧引擎已应用标记；不得进入新源首次 PlaybackInfo。 |
| 字幕明确关闭 | 跨版本可保留关闭意图，发送 -1，并执行原生关闭。 |
| 跟随服务器默认 | 使用新源默认，不沿用旧源解析出的默认数字。 |
| 显式旧源字幕/音轨，首版无可靠跨源偏好 | 回到新源默认；不新增语言偏好系统，不把旧索引冒充偏好。 |
| 调用明确携带新源轨道选择 | 仅接受可证明来自目标源当前选项的索引，否则拒绝或重新解析，不承接旧 int。 |

候选预检使用独立 selection draft，不能为了清索引先污染仍播放的旧源。提交时才替换当前选择、代次和源；旧字幕/轨道任务失效。同一源 ID 但源身份冲突时按第 5 节失败，不借“同源恢复”保留错误选择。

构造测试：A 音轨 2=中文，B 音轨 2=英文/5=中文，B 的首次请求不得携带 A 的 2。字幕显式数字同样重置；关闭意图保留。此为 fixture，不是用户实测结果。

## 9. 非阻塞字幕、唯一应用通道与资源释放

### 9.1 视频与字幕准备分离

```text
视频：解析 → open → ready → 续播/按意图播放或暂停 → 上报
字幕：选择 → 受控下载 → 当前引擎可应用 → 跟踪原生应用 → 确认实际状态
```

视频主链不 await 远程字幕下载，字幕超时不延长 readyTimeout。全屏与内嵌同规则；字幕回调不能启动暂停或失焦媒体。明确关闭字幕仍须执行本机关闭，不能以非阻塞为由省略禁用动作。

UI 区分期望、loading/applying、实际 applied/disabled、failed/unconfirmed。未确认应用不伪报成功；尚在加载新字幕时，旧字幕若仍实际显示，实际状态需如实保留。

### 9.2 统一现有字幕状态所有者（T4）

`external_subtitle_loader` 只负责下载和文件归属，不拥有选择状态、不直接调用引擎、不上报。Controller 的现有选择状态机为唯一所有者，明确迁移/复用 `_lateSubtitleTask` 与延迟内嵌/外挂逻辑。[S5][S6]

每次选择 revision 增加，取消旧网络/等待任务；同一字幕不能同时经原 DeliveryUrl 原生加载与新临时文件路径加载。需要认证的源站直连字幕经新 loader；普通/离线路径迁移时也避免双重调度，并单独回归。

### 9.3 唯一原生应用通道与最终选择（T4）

同一引擎只允许一条有序字幕应用通道。下载完成先核对 scope/source/open generation/selection revision/engine；进入原生前合并过时请求，只保留最新意图（包括关闭）。

已经提交的原生操作不能靠取消 Dart 等待撤回。P0 核对并复用锁定原生实现的真实串行保证；没有充分保证时，由轻量应用队列串行提交，上一操作真正 nativeFuture 完成后才提交最新待应用意图，而不是等逻辑 timeout 后假装已结束。仍沿用原生跟踪/退出屏障，不新增并行播放器。

旧原生操作完成后不得发布旧选择成功；当前身份有效时应用合并后的最新意图。每个稳定选择 revision 最多一次正常提交和一次有证据需要的最终校正；用户新选择是新 revision，不靠定时循环反复 setSubtitle。成功/关闭仅依据已确认应用结果发布。

原生应用超时则标记 failed/unconfirmed，冻结该引擎字幕写入通道并继续跟踪已有操作；不把逻辑取消解释为副作用取消。旧操作真正完成且会话仍有效时，允许一次最新意图校正；无法确认就不显示已关闭/成功，不自动转码。视频可继续，但字幕错误必须可见。退出或换源时遵守原生屏障；未解决旧副作用的引擎不能作为安全新源复用。

强制测试：A 已进入原生且阻塞，用户选 B 再关闭，A 晚完成后实际字幕最终仍关闭。fake 必须模拟旧操作改变引擎状态，不只完成 Future；原生验收检查实际选中轨道/画面。永不完成和逻辑超时样本应得到明确 unconfirmed/隔离，而不是伪造最终成功。

### 9.4 下载限制与文件租约

Emby 字幕使用绑定 API 的独立资源认证；第三方通道不复用带 Emby defaults/interceptor 的 HTTP 客户端；不把 Token 拼 URL。文本字幕采用受控下载，禁用不受控自动跳转，逐跳校验目的和授权。

每次选择总下载期限 15 秒（含跳转）、最多五跳、单文件最多 10 MiB 实际解压/解码后字节；接收过程亦有界，不只信 Content-Length。登录页、错误页及非受支持文本字幕拒绝。首版不加转换/位图下载管线。这些数值是产品上限，尚未经真实大样本校准，修改须同步测试。

应用私有临时目录，随机任务文件名不含媒体/URL；写 .part，完成且身份有效才发布。取消关闭响应并删除自己的未发布文件。已交给原生的文件带租约，真实不再使用才删除，无法证明卸载则保留至引擎真实释放。

每播放会话字幕文件与在途空间预留合计最多 32 MiB；不能释放而将超限时拒绝新下载，保留当前字幕/视频。禁止删除仍被原生使用的文件凑空间。未确认销毁保持隔离；下次启动只清理无活动租约残留，不删其他 scope/任务文件。

### 9.5 已应用状态上报

reporter 根据当前有效源、cycle 和已应用音轨/字幕构建快照，不以期望索引冒充实际。字幕完成不使用下载前旧 plan.copyWith 覆盖期间的新音轨/URL/源；音轨回调也适用同一规则。

Start 不等字幕下载；未知索引不填成成功，禁用按真实应用结果与协议表示。URL/headers 不进 Sessions payload；内嵌初始 IsPaused 如实。Start 进行中而字幕已完成时，最新状态留给其后的有序 Progress，不反向覆盖已经发出的 Start 快照。终止后迟到字幕只清理，不再发 Progress。

## 10. 文件影响与分阶段实施

### 10.1 文件清单

| 类别 | 文件 | 任务 |
|---|---|---|
| 必改 | `lib/models/emby_models.dart` | 必要源字段、请求/快照/计划契约与 copyWith。 |
| 必改 | `lib/data/emby_api.dart` | 正向分类、候选固定、严格 flags/错误/取消/预算、源快照与绑定身份请求。 |
| 必改 | `lib/playback/emby_stream_resolver.dart` | 请求前约束与取消，解析器最后一道守卫。 |
| 必改 | `lib/playback/playback_session_bootstrap.dart` | 双入口依赖统一。 |
| 必改 | `lib/playback/playback_controller.dart` | 重开/周期分离、候选事务、跨源索引重置、单一字幕状态与应用通道。 |
| 必改 | `lib/playback/playback_session_reporter.dart` | 周期延续/退场、当前已应用快照、绑定身份有序上报。 |
| 必改 | `lib/playback/playback_engine.dart` | 原始请求、能力门槛、头重置、跟踪原生操作与字幕真实完成。 |
| 必改 | `lib/playback/track_mapper.dart` | 正向证据匹配、unavailable/ambiguous。 |
| 必改 | `lib/ui/player_screen.dart`、`lib/offline/offline_playback_resolver.dart` | UI 与新契约适配，离线无网络头。 |
| 必审、按需改 | `lib/playback/playback_state.dart`、`inline_playback_*`、`media_kit_inline_playback_session.dart` | 实际/期望状态、内嵌焦点和租约。 |
| 必审、按需改 | `lib/ui/photos/inline_video_page.dart`、`photo_viewer_screen.dart` | 快滑/退出/错误展示，不复制解析。 |
| 复用、回归 | ServerScope、AppController、accounts、原生 operation coordinator/output quiescer | 不改账号架构、不削弱原生迟到隔离。 |
| 按需改、回归 | 缓存策略、Trickplay、diagnostic_log/full_diagnostic_export/playback_diagnostics | 分类、图片认证、日志脱敏。 |
| 实现阶段文档 | `docs/MOONFIN_MIGRATION_PLAN.md` | 代码实际替代后标注旧 STRM 策略，保留历史；本次不假装已经替代。 |

建议新增 `strm_direct_play_policy.dart`、`playback_resource_request.dart`、`external_subtitle_loader.dart`（均在 lib/playback），及对应测试。类型可以合并，不能为了目录形式造空模块。原生适配是否需要新文件由 P0 机制决定，不以“safe”包装名自证安全。

缓存沿用有限渐进源的已证实策略；HLS/DASH、未知传输形式或不可靠大小/时长采用保守内存，不把 HTTP/strm 一律当整文件。Trickplay 保持独立图片，不声称顺带修复已有预览问题。UI 显示真实源站路由，禁用服务端压码动作；HLS 可有源自身码率，不宣传直连必然最高原画。普通媒体码率偏好保留。

### 10.2 P0：证据与机制

记录实际工作区差异、锁定 Flutter/Dart/media_kit/libmpv/FFmpeg 与平台配置。按第 5 节固定分类、选源、错误 fixture；验证原生 URL、清头、后续请求边界与轨道/字幕实际序列化能力。重点为目标 OpenList 渐进播放及跳转。

交付平台/依赖/执行机制/结果矩阵，区分 tested、unsupported、unverified；不支持组合列明发送前拒绝点。没有机制证据不将能力标通过；可继续独立模型测试，不能发布目标直连。未知普通样本及 NoCompatibleStream 取舍列入兼容表，不修改规则掩盖失败。

### 10.3 P1：协议与资源通路

实现请求前上下文、候选 ID 固定、正向分类表、取消/请求预算、源快照和原始 URL/headers；Bootstrap 接双入口，适配普通/离线。跨源 selection draft 在本阶段首次新源请求前即生效，不能等 P2 才停止发送旧索引。

门槛：已知 STRM 在 I/O 前拒绝强制转码；跨组不换源；源数据不混配；不支持原生组合提前失败。回归普通媒体分类与原有协商。

### 10.4 P2：恢复、上报周期、轨道与字幕

封住各回退入口，拆开 engine-only reopen 与终止周期；实现周期延续/更换/有界退场。完成 TrackMapper、跨源选择提交、异步 loader 接现有状态机、唯一字幕原生通道与文件租约、UI/已应用状态上报。

门槛：本地重开不重复 Start/Stopped；新源首次请求无旧索引；字幕慢不阻塞视频；旧原生副作用不被误报为取消；双入口/跨账号/退出时不串源、不串头、不自动恢复失焦输出。

### 10.5 P3：回归与真实链路

执行全量检查和实际平台构建，在锁定二进制、Android/iOS/iPadOS 目标设备验证网络、字幕、周期和双入口；取得真实 PlaybackInfo/OpenList 脱敏样本与请求记录。补实现/验收文档。

分批审阅但不发布只替换 URI 的中间版本。本次仅提交计划，以上阶段均为待执行任务；后续授权不涵盖无关分支合并。

## 11. 测试矩阵

表中构造轨道、源 A/B 和故障时序均为测试设计，不是用户设备实测。A/B 多数可 fake 验证；C 的网络保证和实际字幕最终状态需要锁定原生引擎证据。

### 11.1 解析、协议与元数据

| ID | 场景与必须断言 |
|---|---|
| A01 | 标准 HTTP STRM 打开原始 URL，route=sourceDirect。 |
| A02 | STRM 解析后容器变 mp4/mkv，正向来源仍保持 strict；多版本不传播顶层标记。 |
| A03 | 普通源 A/STRM 源 B：只按选中源证据授权。 |
| A04 | 源缺失/重复/冲突/恢复消失：确定错误，不造 ID、不改版。 |
| A05 | 磁盘/空/相对/嵌套 STRM 地址：最多一次详情，不请求视频端点兜底。 |
| A06 | 签名、重复键、空值、api_key、编码：原生实际 path/query 保真。 |
| A07 | LAN/IsRemote=false 合法源不被误拒绝。 |
| A08 | 初始与后续非法协议/回环/userinfo/控制字符安全拒绝。 |
| A09 | 三种严格 payload 保留全部 flags、固定 ID 与关闭字幕语义。 |
| A10 | plan 不存在时已知 STRM 的 forceTranscode 不发请求即拒绝；unknown 先识别。 |
| A11 | 详情与两组预算不重复，最坏七请求/30 秒，取消触达 HTTP。 |
| A12 | 401/403/429/NotAllowed/RateLimitExceeded 不被 Path 覆盖。 |
| A13 | NoCompatibleStream 按 STRM/识别普通的明确规则；supports=false 不假冒权限错误。 |
| A14 | A/B 不同剪辑时长、同 index 不同语言：元数据不串版。 |
| A15 | 新 URL+新头/空头原子替换，不以旧头填空；详情不混头。 |
| A16 | RequiresOpening/无限源排除；意外资源只清理明确自有项。 |
| A17 | 单源 File+普通路径进入正常组；只有容器/隐藏路径按 unknown 规则并记录兼容限制。 |
| A18 | 识别后响应顺序/flags 变化，跨组与兼容重试仍固定候选 ID。 |
| A19 | A 证据不能授权 B；候选缺失不能重跑默认选源。 |
| A20 | 非法必需头、大小写冲突、CRLF/Host/固定 Range 明确拒绝；合法头与空集合正确传递。 |

### 11.2 生命周期、轨道与字幕

| ID | 场景与必须断言 |
|---|---|
| B01 | open/ready/解码失败 strict 不回 Emby。 |
| B02 | Emby 中文 index=2、原生英文 id=2：不得数字误匹配。 |
| B03 | 多同语轨/缺元数据/无可信索引：歧义不猜，默认与显式失败区分。 |
| B04 | 禁止音轨/码率动作不先停有效视频，普通媒体行为回归。 |
| B05 | seek/运行恢复/缓存重开保持固定源、strict、API 与预算。 |
| B06 | 源 403/404 与 Emby 鉴权错误分离，不误登出或无界刷新。 |
| B07 | 字幕慢/超时，视频仍 ready/续播/暂停准备；上报不虚构字幕成功。 |
| B08 | 自动中文/禁用/重选、下载中快速选择，旧任务不覆盖。 |
| B09 | 字幕与音轨交错完成，旧 plan 不覆盖当前上报快照。 |
| B10 | 超大/无长度/解压后超限响应，实收/期限/取消/清理有效。 |
| B11 | 活动租约和在途预留累计超 32 MiB：不删正在使用的文件，拒新字幕不影响视频。 |
| B12 | 图片→STRM→图片快滑，失焦无输出，唯一原生资源租约不竞争。 |
| B13 | 全屏/内嵌、playAfterReady=false、前后台保持同一路由认证及播放意图。 |
| B14 | A/B 服务器媒体 ID 相同，旧地址/字幕不串头、文件和上报。 |
| B15 | 同 scope 重新登录，旧 API 结果失效。 |
| B16 | open/subtitle/dispose 逻辑超时与原生晚完成，屏障/静默/隔离不伪造完成。 |
| B17 | 下一集与显式换普通版本重判策略，不带旧头、不误作自动回退。 |
| B18 | Start 后纯缓存降级/引擎重开再退出，同延续 cycle 的 Start/Stopped 各一次。 |
| B19 | Start 在途、Stopped 超时后晚回：只影响自己周期，事件网络顺序与绑定身份正确。 |
| B20 | URL 刷新同非空会话 ID 延续；不同 ID/null 不擅自视作同周期；退场超预算不自动激活。 |
| B21 | A index=2 中文、B index=2 英文：B 首次请求无 A 旧数值；关闭意图可保留。 |
| B22 | 同源恢复保留选择、跨源重置；候选预检失败不污染旧播放。 |
| B23 | 原生字幕 A 阻塞→选 B→关闭→A 晚完成：实际最终关闭，fake 模拟真实副作用。 |
| B24 | loader 与旧 DeliveryUrl 不双载；旧 nativeFuture 未终结不被逻辑取消冒充安全结束。 |
| B25 | 原生字幕永不结束：明确 unconfirmed/隔离，不伪报关闭，不无限校正或转码。 |

### 11.3 原生网络与既有功能

| ID | 场景与必须断言 |
|---|---|
| C01 | 无头/普通头/敏感头能力组合，unverified/unsupported 提前拒绝。 |
| C02 | 同源/跨源/多跳/循环/HTTPS 降级，逐请求执行限制、超五跳失败。 |
| C03 | Range 再请求改变目的仍限制，不返回 Emby 视频端点。 |
| C04 | manifest/子清单/分片/密钥跨源，授权不扩散，未支持组合不先发敏感请求。 |
| C05 | Emby→源 A→源 B→空头源，原生头/Cookie/属性不残留。 |
| C06 | 源视频/Emby 字幕/第三方字幕三种认证隔离，包括字幕跳转。 |
| C07 | HTTP 成功但登录页/错误内容，不能伪报媒体或字幕成功。 |
| C08 | 有限渐进/HLS/DASH/未知形式或时长，缓存与空间安全正确。 |
| C09 | 普通媒体/离线/Trickplay/会话回归，IsPaused/位置/已应用轨道真实。 |
| C10 | 日志、异常、原生日志和完整诊断导出不含凭据、签名、真实 URL/媒体名。 |
| C11 | 原生字幕交错、关闭与迟到操作：实际轨道/画面、UI 与上报一致。 |
| C12 | 真实 Emby 上同源本地重开、周期刷新和最终退出，上报访问序列与设计相符。 |

## 12. 证据、质量门槛与回滚

使用可观测 Emby 与至少两个受控媒体 origin，覆盖 Range、签名、所需头、同/跨源跳转和字幕；真实样本必须包含目标 OpenList 地址，不只一个无认证 mp4。

证据同时包括：route=sourceDirect/禁止中转的分类日志；设备实际向源读取；首播/续播/seek/失败恢复无 Emby 视频传输请求；控制、字幕、Trickplay 与上报正常；外部目标未收到不属于它的凭据。本地重开与周期 Start/Stopped 序列、字幕实际最终选择也需记录。

TLS 连接主机记录不能单独证明头安全；结合受控端点日志。源内部代理拓扑另标已验证/未知。分享证据前脱敏；普通及完整日志只记录固定类别，不输出 rawUrl、host/path/query、签名、Cookie、私有头值、媒体名。

实现时先记录基线，再执行：

```bash
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
git diff --check
```

执行实际仓库 Android 构建与 iOS 工作流，SDK/Xcode/ABI 以锁定配置为准。构建不替代原生或实机验证。验收报告建议落在 `docs/acceptance/2026-09-strm-source-direct-play-acceptance.md`，能力矩阵可作为其章节，不必为形式新建多个文档。

回滚为恢复此前稳定提交/构建，不是隐藏开启 Emby 中转。最终报告分别列代码、静态检查、单元、平台构建、原生能力、真实链路和未支持组合；未执行填 NOT_RUN。文档提交不能填成任何运行项通过。

## 13. 本轮交付状态与来源

| 项目 | 本轮状态 |
|---|---|
| R1—R6、T1—T4 进入统一 v3 | 文档已完善，文件清单/阶段/测试同步。 |
| GitHub 文档交付 | 由承载本文件的提交记录；范围仅本计划。 |
| 源码实施、测试、构建、原生/实机验证 | 尚未执行。 |
| 用户本地工作区和未来 HEAD 差异 | 后续实施前核对，不假定。 |
| 原生 OpenList 跳转能力、真实 Path/headers/字幕 | P0/P3 待验证，不预先承诺全兼容。 |

本轮文档范围至此收口，可按授权进入 P0 和针对性实现；不继续新增通用网络或播放器架构。原生能力不满足目标是应报告的技术阻塞，不以删约束或把未验证改为通过解决。

仓库事实来自前轮对以下不可变提交的读取，本轮重新确认 main 未变化并针对 T1—T4 整合。协议链接是语义参考，不代替锁定服务端/二进制验证；实施时复核。

- [S1：源码基线](https://github.com/jsdfhasuh/emby_my_client/commit/ab5303652269b3ae9f9d85f5b4d3de96376a9e0e)
- [S2：Emby API](https://github.com/jsdfhasuh/emby_my_client/blob/ab5303652269b3ae9f9d85f5b4d3de96376a9e0e/lib/data/emby_api.dart)
- [S3：Bootstrap](https://github.com/jsdfhasuh/emby_my_client/blob/ab5303652269b3ae9f9d85f5b4d3de96376a9e0e/lib/playback/playback_session_bootstrap.dart)
- [S4：内嵌播放](https://github.com/jsdfhasuh/emby_my_client/blob/ab5303652269b3ae9f9d85f5b4d3de96376a9e0e/lib/playback/media_kit_inline_playback_session.dart)
- [S5：Controller](https://github.com/jsdfhasuh/emby_my_client/blob/ab5303652269b3ae9f9d85f5b4d3de96376a9e0e/lib/playback/playback_controller.dart)
- [S6：Engine](https://github.com/jsdfhasuh/emby_my_client/blob/ab5303652269b3ae9f9d85f5b4d3de96376a9e0e/lib/playback/playback_engine.dart)
- [S7：TrackMapper](https://github.com/jsdfhasuh/emby_my_client/blob/ab5303652269b3ae9f9d85f5b4d3de96376a9e0e/lib/playback/track_mapper.dart)
- [S8：ServerScope](https://github.com/jsdfhasuh/emby_my_client/blob/ab5303652269b3ae9f9d85f5b4d3de96376a9e0e/lib/core/server_scope.dart)
- [S9：AppController](https://github.com/jsdfhasuh/emby_my_client/blob/ab5303652269b3ae9f9d85f5b4d3de96376a9e0e/lib/state/app_controller.dart)
- [S10：模型](https://github.com/jsdfhasuh/emby_my_client/blob/ab5303652269b3ae9f9d85f5b4d3de96376a9e0e/lib/models/emby_models.dart)
- [S11：Emby PlaybackInfo/媒体源定义](https://dev.emby.media/reference/RestAPI/MediaInfoService/postItemsByIdPlaybackinfo.html)
- [S12：mpv 手册](https://mpv.io/manual/stable/)
- [S13：PlaybackSessionReporter](https://github.com/jsdfhasuh/emby_my_client/blob/ab5303652269b3ae9f9d85f5b4d3de96376a9e0e/lib/playback/playback_session_reporter.dart)

## 14. 交给实施者的摘要

以本计划和实际工作区差异为起点。P0 优先确认目标 OpenList 路径和锁定原生机制；Bootstrap 统一双入口。I/O 前建立三态分类和约束，正向证据按具体源，跨组固定 ID；严格 flags 不在兼容请求中丢失。源 URL/headers/元数据整体处理，所有恢复保持直连和身份。本地引擎重开延续上报周期，不无条件 stop/activate；刷新更换会话有有界退场规则。跨源首次请求前清除旧轨道数字，保留明确关闭/默认意图。TrackMapper 不凭数字巧合；字幕 loader 接入现有状态机，下载不阻塞视频，原生应用只走唯一通道，最新选择按实际副作用确认。保留原生屏障、租约、账号隔离、缓存安全和脱敏。按矩阵分别交付单元、构建、原生和真实链路证据；未另获授权不实施源码、不合并其他分支、不修改服务端。
