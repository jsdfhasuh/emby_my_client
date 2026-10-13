# Emby Flutter Client

一个面向 Android 手机的轻量 Emby 客户端。

## 已实现

- Emby 服务器地址、用户名和密码登录
- 访问令牌安全存储与自动恢复会话
- 首页继续观看、最近添加和媒体库
- 媒体库服务端分页浏览、筛选/排序、滚动位置提示、名称升序 `# / A-Z` 快速导航与
  全库搜索
- 电影、剧集、季和单集详情
- 电影、电视剧和单集演员列表，以及人物资料与服务端分页作品
- 基于 `PlaybackInfo` 的 DirectPlay / DirectStream / Transcode 协商
- `media_kit` / libmpv 视频播放、断点续播和播放进度回报
- HTTP 局域网服务器与 HTTPS 服务器

播放架构参考了
[Moonfin-Core](https://github.com/Moonfin-Client/Moonfin-Core)
的服务器适配层和媒体流解析思路，当前项目保持为独立、精简的 Android 实现。

## 下载构建

安装包在 [GitHub Releases](https://github.com/jsdfhasuh/emby_my_client/releases/latest)
中下载。`main` 每次构建通过测试、Android 原生检查和 iPadOS 打包检查后，会自动发布
`build-构建号`，附上通用及分架构 Debug APK、TrollStore IPA 和 SHA-256 校验文件。
PR 和失败构建不会发布，原始诊断产物仍保留在 Actions Artifacts 中。

公开 Release 的 Android APK 由发布步骤使用固定签名，缺少签名 Secrets 或证书不符时停止发布。
它们仍是 Debug 构建；iPadOS IPA 面向 TrollStore，不是 App Store 安装包。
旧版随机调试签名不能被新签名直接覆盖，请先保留旧应用及数据。
稳定版名称为 **Emo Emby 稳定版**，Android 包名固定为 `com.jsdfhasuh.emoemby`，
可与旧版 `com.example.embyclient` 并存。新版需重新登录，旧下载和设置不会自动迁移。
请安装公开 Release 的最终 APK；Actions 中的原始调试产物不是固定签名安装包。
签名配置和更新限制见 [版本与手动更新说明](docs/implementation/2026-10-app-updates.md)。

## 开发

需要 Flutter 3.38 或更高版本，以及可用的 Android SDK。

```powershell
flutter pub get
flutter analyze
flutter test
flutter run
```

构建通用调试包：

```powershell
flutter build apk --debug
```

按 CPU 架构生成更小的安装包：

```powershell
flutter build apk --debug --split-per-abi
```

本地 Debug APK 使用开发用调试签名；公开 APK 由受信任的发布 job 重新签名并验证。
本地 Release 构建不再回退到调试签名。长期签名密钥保存在源码之外，
由所有者亲自配置 GitHub Secrets；仓库仅保存公开证书指纹。

## 人物作品与大型媒体库导航里程碑

里程碑 A、B、C 的代码、自动化测试和分 ABI Debug APK 构建已完成。人物数据只来自
当前 Emby 服务器，作品只查询电影和电视剧；媒体库位置提示和 `# / A-Z` 导航继续
使用服务端分页与 `NameStartsWith` / `NameLessThan`，不加载完整媒体库。真实 Emby
服务器与 Android 设备验收尚待可用设备执行。
