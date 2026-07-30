import 'package:dio/dio.dart';

import '../data/emby_api.dart';

class DownloadResponse {
  const DownloadResponse({
    required this.statusCode,
    required this.stream,
    required this.headers,
  });

  final int statusCode;
  final Stream<List<int>> stream;
  final Map<String, String> headers;

  String? header(String name) => headers[name.toLowerCase()];
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

class EmbyDownloadTransport implements DownloadTransport {
  const EmbyDownloadTransport(this.api);

  final EmbyApi api;

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
    );
  }
}
