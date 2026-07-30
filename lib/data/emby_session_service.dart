import 'package:dio/dio.dart';

import '../core/diagnostic_log.dart';
import 'emby_request_executor.dart';

class EmbySessionService {
  const EmbySessionService({
    required Dio dio,
    required EmbyRequestExecutor execute,
  }) : _dio = dio,
       _execute = execute;

  static const supportedPlaystateCommands = [
    'Play',
    'Pause',
    'Unpause',
    'Stop',
    'Seek',
    'NextTrack',
    'PreviousTrack',
    'FastForward',
    'Rewind',
  ];

  final Dio _dio;
  final EmbyRequestExecutor _execute;

  Future<void> reportCapabilities() async {
    await _execute(
      () => _dio.post<dynamic>(
        '/Sessions/Capabilities/Full',
        data: const {
          'PlayableMediaTypes': ['Video'],
          'SupportsMediaControl': true,
          'SupportsPersistentIdentifier': true,
          'SupportedCommands': supportedPlaystateCommands,
        },
      ),
    );
    DiagnosticLog.instance.info(
      'realtime',
      'Reported remote playback capabilities',
    );
  }
}
