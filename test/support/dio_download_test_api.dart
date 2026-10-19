import 'package:dio/dio.dart';
import 'package:emby_my_client/data/emby_api.dart';

/// Keeps sidecar fixture tests independent of real sockets. The production
/// dart:io download path is exercised by download_http_client_test.dart.
class DioDownloadTestApi extends EmbyApi {
  DioDownloadTestApi(super.session, {required Dio dio})
    : _downloads = dio,
      super(dio: dio);
  final Dio _downloads;

  @override
  Future<Response<ResponseBody>> openDownload(
    Uri uri, {
    required CancelToken cancelToken,
    int offset = 0,
    String? etag,
    bool followRedirects = true,
    CancelToken? downloadTaskToken,
  }) async {
    final response = await _downloads.getUri<ResponseBody>(
      uri,
      cancelToken: cancelToken,
      options: Options(
        responseType: ResponseType.stream,
        followRedirects: followRedirects,
        headers: {
          'Accept-Encoding': 'identity',
          if (offset > 0) 'Range': 'bytes=$offset-',
        },
        validateStatus: (status) =>
            const {200, 206, 416, 301, 302, 303, 307, 308}.contains(status),
      ),
    );
    response.extra['downloadClose'] = () async {
      if (!cancelToken.isCancelled) {
        cancelToken.cancel('fixture response closed');
      }
    };
    return response;
  }
}
