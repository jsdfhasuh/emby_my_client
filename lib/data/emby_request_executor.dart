import 'package:dio/dio.dart';

typedef EmbyRequestExecutor =
    Future<Response<dynamic>> Function(
      Future<Response<dynamic>> Function() action,
    );
