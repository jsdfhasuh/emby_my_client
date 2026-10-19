import 'package:dio/dio.dart';

import '../data/emby_api.dart';
export 'download_connection.dart' show DownloadConnectionException;

class DownloadResponse {
  const DownloadResponse({
    required this.statusCode,
    required this.stream,
    required this.headers,
    this.onClose,
  });

  final int statusCode;
  final Stream<List<int>> stream;
  final Map<String, String> headers;
  final Future<void> Function()? onClose;

  Future<void> close() async => onClose?.call();

  String? header(String name) => headers[name.toLowerCase()];

  Future<void> discard() async {
    if (onClose != null) {
      await onClose!();
      return;
    }
    final subscription = stream.listen(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    try {
      await subscription.cancel();
    } catch (_) {
      // A failed cancellation must not hide the response error being handled.
    }
  }
}

abstract interface class DownloadTaskTransport {
  Future<void> beginTask(CancelToken token, {required String taskId});
  Future<void> endTask(CancelToken token);
}

abstract interface class DownloadTransport {
  List<Uri> sourceUris({required String itemId, required String mediaSourceId});

  Future<DownloadResponse> open(
    Uri uri, {
    required CancelToken cancelToken,
    required int offset,
    String? etag,
  });
}

class EmbyDownloadTransport
    implements DownloadTransport, DownloadTaskTransport {
  const EmbyDownloadTransport(this.api);

  final EmbyApi api;

  @override
  Future<void> beginTask(CancelToken token, {required String taskId}) =>
      api.beginDownloadTask(token, taskId: taskId);

  @override
  Future<void> endTask(CancelToken token) => api.endDownloadTask(token);

  @override
  List<Uri> sourceUris({
    required String itemId,
    required String mediaSourceId,
  }) => api.originalDownloadUris(itemId: itemId, mediaSourceId: mediaSourceId);

  @override
  Future<DownloadResponse> open(
    Uri uri, {
    required CancelToken cancelToken,
    required int offset,
    String? etag,
  }) async {
    final response = await api.openDownload(
      uri,
      cancelToken: cancelToken,
      offset: offset,
      etag: etag,
    );
    final body = response.data;
    if (body == null) {
      throw const EmbyApiException('服务器返回了空的下载响应');
    }
    final headers = <String, String>{};
    for (final name in response.headers.map.keys) {
      final value = response.headers.value(name);
      if (value != null) headers[name.toLowerCase()] = value;
    }
    return DownloadResponse(
      statusCode: response.statusCode ?? 0,
      stream: body.stream,
      headers: headers,
      onClose: response.extra['downloadClose'] as Future<void> Function()?,
    );
  }
}
