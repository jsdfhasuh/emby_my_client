import '../core/strm_diagnostics.dart';
import 'dart:convert';
import 'dart:io';

import '../core/server_scope.dart';
import '../data/emby_api.dart';
import 'playback_resource_request.dart';
import 'source_http_input.dart';

/// Owns downloads/files only. Selection and native application belong to the
/// controller queue. Attached leases live until the real engine is destroyed.
class ExternalSubtitleLoader {
  ExternalSubtitleLoader(this.api, {this.trace});
  final StrmTrace? trace;
  final EmbyApi api;
  final Object _task = Object();
  final Set<SubtitleFileLease> _leases = {};
  SourceHttpInput? _pending;
  int _reserved = 0;
  int _revision = 0;
  bool _closed = false;
  static const _fileLimit = 10 * 1024 * 1024;
  static const _sessionLimit = 32 * 1024 * 1024;

  void cancel() {
    _revision++;
    _pending?.close();
    _pending = null;
  }

  Future<SubtitleFileLease> load(
    String raw, {
    required String itemId,
    required String sourceId,
  }) async {
    cancel();
    final revision = _revision;
    final attempt = trace?.currentAttempt ?? 0;
    final task = trace?.nextTask();
    void event(String outcome) => trace?.emit('strm_subtitle', {
      'openAttempt': attempt,
      'task': task,
      'stage': 'subtitle_download',
      'outcome': outcome,
      'stale': revision != _revision,
    });
    event('started');
    if (_closed || _reserved + _fileLimit > _sessionLimit) {
      throw const SourceInputException('subtitle_budget');
    }
    _reserved += _fileLimit;
    var reservation = _fileLimit;
    Directory? directory;
    try {
      final server = Uri.parse(api.session.serverUrl);
      var absolute = raw.startsWith(RegExp(r'https?://'))
          ? raw
          : resolveRawLocation(
              '${server.toString().replaceFirst(RegExp(r'/+$'), '')}/',
              raw,
            );
      final uri = Uri.parse(absolute);
      final base = server.path.replaceFirst(RegExp(r'/+$'), '');
      // Authentication only for an exact subtitle resource on the bound API.
      final subtitlePrefix =
          '$base/Videos/${Uri.encodeComponent(itemId)}/${Uri.encodeComponent(sourceId)}/Subtitles/';
      bool owns(String value) {
        final target = Uri.parse(value);
        return target.origin == server.origin &&
            target.path.toLowerCase().startsWith(
              subtitlePrefix.toLowerCase(),
            ) &&
            !Uri.decodeComponent(
              target.path,
            ).split('/').any((part) => part == '..' || part == '.');
      }

      final authenticated = owns(absolute);
      if (authenticated && uri.hasQuery) {
        // Remove only this server's authentication query fields. Opaque
        // third-party signatures, including their own api_key, are untouched.
        final query = absolute
            .substring(absolute.indexOf('?') + 1)
            .split('&')
            .where(
              (part) => !{'api_key', 'access_token', 'x-emby-token'}.contains(
                Uri.decodeQueryComponent(part.split('=').first).toLowerCase(),
              ),
            )
            .join('&');
        absolute =
            absolute.substring(0, absolute.indexOf('?')) +
            (query.isEmpty ? '' : '?$query');
      }
      final headers = authenticated
          ? api.playbackHeaders
          : const <String, String>{};
      final resource = PlaybackResourceRequest(
        rawUrl: absolute,
        trace: trace,
        diagnosticTask: task,
        headers: const {},
        identity: PlaybackResourceIdentity(
          scope: ServerScope.fromSession(api.session),
          apiSession: api,
          itemId: itemId,
          sourceId: sourceId,
          itemSession: _task,
          generation: revision,
        ),
        embyServer: server,
        isSessionActive: () =>
            api.isSessionActive && !_closed && revision == _revision,
      );
      final input = _pending = SourceHttpInput(
        resource,
        embyServer: server,
        openAttempt: attempt,
      );
      final bytes = await input.downloadText(
        headers: headers,
        authorizeHeaders: authenticated ? owns : (_) => false,
      );
      if (_closed || revision != _revision || !api.isSessionActive) {
        throw const SourceInputException('cancelled');
      }
      final text = utf8.decode(bytes, allowMalformed: false).trimLeft();
      final lower = text.toLowerCase();
      if (lower.startsWith('<') ||
          lower.contains('<html') ||
          !(text.startsWith('WEBVTT') ||
              text.startsWith('[Script Info]') ||
              RegExp(r'\d{1,2}:\d{2}:\d{2}[,.]\d{3}\s*-->').hasMatch(text))) {
        throw const SourceInputException('subtitle_format');
      }
      directory = await Directory.systemTemp.createTemp('emby-sub-');
      final part = File('${directory.path}/subtitle.part');
      await part.writeAsBytes(bytes, flush: true);
      if (_closed || revision != _revision) {
        throw const SourceInputException('cancelled');
      }
      final extension = text.startsWith('WEBVTT')
          ? 'vtt'
          : text.startsWith('[Script Info]')
          ? 'ass'
          : 'srt';
      final file = await part.rename('${directory.path}/subtitle.$extension');
      _reserved -= reservation - bytes.length;
      reservation = 0;
      late SubtitleFileLease lease;
      lease = SubtitleFileLease(file, () {
        _reserved -= bytes.length;
        _leases.remove(lease);
        event('released');
      });
      _leases.add(lease);
      directory = null;
      event('succeeded');
      return lease;
    } catch (error) {
      final failure = SourceInputException.from(
        error,
        stage: 'subtitle_download',
        cancelled: _closed || revision != _revision,
      );
      if (trace != null) {
        SourceInputFailure(
          error: failure,
          trace: trace!,
          openAttempt: attempt,
          request: 0,
          stale: revision != _revision,
        ).record();
      }
      event(failure.reason == 'cancelled' ? 'cancelled' : 'failed');
      rethrow;
    } finally {
      _reserved -= reservation;
      if (directory != null) await _deleteOwnedFiles(directory);
    }
  }

  Future<void> dispose() async {
    _closed = true;
    cancel();
    for (final lease in _leases.toList()) {
      if (!lease.attached) await lease.release();
    }
  }
}

class SubtitleFileLease {
  SubtitleFileLease(this.file, this._onRelease);
  final File file;
  final void Function() _onRelease;
  bool attached = false;
  bool _released = false;
  Future<void> release() async {
    if (_released) return;
    _released = true;
    try {
      if (await file.parent.exists()) await _deleteOwnedFiles(file.parent);
    } finally {
      _onRelease();
    }
  }
}

Future<void> _deleteOwnedFiles(Directory directory) async {
  // Only our four known filenames; never recursively delete a computed tree.
  for (final name in [
    'subtitle.part',
    'subtitle.srt',
    'subtitle.ass',
    'subtitle.vtt',
  ]) {
    final file = File('${directory.path}/$name');
    if (await file.exists()) await file.delete();
  }
  await directory.delete();
}
