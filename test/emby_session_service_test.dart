import 'package:dio/dio.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/data/emby_session_service.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reports exactly the supported remote playback capabilities', () async {
    RequestOptions? request;
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            request = options;
            handler.resolve(
              Response<dynamic>(requestOptions: options, statusCode: 204),
            );
          },
        ),
      );
    final api = EmbyApi(_session, dio: dio);

    await api.sessionControl.reportCapabilities();

    expect(request?.path, '/Sessions/Capabilities/Full');
    final data = request?.data as Map<String, dynamic>;
    expect(data['SupportsMediaControl'], isTrue);
    expect(data['PlayableMediaTypes'], ['Video']);
    expect(
      data['SupportedCommands'],
      EmbySessionService.supportedPlaystateCommands,
    );
  });
}

const _session = EmbySession(
  serverUrl: 'https://emby.example.test',
  serverName: 'Test Emby',
  serverId: 'server-1',
  userId: 'user-1',
  username: 'tester',
  accessToken: 'access-token',
  deviceId: 'device-1',
);
