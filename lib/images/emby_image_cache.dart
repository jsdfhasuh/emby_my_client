import 'dart:async';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;

const embyImageCacheBudgetBytes = 256 * 1024 * 1024;

EmbyImageCacheManager? _imageCacheManager;

EmbyImageCacheManager get embyImageCacheManager =>
    _imageCacheManager ??= EmbyImageCacheManager();

class EmbyImageCacheManager extends CacheManager with ImageCacheManager {
  EmbyImageCacheManager({
    FileService? fileService,
    this.maxCacheBytes = embyImageCacheBudgetBytes,
    this.cleanupDelay = const Duration(seconds: 2),
  }) : assert(maxCacheBytes > 0),
       super(
         Config(
           'embyImageCacheV1',
           stalePeriod: const Duration(days: 14),
           maxNrOfCacheObjects: 240,
           fileService: fileService ?? SameOriginImageFileService(),
         ),
       );

  final int maxCacheBytes;
  final Duration cleanupDelay;

  Timer? _cleanupTimer;
  Future<EmbyImageCacheUsage>? _budgetOperation;

  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) async* {
    await for (final response in super.getFileStream(
      url,
      key: key,
      headers: headers,
      withProgress: withProgress,
    )) {
      if (response is FileInfo && response.source == FileSource.Online) {
        _scheduleBudgetEnforcement();
      }
      yield response;
    }
  }

  @override
  Future<FileInfo> downloadFile(
    String url, {
    String? key,
    Map<String, String>? authHeaders,
    bool force = false,
  }) async {
    final result = await super.downloadFile(
      url,
      key: key,
      authHeaders: authHeaders,
      force: force,
    );
    _scheduleBudgetEnforcement();
    return result;
  }

  Future<EmbyImageCacheUsage> inspectUsage() async {
    await config.repo.open();
    final objects = await config.repo.getAllObjects();
    var bytes = 0;
    var count = 0;
    for (final object in objects) {
      final file = await config.fileSystem.createFile(object.relativePath);
      if (!await file.exists()) continue;
      bytes += object.length ?? await file.length();
      count++;
    }
    return EmbyImageCacheUsage(objectCount: count, bytes: bytes);
  }

  Future<EmbyImageCacheUsage> enforceBudget() {
    final active = _budgetOperation;
    if (active != null) return active;
    late final Future<EmbyImageCacheUsage> operation;
    operation = _enforceBudget().whenComplete(() {
      if (identical(_budgetOperation, operation)) _budgetOperation = null;
    });
    _budgetOperation = operation;
    return operation;
  }

  Future<void> clearAll() async {
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
    await _budgetOperation;
    await emptyCache();
  }

  Future<EmbyImageCacheUsage> _enforceBudget() async {
    await config.repo.open();
    final objects = await config.repo.getAllObjects();
    final entries = <EmbyImageCacheEntry>[];
    for (final object in objects) {
      final file = await config.fileSystem.createFile(object.relativePath);
      if (!await file.exists()) continue;
      entries.add(
        EmbyImageCacheEntry(
          key: object.key,
          bytes: object.length ?? await file.length(),
          touched: object.touched ?? DateTime.fromMillisecondsSinceEpoch(0),
        ),
      );
    }
    final policy = EmbyImageCacheBudgetPolicy(maxBytes: maxCacheBytes);
    for (final key in policy.keysToRemove(entries)) {
      await removeFile(key);
    }
    return inspectUsage();
  }

  void _scheduleBudgetEnforcement() {
    _cleanupTimer?.cancel();
    _cleanupTimer = Timer(cleanupDelay, () {
      _cleanupTimer = null;
      unawaited(_enforceBudgetInBackground());
    });
  }

  Future<void> _enforceBudgetInBackground() async {
    try {
      await enforceBudget();
    } catch (_) {
      // Cache cleanup failure must not make an otherwise valid image fail.
    }
  }

  @override
  Future<void> dispose() async {
    _cleanupTimer?.cancel();
    await _budgetOperation;
    await super.dispose();
  }
}

class EmbyImageCacheBudgetPolicy {
  const EmbyImageCacheBudgetPolicy({required this.maxBytes})
    : assert(maxBytes > 0);

  final int maxBytes;

  List<String> keysToRemove(Iterable<EmbyImageCacheEntry> entries) {
    final oldestFirst = entries.toList()
      ..sort((first, second) => first.touched.compareTo(second.touched));
    var currentBytes = oldestFirst.fold<int>(
      0,
      (total, entry) => total + entry.bytes,
    );
    final removals = <String>[];
    for (final entry in oldestFirst) {
      if (currentBytes <= maxBytes) break;
      removals.add(entry.key);
      currentBytes -= entry.bytes;
    }
    return removals;
  }
}

class EmbyImageCacheEntry {
  const EmbyImageCacheEntry({
    required this.key,
    required this.bytes,
    required this.touched,
  });

  final String key;
  final int bytes;
  final DateTime touched;
}

class EmbyImageCacheUsage {
  const EmbyImageCacheUsage({required this.objectCount, required this.bytes});

  final int objectCount;
  final int bytes;
}

class SameOriginImageFileService extends FileService {
  SameOriginImageFileService({
    http.Client? client,
    this.maxRedirects = 5,
    this.responseTimeout = const Duration(seconds: 15),
    this.responseIdleTimeout = const Duration(seconds: 15),
  }) : assert(maxRedirects >= 0),
       assert(responseTimeout > Duration.zero),
       assert(responseIdleTimeout > Duration.zero),
       _client = client ?? http.Client();

  final http.Client _client;
  final int maxRedirects;
  final Duration responseTimeout;
  final Duration responseIdleTimeout;

  @override
  Future<FileServiceResponse> get(
    String url, {
    Map<String, String>? headers,
  }) async {
    final origin = Uri.parse(url);
    _validateHttpUri(origin);
    var current = origin;
    var followedRedirects = 0;

    while (true) {
      final abort = Completer<void>();
      var responseTimedOut = false;
      final request =
          http.AbortableRequest('GET', current, abortTrigger: abort.future)
            ..followRedirects = false
            ..maxRedirects = 0;
      if (headers != null) request.headers.addAll(headers);
      late final http.StreamedResponse response;
      try {
        response = await _client
            .send(request)
            .timeout(
              responseTimeout,
              onTimeout: () {
                responseTimedOut = true;
                if (!abort.isCompleted) abort.complete();
                throw ImageRequestTimeoutException(
                  stage: ImageRequestTimeoutStage.response,
                  duration: responseTimeout,
                );
              },
            );
      } on http.RequestAbortedException {
        if (!responseTimedOut) rethrow;
        throw ImageRequestTimeoutException(
          stage: ImageRequestTimeoutStage.response,
          duration: responseTimeout,
        );
      }
      final timedResponse = _TimedFileServiceResponse(
        HttpGetResponse(response),
        abort: abort,
        idleTimeout: responseIdleTimeout,
      );
      if (!_isRedirect(response.statusCode)) return timedResponse;

      final location = response.headers['location'];
      if (location == null || location.isEmpty) {
        return timedResponse;
      }
      final target = current.resolve(location);
      if (!_isSameOrigin(origin, target)) {
        if (!abort.isCompleted) abort.complete();
        throw const UnsafeImageRedirectException();
      }
      if (followedRedirects >= maxRedirects) {
        if (!abort.isCompleted) abort.complete();
        throw ImageRedirectLimitException(maxRedirects);
      }

      await timedResponse.content.drain<void>();
      followedRedirects++;
      current = target;
    }
  }
}

enum ImageRequestTimeoutStage { response, responseBody }

class ImageRequestTimeoutException implements TimeoutException {
  const ImageRequestTimeoutException({
    required this.stage,
    required this.duration,
  });

  final ImageRequestTimeoutStage stage;

  @override
  final Duration duration;

  @override
  String? get message => stage == ImageRequestTimeoutStage.response
      ? 'Image server response timed out'
      : 'Image response body stalled';

  @override
  String toString() => '$message after ${duration.inSeconds}s';
}

class _TimedFileServiceResponse implements FileServiceResponse {
  const _TimedFileServiceResponse(
    this._delegate, {
    required Completer<void> abort,
    required this.idleTimeout,
  }) : _abort = abort;

  final FileServiceResponse _delegate;
  final Completer<void> _abort;
  final Duration idleTimeout;

  @override
  Stream<List<int>> get content => _delegate.content.timeout(
    idleTimeout,
    onTimeout: (sink) {
      if (!_abort.isCompleted) _abort.complete();
      sink
        ..addError(
          ImageRequestTimeoutException(
            stage: ImageRequestTimeoutStage.responseBody,
            duration: idleTimeout,
          ),
        )
        ..close();
    },
  );

  @override
  int? get contentLength => _delegate.contentLength;

  @override
  String? get eTag => _delegate.eTag;

  @override
  String get fileExtension => _delegate.fileExtension;

  @override
  int get statusCode => _delegate.statusCode;

  @override
  DateTime get validTill => _delegate.validTill;
}

class UnsafeImageRedirectException implements Exception {
  const UnsafeImageRedirectException();

  @override
  String toString() => 'Refused cross-origin image redirect';
}

class ImageRedirectLimitException implements Exception {
  const ImageRedirectLimitException(this.maxRedirects);

  final int maxRedirects;

  @override
  String toString() => 'Image redirect limit exceeded (maximum $maxRedirects)';
}

bool _isRedirect(int statusCode) =>
    statusCode == 301 ||
    statusCode == 302 ||
    statusCode == 303 ||
    statusCode == 307 ||
    statusCode == 308;

bool _isSameOrigin(Uri first, Uri second) =>
    second.scheme == first.scheme &&
    second.host == first.host &&
    second.port == first.port;

void _validateHttpUri(Uri uri) {
  if ((uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) {
    throw const FormatException('Invalid image URI origin');
  }
}
