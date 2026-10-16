import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../updates/app_update.dart';
import '../updates/update_gateway.dart';

class AppUpdateEntry extends StatefulWidget {
  const AppUpdateEntry({
    super.key,
    this.enabled = true,
    this.gateway = const MethodChannelUpdateGateway(),
  });
  final bool enabled;
  final UpdateGateway gateway;
  @override
  State<AppUpdateEntry> createState() => _AppUpdateEntryState();
}

class _AppUpdateEntryState extends State<AppUpdateEntry> {
  late final Future<InstalledApp> _installed = widget.gateway.installed();
  @override
  Widget build(BuildContext context) => FutureBuilder<InstalledApp>(
    future: _installed,
    builder: (context, snapshot) => ListTile(
      key: const ValueKey('app-update-entry'),
      leading: const Icon(Icons.info_outline),
      title: const Text('版本与更新'),
      subtitle: Text(
        snapshot.hasData
            ? '${snapshot.data!.version} · 构建 ${snapshot.data!.buildNumber}'
            : snapshot.hasError
            ? '点击查看版本信息'
            : '正在读取版本',
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: !widget.enabled
          ? null
          : () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => AppUpdateScreen(gateway: widget.gateway),
              ),
            ),
    ),
  );
}

class AppUpdateScreen extends StatefulWidget {
  const AppUpdateScreen({
    super.key,
    this.source,
    this.gateway = const MethodChannelUpdateGateway(),
  });
  final UpdateSource? source;
  final UpdateGateway gateway;
  @override
  State<AppUpdateScreen> createState() => _AppUpdateScreenState();
}

class _AppUpdateScreenState extends State<AppUpdateScreen> {
  late final UpdateSource _source = widget.source ?? GitHubUpdateSource();
  InstalledApp? _installed;
  AppRelease? _release;
  VerifiedDownload? _download;
  CancelToken? _cancel;
  bool _busy = false;
  bool _loading = true;
  bool _permissionRequired = false;
  bool _handedOff = false;
  double? _progress;
  String? _message;
  String _latestStatus = '尚未检查';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final info = await widget.gateway.installed();
      if (mounted) {
        setState(() {
          _installed = info;
          _loading = false;
          _message = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _message = const UpdateFailure('metadata').message;
        });
      }
    }
  }

  @override
  void dispose() {
    _cancel?.cancel();
    _source.close();
    if (!_handedOff) _discard(_download);
    super.dispose();
  }

  Future<void> _discard(VerifiedDownload? value) async {
    try {
      await value?.discard();
    } catch (_) {
      /* Pruned on a later download. */
    }
  }

  Future<void> _run(Future<void> Function() work) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await work();
    } catch (error) {
      if (mounted) {
        setState(() {
          _message =
              (error is UpdateFailure ? error : const UpdateFailure('network'))
                  .message;
          if (_latestStatus == '正在检查…') _latestStatus = '检查未完成，请重试';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _cancel = null;
          _progress = null;
        });
      }
    }
  }

  Future<void> _check() => _run(() async {
    if (!_handedOff) await _discard(_download);
    if (!mounted) return;
    setState(() {
      _release = null;
      _latestStatus = '正在检查…';
      _download = null;
      _permissionRequired = false;
      _handedOff = false;
    });
    final cancel = _cancel = CancelToken();
    final release = await _source.latest(cancel);
    if (!mounted) return;
    if (cancel.isCancelled) {
      setState(() => _latestStatus = '检查已取消');
      return;
    }
    setState(() {
      _release = release;
      _latestStatus = '检查完成';
      if (!release.isNewerThan(_installed!)) _message = '当前已是最新版本。';
    });
  });

  Future<void> _getPackage(ReleaseAsset asset) => _run(() async {
    final cancel = _cancel = CancelToken();
    VerifiedDownload? downloaded;
    try {
      downloaded = await _source.download(_release!, asset, cancel, (
        received,
        total,
      ) {
        if (mounted && !cancel.isCancelled) {
          setState(() => _progress = received / total);
        }
      });
      if (!mounted || cancel.isCancelled) {
        throw const UpdateFailure('cancelled');
      }
      setState(() {
        _progress = null;
        _message = '下载完成，正在校验安装兼容性…';
      });
      await widget.gateway.validate(downloaded);
      if (!mounted || cancel.isCancelled) {
        throw const UpdateFailure('cancelled');
      }
      setState(() {
        _download = downloaded;
        _message = '校验通过，等待你确认安装。';
      });
    } catch (_) {
      await _discard(downloaded);
      rethrow;
    }
  });

  Future<void> _install() => _run(() async {
    try {
      // Keep the file alive if the page closes while Android opens its UI.
      _handedOff = true;
      final result = await widget.gateway.install(_download!);
      if (!mounted) return;
      setState(() {
        _permissionRequired = result == InstallHandoff.permissionRequired;
        _handedOff = result == InstallHandoff.opened;
        _message = _permissionRequired
            ? '请在系统设置中允许此应用安装更新，然后返回并点击“继续安装”。'
            : '已打开系统安装确认。是否完成安装，以系统结果为准。';
      });
    } on UpdateFailure catch (error) {
      _handedOff = false;
      if (const {
        'signature',
        'package',
        'downgrade',
        'checksum',
        'size',
        'unsupported',
      }.contains(error.code)) {
        final rejected = _download;
        if (mounted) {
          setState(() {
            _download = null;
            _permissionRequired = false;
          });
        }
        await _discard(rejected);
      }
      rethrow;
    }
  });

  @override
  Widget build(BuildContext context) {
    final app = _installed;
    final release = _release;
    ReleaseAsset? asset;
    String? assetError;
    if (app != null &&
        release != null &&
        release.isNewerThan(app) &&
        app.platform == UpdatePlatform.android) {
      try {
        asset = release.apkFor(app);
      } on UpdateFailure catch (error) {
        assetError = error.message;
      }
    }
    return Scaffold(
      appBar: AppBar(title: const Text('版本与更新')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('emo-emby', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text(
            app == null
                ? (_loading ? '正在读取版本…' : '版本信息不可用')
                : '已安装版本 ${app.version}\n构建号 ${app.buildNumber}',
          ),
          const SizedBox(height: 12),
          Text(
            release == null
                ? '最新版本：$_latestStatus'
                : '最新公开版本：1.0.${release.number}（${release.tag}）',
            key: const ValueKey('latest-version'),
          ),
          const SizedBox(height: 16),
          const Text('仅在你点击时检查 GitHub 公开版本。下载和安装均由你确认。'),
          if (app?.platform == UpdatePlatform.ios) ...[
            const SizedBox(height: 12),
            const Text('iPadOS 使用 TrollStore 手动安装 IPA，本页不会自动安装。'),
          ],
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const ValueKey('check-update'),
            onPressed: _busy || _loading
                ? null
                : app == null
                ? _load
                : _check,
            icon: const Icon(Icons.refresh),
            label: Text(app == null ? '重试读取版本' : '检查更新'),
          ),
          if (_busy) ...[
            const SizedBox(height: 16),
            LinearProgressIndicator(value: _progress),
            if (_progress != null)
              Text('下载中 ${(_progress! * 100).toStringAsFixed(0)}%'),
            if (_cancel != null)
              TextButton(
                onPressed: () => _cancel?.cancel(),
                child: const Text('取消'),
              ),
          ],
          if (_message != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(_message!, key: const ValueKey('update-message')),
            ),
          if (release != null) ...[
            const Divider(),
            Text('更新摘要', style: Theme.of(context).textTheme.titleLarge),
            if (app?.releaseNumber == null)
              const Text('此旧版本未记录可比较的发布号；安装前会核验实际版本与签名。'),
            const SizedBox(height: 12),
            Text(
              releaseChangelogSummary(release.notes),
              key: const ValueKey('release-summary'),
            ),
            if (release.notes.trim().isNotEmpty)
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('完整更新说明'),
                children: [SelectableText(release.notes)],
              ),
            const SizedBox(height: 12),
            SelectableText(release.page),
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: release.page));
                if (context.mounted) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('已复制发布页链接')));
                }
              },
              child: const Text('复制发布页链接'),
            ),
          ],
          if (assetError != null) Text(assetError),
          if (asset != null && _download == null) ...[
            Text(
              '适用安装包：${asset.name}\n大小：${(asset.size / 1024 / 1024).toStringAsFixed(1)} MB',
            ),
            const SizedBox(height: 12),
            FilledButton(
              key: const ValueKey('download-update'),
              onPressed: _busy ? null : () => _getPackage(asset!),
              child: const Text('下载并校验'),
            ),
          ],
          if (_download != null) ...[
            if (_permissionRequired)
              OutlinedButton(
                onPressed: _busy
                    ? null
                    : () => _run(widget.gateway.allowInstalls),
                child: const Text('允许此应用安装更新'),
              ),
            FilledButton(
              key: const ValueKey('install-update'),
              onPressed: _busy ? null : _install,
              child: Text(
                _permissionRequired || _handedOff ? '继续安装' : '打开系统安装确认',
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A short excerpt of actual release notes, with the original available below.
String releaseChangelogSummary(String notes) {
  final lines = notes
      .split('\n')
      .map((line) => line.trim())
      .where(
        (line) =>
            line.isNotEmpty && !line.startsWith('```') && !line.startsWith('#'),
      )
      .take(3)
      .toList();
  if (lines.isEmpty) return '此版本未提供更新摘要，请查看完整更新说明。';
  return lines
      .map((line) {
        final plain = line.replaceFirst(RegExp(r'^[-*+]\s+'), '');
        final runes = plain.runes.toList();
        return runes.length > 160
            ? '${String.fromCharCodes(runes.take(160))}…'
            : plain;
      })
      .join('\n');
}
