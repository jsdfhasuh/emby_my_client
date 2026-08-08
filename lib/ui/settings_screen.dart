import 'package:flutter/material.dart';

import '../core/diagnostic_log.dart';
import '../settings/library_category_settings.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.settings,
    required this.accountName,
    required this.onLibraryCategorySettingsChanged,
    required this.onDeleteAccountData,
  });

  final LibraryCategorySettings settings;
  final String accountName;
  final Future<void> Function(LibraryCategorySettings settings)
  onLibraryCategorySettingsChanged;
  final Future<void> Function() onDeleteAccountData;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late LibraryCategorySettings _settings;
  bool _saving = false;
  bool _deletingAccountData = false;

  @override
  void initState() {
    super.initState();
    _settings = widget.settings;
  }

  Future<void> _update(LibraryCategorySettings settings) async {
    if (_saving || _deletingAccountData || settings == _settings) return;
    final previous = _settings;
    setState(() {
      _settings = settings;
      _saving = true;
    });
    try {
      await widget.onLibraryCategorySettingsChanged(settings);
    } catch (error, stackTrace) {
      if (!mounted) return;
      setState(() => _settings = previous);
      DiagnosticLog.instance.error(
        'settings',
        'Library category settings update failed',
        error: error,
        stackTrace: stackTrace,
      );
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('设置保存失败，请重试')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _confirmDeleteAccountData() async {
    if (_deletingAccountData) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除此账户数据？'),
        content: Text(
          '将从本机删除“${widget.accountName}”的全部离线媒体、未完成下载、'
          '离线观看进度和账户设置，并退出登录。此操作无法撤销。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除并退出'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _deletingAccountData = true);
    try {
      await widget.onDeleteAccountData();
      if (mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    } finally {
      if (mounted) setState(() => _deletingAccountData = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_deletingAccountData,
      child: Scaffold(
        appBar: AppBar(title: const Text('设置')),
        body: ListView(
          padding: const EdgeInsets.symmetric(vertical: 12),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 10),
              child: Text(
                '媒体库快捷分类',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            _categorySwitch(
              icon: Icons.movie_outlined,
              label: '电影',
              value: _settings.showMovies,
              onChanged: (value) =>
                  _update(_settings.copyWith(showMovies: value)),
            ),
            _categorySwitch(
              icon: Icons.tv_outlined,
              label: '剧集',
              value: _settings.showSeries,
              onChanged: (value) =>
                  _update(_settings.copyWith(showSeries: value)),
            ),
            _categorySwitch(
              icon: Icons.video_library_outlined,
              label: '视频',
              value: _settings.showVideos,
              onChanged: (value) =>
                  _update(_settings.copyWith(showVideos: value)),
            ),
            _categorySwitch(
              icon: Icons.photo_outlined,
              label: '图片',
              value: _settings.showPhotos,
              onChanged: (value) =>
                  _update(_settings.copyWith(showPhotos: value)),
            ),
            _categorySwitch(
              icon: Icons.favorite_outline,
              label: '收藏',
              value: _settings.showFavorites,
              onChanged: (value) =>
                  _update(_settings.copyWith(showFavorites: value)),
            ),
            _categorySwitch(
              icon: Icons.folder_outlined,
              label: '目录',
              value: _settings.showFolders,
              onChanged: (value) =>
                  _update(_settings.copyWith(showFolders: value)),
            ),
            const Divider(height: 32),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                '账户与本地数据',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            ListTile(
              leading: Icon(
                Icons.delete_forever_outlined,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(
                '删除此账户数据',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              subtitle: const Text('删除本机离线内容和账户设置'),
              trailing: _deletingAccountData
                  ? const SizedBox.square(
                      dimension: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.chevron_right),
              onTap: _deletingAccountData ? null : _confirmDeleteAccountData,
            ),
          ],
        ),
      ),
    );
  }

  Widget _categorySwitch({
    required IconData icon,
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return SwitchListTile(
      secondary: Icon(icon),
      title: Text(label),
      value: value,
      onChanged: _saving || _deletingAccountData ? null : onChanged,
    );
  }
}
