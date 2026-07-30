# Android TV 设计计划

更新日期：2026-07-30

## 1. 用户场景

- 从 Android TV 主屏启动客户端。
- 只用 D-pad、确认、返回和菜单键完成登录、浏览、搜索和播放。
- 焦点在页面返回、弹窗关闭和列表刷新后回到合理位置。
- 播放时使用遥控器显示控制层、定位、切集和退出。
- 同一业务代码同时支持手机和 TV，不维护两套数据层。

## 2. 首版范围和非目标

首版：

- 独立 Android TV 清单/构建变体。
- Leanback 启动入口、TV banner 和 touchscreen optional。
- 输入模式识别、D-pad 导航、焦点样式和焦点恢复。
- 现有首页、媒体库、详情、搜索和播放器 TV 布局。
- 遥控器播放控制。

非目标：

- 首版不做 Android TV Preview Channel、Watch Next 或全局搜索集成。
- 不支持游戏手柄的所有厂商私有按键。
- 不把手机触摸布局简单放大后宣布 TV 支持。
- 不复制业务 API、Repository 或 PlaybackController。

## 3. Android 工程结构

推荐建立 product flavor 或独立 source set：

```text
android/app/src/mobile/AndroidManifest.xml
android/app/src/androidTv/AndroidManifest.xml
android/app/src/androidTv/res/drawable/tv_banner.*
android/app/src/androidTv/res/mipmap-*/ic_launcher.*
```

TV 清单要求：

- `android.software.leanback` 按 TV 变体要求声明。
- `android.hardware.touchscreen` 设为 `required="false"`。
- 启动 Activity 增加 `LEANBACK_LAUNCHER`。
- 提供符合 Android TV 尺寸和可读性要求的 banner。
- 手机变体不意外出现两个启动图标。

是否共用 applicationId 在发布策略确定后决定；测试阶段可使用 applicationIdSuffix
让手机和 TV 版本并存。

## 4. Flutter 输入与焦点架构

```text
lib/tv/tv_platform.dart
lib/tv/input_mode_tracker.dart
lib/tv/tv_shortcuts.dart
lib/tv/focus_memory.dart
lib/tv/focusable_action.dart
lib/tv/tv_scroll_coordinator.dart
lib/ui/tv/tv_home_shell.dart
lib/ui/tv/tv_player_controls.dart
```

- `InputModeTracker` 区分 touch、keyboard、D-pad 和 gamepad。
- `Shortcuts/Actions` 统一映射方向、select、back、play/pause、菜单和长按。
- 每个路由拥有焦点 Scope，并记录最后一个稳定内容 ID，而不是仅记录列表索引。
- 列表刷新后按内容 ID 恢复；项目消失时选择最近有效项目。
- 焦点移动和滚动由一个协调器处理，避免多个 `ensureVisible` 竞争。
- 弹窗负责捕获焦点，关闭后显式返还触发按钮。

## 5. 布局和交互

- 使用 TV 安全区和固定视觉密度，不按 viewport 宽度缩放字体。
- 焦点状态必须有清晰边框、阴影或尺寸变化，且不导致周围布局跳动。
- 横向行、网格和侧边导航的移动结果可预测。
- 所有核心操作可聚焦；隐藏控件和加载骨架不可获得焦点。
- 长列表使用懒加载和稳定尺寸，图片加载不改变焦点卡片大小。
- 搜索首版使用系统/屏幕键盘，语音搜索单独立项。
- 手机端继续使用当前导航和触摸手势。

## 6. 播放器适配

- 任意遥控器按键可唤起控制层，但方向键不能同时触发 seek 和焦点移动。
- 播放/暂停媒体键直接控制播放。
- 控制层隐藏时，左右键快退/快进或显示时间轴的行为必须固定且可测试。
- 控制层显示时，D-pad 只移动焦点；确认键执行当前控件。
- 返回键先关闭弹层，再隐藏控制层，最后退出播放器。
- 长按 seek 采用有上限的重复步进，松开后只提交一次最终 seek。
- 轨道、清晰度、章节和下一集弹层均能完整使用 D-pad。
- TV 上不显示亮度、音量触摸滑动提示；系统音量交给遥控器。

## 7. 状态和平台能力

- TV 判定使用平台/资源能力，不只依赖屏幕尺寸。
- 焦点记忆可以按路由保存在内存，只有必要的导航偏好持久化。
- Activity 重建后恢复当前路由，再由页面选择合法初始焦点。
- 现有 WebSocket、播放、画中画和会话清理逻辑保持单一实现。
- Watch Next、Preview Channel 和系统 MediaSession 作为独立增量，每项增加原生测试。

## 8. 测试与验收

Widget 测试：

- 方向键、select、back、菜单和媒体键映射。
- 初始焦点、弹窗焦点捕获、路由返回和列表刷新恢复。
- 加载、空状态、错误状态和项目删除后的合法焦点。
- 播放器控制层显示/隐藏及 seek 不重复提交。

集成与真机：

- Android TV 模拟器以及至少一台物理 TV/盒子。
- 冷启动、登录、首页、媒体库、搜索、详情和播放全程不触屏。
- 不同遥控器重复键速率和长按行为。
- 1080p、4K、不同 overscan/显示缩放设置。
- Activity 重建、切后台、网络断开和返回首页。
- TalkBack 基本可读性和焦点顺序。

构建验证：

```powershell
flutter build apk --debug --flavor mobile --split-per-abi
flutter build apk --debug --flavor androidTv --split-per-abi
```

实际命令根据最终 Gradle flavor 和 Dart 入口配置调整。

## 9. 发布步骤

1. TV source set、启动入口、banner 和设备识别。
2. 全局输入映射、焦点主题和调试焦点日志。
3. 登录与首页。
4. 列表、详情和搜索。
5. 播放器和所有弹层。
6. Live TV 节目单。
7. Watch Next 等系统集成另行立项。

手机 APK 的回归构建和触摸测试是每一步的必要门槛。

## 10. GPL 边界

借鉴 Moonfin 的独立 TV 清单、输入模式跟踪、焦点所有权和恢复原则，不复制其
Focus 工具、Android 原生类、Manifest 或 UI 代码。
