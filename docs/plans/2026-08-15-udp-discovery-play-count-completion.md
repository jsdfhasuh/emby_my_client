# UDP 服务器发现、播放次数排序与排序记忆完成记录

## 状态

```text
IMPLEMENTATION_COMPLETE
REAL_DEVICE_ACCEPTANCE=PASSED
MERGED_TO_INTEGRATION=PASSED
MAIN_INTEGRATION=PASSED
```

## 最终范围

本轮已完成并通过实机验证的三个功能：

1. 媒体库增加服务端 `PlayCount` 升序和降序排序；
2. 按服务器、账号和媒体库分别保存并恢复排序字段与方向；
3. Android 与 iPadOS 登录页通过 UDP `7359`、请求消息 `who is EmbyServer?` 自动发现同一局域网中的 Emby 服务器。

## 合并记录

### 播放次数排序与排序记忆

- 功能分支：`agent/library-play-count-sort`
- 功能 HEAD：`d31ae278034a91a5a231cb2ee0139167ddde4fd7`
- Pull Request：`#2`
- 合并目标：`agent/ios-core-real-device-remediation`
- 合并提交：`7ba6a02fa9cc9c4af2cb6dfa4e42a8c006f9ad5c`

### UDP 发现与 iPadOS multicast entitlement

- 功能分支：`agent/ipados-udp-server-discovery`
- 功能 HEAD：`34f71f01e9895448f8615e3c059a43d5bd71eace`
- Pull Request：`#3`
- 合并目标：`agent/ios-core-real-device-remediation`
- 合并提交：`c207108bcdb62c3196aeaf0e2726b641d651b138`

### 主分支

`main` 已从 `9b74b6216e25375ee2e44e8019bfbff9546a5f51` 快进到：

```text
c207108bcdb62c3196aeaf0e2726b641d651b138
```

该更新没有 rebase、squash 或 force-push。

## 自动化证据

### PR #2

- 全量 Flutter 测试：`878 passed`
- GitHub Actions Run：`31877714051`（Run #107）
- `Quality and Android`：通过
- `iPadOS device IPA`：通过

### PR #3

- 全量 Flutter 测试：`892 passed`
- Discovery 定向测试：`14 passed`
- Stage C 回归测试：`105 passed`
- GitHub Actions Run：`31879377381`（Run #108）
- `Quality and Android`：通过
- `iPadOS device IPA`：通过
- entitlement 正向与负向门禁：通过

最终组合 IPA：

```text
emby-ios-core-a6dc7e19207b-108.ipa
SHA-256: 91ef7b846268653457603da2efdd507b544ec509b92040ac361ae60226c077cd
```

最终合并树与 Run #108 测试树一致。

## 实机验收

设备所有者已确认以下三个功能均无问题：

- `PLAY_COUNT_SORT=PASSED`
- `SORT_PERSISTENCE=PASSED`
- `UDP_LAN_DISCOVERY=PASSED`

验收包含排序升降序、重新进入后的排序恢复、局域网服务器发现及登录页交互。

## 已知限制

```text
UDP_SEND_ZERO_RESULT=NOT_ADDRESSED
DIRECTED_BROADCAST_ASSUMES_SLASH_24=KNOWN_LIMITATION
APPLE_SIGNED_MULTICAST_PROFILE=OWNER_DEPENDENT
```

上述限制不影响本轮已完成的 Android 与 iPadOS/TrollStore 实机验收结果。

## 归档说明

原文件 `2026-08-14-udp-discovery-and-play-count-sort.md` 保留为实施前的计划快照；本文件是实施、测试、实机验收和合并后的最终状态记录。
