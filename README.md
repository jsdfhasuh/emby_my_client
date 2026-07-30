# Emby Flutter Client

一个面向 Android 手机的轻量 Emby 客户端。

## 已实现

- Emby 服务器地址、用户名和密码登录
- 访问令牌安全存储与自动恢复会话
- 首页继续观看、最近添加和媒体库
- 媒体库分页浏览与全库搜索
- 电影、剧集、季和单集详情
- 基于 `PlaybackInfo` 的 DirectPlay / DirectStream / Transcode 协商
- `media_kit` / libmpv 视频播放、断点续播和播放进度回报
- HTTP 局域网服务器与 HTTPS 服务器

播放架构参考了
[Moonfin-Core](https://github.com/Moonfin-Client/Moonfin-Core)
的服务器适配层和媒体流解析思路，当前项目保持为独立、精简的 Android 实现。

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

调试 APK 使用调试签名。正式发布前需要更换
`applicationId`、应用图标，并配置 Android release 签名。
