# 版本展示与手动更新

## 范围

登录页信息按钮、设置页「版本与更新」显示安装包的实际版本和构建号。仅点击「检查更新」时访问 `jsdfhasuh/emby_my_client` 的 GitHub 公开 latest Release，不在后台轮询，不使用 Emby 会话、令牌或账号请求头。

Android 稳定版 applicationId 固定为 `com.jsdfhasuh.emoemby`，系统显示名为「Emo Emby 稳定版」，与旧版 `com.example.embyclient` 并存。用户已明确同意该方案。iOS Bundle ID 未变，旧应用和数据未被操作。

Android 流程：查看发布说明 → 按设备实际 ABI 选择 APK（缺少对应包时使用通用包）→ 用户点击下载 → 有界流式下载、取消及错误重试 → 校验 Release 资产大小和同一 Release 的 SHA256SUMS.txt → 原生核验包名、安装包实际版本、最低系统版本、ABI 和当前签名 → 用户点击打开系统安装确认。安装前再次核验文件哈希及安装兼容性。下载完成、校验完成和系统安装界面已打开是不同状态；客户端不把交接成功当成安装成功。

iPadOS 复用已有原生版本元数据接口，提供发布说明、发布页链接和 TrollStore 手动安装提示，不提供 APK 安装操作。

Android 本地方案增加 `REQUEST_INSTALL_PACKAGES` 声明；用户仍需在系统界面允许此来源并确认安装。FileProvider 不导出，只临时授予读取权限，路径限定为 `cache/app_updates/`。损坏、取消或被拒绝的包会清理；交给系统安装器的包保留，后续下载时清理超过 24 小时的遗留缓存。没有新增存储权限，也没有修改 GitHub workflow 的权限。

## 版本规则

CI 的 `scripts/release/build_version.py` 根据同一 workflow 的 `GITHUB_RUN_NUMBER=N` 生成：

- Android / iOS 显示版本：`1.0.N`。
- Android 基础 versionCode：`N * 10000`。
- iOS build number：`N`。

Flutter 为分架构 APK 加 1000/2000/4000 偏移，因此给每个构建保留 10000 的间隔，保证下一次通用 APK 能高于上一次分架构包。例如 N=179 时通用包是 1790000，ARM64 包是 1792000。脚本限制 N≤209999，避免超过 Android 版本上限。pubspec 和锁文件不变。

版本比较使用整数，不按字符串排序。旧的 `1.0.0` / 2001 无法标识 build-177 还是 build-178，界面明确提示无法从旧元数据推断发布号，并在安装前以 APK 的真实 versionCode 和签名判定。更换 workflow、重置运行编号、更改版本格式或密钥轮换时，需要重新规划版本迁移，不能直接重用此计数规则。

## 签名调查与发布前阻塞

基线：`1ccdf620d3bbd966ead5774e90b37b971787c2c2`，默认分支 main。

公开 ARM64 APK 均通过 Android SDK `apksigner verify --verbose --print-certs`；完整文件哈希与各自公开 SHA256SUMS.txt 一致。`aapt dump badging` 显示两者都是包名 `com.example.embyclient`、versionName `1.0.0`、versionCode `2001`。证书 SHA-256：

- build-177：`d0ac6edd5730551ab00d0e231572378e04cd1dff075d8f6f3fa02bd22ffce293`
- build-178：`44b940c8c0c61070d5d8661b53ce949f34f0b51f98ad233ae6ddede6587a758d`

两者各有一个 Android Debug 签名者，验证为 APK Signature Scheme v2。证书不一致，不能普通覆盖升级。基线仓库只配置 debug 签名，没有持久 keystore 恢复步骤。用户随后确认没有保存历史密钥，并明确授权创建本地长期签名；GitHub Secrets 的录入由用户亲自进行。

当前实现严格要求安装包与已安装应用的当前签名者集合一致。任意新密钥、附加签名者或未经单独设计的轮换都被拒绝，并显示“安装包签名与当前应用不兼容，无法覆盖升级”，不会提示卸载。

### 已实现的固定签名门禁

长期 RSA 4096 / PKCS12 密钥已在所有者电脑的独立持久目录生成，目录只允许当前 Windows 用户和 SYSTEM 访问。随机密码使用当前用户的 Windows DPAPI 保护。生成流程拒绝覆盖已有目录；重跑只返回已存在的公开状态。仓库不包含密钥或密码，只有公开指纹文件 `scripts/release/android-signing-certificate.sha256`：

`873973f399c1c36de9cde8efddd0d4b1b205855d6de8f4db1ce4150945da00b5`

用户需在仓库 Settings → Secrets and variables → Actions 中亲自建立两个 Secret：

- `ANDROID_SIGNING_KEYSTORE_BASE64`：PKCS12 文件的 Base64 编码。
- `ANDROID_SIGNING_PASSWORD`：该 PKCS12 的密码；key password 与 store password 相同。

alias 固定为 `emo-emby-release`，不是 Secret。本地目录有用户手动操作的复制助手及备份说明，助手不上传或打印值；本轮没有使用剪贴板或录入 Secrets。应另行把加密 keystore 备份到可信加密离线存储，并把密码保存到自己的密码管理器。DPAPI 文件依赖同一 Windows 用户和电脑，不能作为跨机器恢复的唯一备份。

`sign_android_release.py` 只允许原仓库 main 的 push/workflow_dispatch 发布运行。Secrets 只注入已有发布 job 的签名步骤，PR 和质量检查 job 不接收它们。四个已测试 APK 在私有临时目录内用同一密钥重新签名；密码通过 `env:` 传给 apksigner，不放进命令参数，工具异常输出不回显。每个包必须由官方 apksigner 验证通过，且只有一个签名者、指纹与仓库固定值一致。签名后再用 aapt 检查真实包名、显示名、versionName、含 ABI 偏移的 versionCode，以及每个文件的 CPU 架构。全部通过后才输出可发布文件。临时密钥随步骤清理。

缺少 Secret、错误密码、错误证书、重复或缺少 APK、旧包名或错误版本/架构都停止流程，不回退到随机 debug key。格式 2 的签名验证记录绑定固定包名、构建号和四个最终 APK 的哈希，`prepare_release.py` 必须验证该记录后才生成公开 SHA256SUMS.txt 和发布目录，避免误发原始调试签名输入。现有 GitHub 权限和 main 发布条件不变。Gradle 的 Release 构建也已移除调试签名回退；日常 Debug 构建仍可使用开发用调试签名。用户应使用公开 Release 最终包，不安装 Actions 中的原始调试签名中间产物。

### 单用户首次迁移

新密钥不能从旧 APK 恢复私钥，也不能让新签名覆盖旧安装。已按授权设置稳定版独立包名，旧应用保留，新版正常登录。FileProvider authority 由 applicationId 派生，实际为 `com.jsdfhasuh.emoemby.app_updates`；原生安装检查对比运行时 packageName，所以旧包即使使用相同新密钥也会被拒绝。签名不匹配同样被拒绝，没有放宽更新校验。

新包不能自动读取旧包的数据库、下载和安全存储；现有诊断日志导出不是完整备份。服务器已经保存的数据可重新请求，本地独有数据仍需保留旧版再处理。本轮没有卸载、清数据或连接真实账号。代码层面准备并存不等于真机安装或迁移已经完成。

参考：[Android 应用签名](https://developer.android.com/studio/publish/app-signing)、[版本管理](https://developer.android.com/studio/publish/versioning)、[FileProvider 配置](https://developer.android.com/training/secure-file-sharing/setup-sharing)。

## 验证边界

本地 Flutter 3.38.9 / Dart 3.10.8；JDK 17；缓存 Kotlin 2.2.20 和 Android API 36。新增更新服务及 Widget 测试连同登录、空密码、有密码、账号、设置回归共 124 项通过；Flutter analyze 和格式检查通过；版本、签名和发布脚本 27 项测试通过；Android 兼容性策略 18 项 JVM 测试通过，包括稳定版拒绝旧包名。签名及包名阶段没有更改 Dart/Kotlin 功能代码，新增原生用例并重新独立编译入口和通道通过。官方 apksigner 已在本地使用新密钥签署公开 APK 的临时副本并验证指纹一致，DPAPI 密码恢复也通过；测试副本随后删除，未安装或发布。

完整 Gradle 编译任务的 dry-run 在启动 daemon 时因本机 `Unable to establish loopback connection` 失败。使用已有缓存依赖进行独立 Kotlin 编译和 JUnit 测试，不创建 debug keystore、不打包、不启动模拟器。独立编译不能代替 Gradle 资源合并、设备 PackageManager、系统未知来源设置、FileProvider 读权限和实际安装的验收。

提交前尚未运行本轮完整 Flutter 全量套件、GitHub Actions、新 APK/IPA 编译构建、真实 Emby 登录、真机安装或升级。完整 Gradle 阻塞没有反复重试。未验证 iOS/TrollStore 实机行为及旧安装的数据迁移。此前下载后播放的实机测试仍是独立未完成事项。用户已手动录入两个 Secrets，并明确授权正常推送 main、沿用自动构建和公开 Release 流程。已只读确认两个 Secret 名称存在且引用一致；GitHub 不提供值读回，内容有效性由真实发布签名步骤验证。本节记录提交前验证状态，实际云端构建及发布结果以该提交的 Actions 和 Release 为准。
