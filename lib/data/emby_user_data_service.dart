import 'package:dio/dio.dart';

import '../core/diagnostic_log.dart';
import '../models/emby_models.dart';
import 'emby_request_executor.dart';

class EmbyUserDataService {
  const EmbyUserDataService({
    required EmbySession session,
    required Dio dio,
    required EmbyRequestExecutor execute,
  }) : _session = session,
       _dio = dio,
       _execute = execute;

  final EmbySession _session;
  final Dio _dio;
  final EmbyRequestExecutor _execute;

  Future<void> setFavorite(String itemId, {required bool favorite}) async {
    final path = _userItemPath('FavoriteItems', itemId);
    await _execute(
      () => favorite ? _dio.post<dynamic>(path) : _dio.delete<dynamic>(path),
    );
    DiagnosticLog.instance.info(
      'user-data',
      '${favorite ? 'Favorited' : 'Unfavorited'} item=$itemId',
    );
  }

  Future<void> setPlayed(String itemId, {required bool played}) async {
    final path = _userItemPath('PlayedItems', itemId);
    await _execute(
      () => played ? _dio.post<dynamic>(path) : _dio.delete<dynamic>(path),
    );
    DiagnosticLog.instance.info(
      'user-data',
      'Marked item=$itemId as ${played ? 'played' : 'unplayed'}',
    );
  }

  String _userItemPath(String collection, String itemId) =>
      '/Users/${Uri.encodeComponent(_session.userId)}/$collection/'
      '${Uri.encodeComponent(itemId)}';
}
