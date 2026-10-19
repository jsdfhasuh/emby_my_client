import 'dart:convert';

import 'package:emby_my_client/core/server_scope.dart';
import 'package:emby_my_client/data/session_store.dart';
import 'package:emby_my_client/downloads/download_connection.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hysteria2/hysteria2.dart';

const scope = ServerScope(serverId: 'server', userId: 'user');
const link =
    'hysteria2://user%3Ap%2Fass@example.test:443/'
    '?sni=certificate.test&obfs=salamander&obfs-password=s%2Fe%2Bcret#label';

void main() {
  test(
    'imports encoded credentials, SNI and salamander without display leaks',
    () {
      final profile = Hysteria2Profile.parse(link);
      expect(profile.auth, 'user:p/ass');
      expect(profile.obfsPassword, 's/e+cret');
      expect(profile.sni, 'certificate.test');
      expect(profile.port, 443);
      expect(profile.label, 'example.test:443');
      expect(profile.toString(), isNot(contains(profile.auth)));
      expect(
        Hysteria2Profile.fromJson(profile.toNativeConfig()).auth,
        profile.auth,
      );
      expect(Hysteria2Profile.parse('hy2://pass@example.test').port, 443);
      expect(
        Hysteria2Profile.parse(
          'hy2://pass@[2001:db8::1]:443?sni=cert.test',
        ).host,
        '2001:db8::1',
      );
    },
  );

  for (final invalid in [
    'https://secret@example.test',
    'hy2://example.test',
    'hy2://secret@example.test?insecure=1',
    'hy2://secret@example.test?insecure=true',
    'hy2://secret@example.test?unknown=secret',
    'hy2://secret@example.test?sni=one&sni=two',
    'hy2://secret@example.test:0',
    'hy2://secret@example.test:65536',
    'hy2://secret@example.test/path',
    'hy2://secret@example.test?obfs=other&obfs-password=secret',
    'hy2://secret@example.test?obfs=salamander',
    'hy2://secret@example.test?obfs=salamander&obfs-password=abc',
    'hy2://secret@-invalid.test',
    'hy2://secret@example.test?sni=bad%2Fhost',
    'hy2://secret@example.test?obfs-password=secret',
    'hy2://secret@example.test:443-444',
  ]) {
    test(
      'rejects unsupported link without echoing credentials ${invalid.hashCode}',
      () {
        expect(
          () => Hysteria2Profile.parse(invalid),
          throwsA(
            isA<FormatException>().having(
              (error) => error.toString(),
              'sanitized',
              isNot(contains('secret')),
            ),
          ),
        );
      },
    );
  }

  test('secure repository defaults off and isolates accounts', () async {
    final storage = _Storage();
    final repo = DownloadConnectionRepository(storage: storage);
    expect((await repo.load(scope)).mode, DownloadConnectionMode.direct);
    final profile = Hysteria2Profile.parse(link);
    await repo.save(
      scope,
      DownloadConnectionSettings(
        mode: DownloadConnectionMode.hysteria2,
        profile: profile,
      ),
    );
    expect(
      (await repo.load(scope)).profile!.obfsPassword,
      profile.obfsPassword,
    );
    expect(
      (await repo.load(
        const ServerScope(serverId: 'other', userId: 'user'),
      )).mode,
      DownloadConnectionMode.direct,
    );
    expect(storage.values.keys.single, isNot(contains('server')));
    await repo.delete(scope);
    expect(storage.values, isEmpty);
  });

  test(
    'unreadable configuration fails closed instead of choosing direct',
    () async {
      final storage = _Storage();
      final repo = DownloadConnectionRepository(storage: storage);
      await repo.save(scope, const DownloadConnectionSettings());
      storage.values[storage.values.keys.single] = '{corrupt';
      await expectLater(
        repo.load(scope),
        throwsA(isA<DownloadConnectionException>()),
      );
    },
  );

  test(
    'two engine managers share an exclusive config gate and fixed route',
    () async {
      final storage = _Storage();
      final platform = _GatePlatform();
      final repo = DownloadConnectionRepository(storage: storage);
      final ui = DownloadConnectionManager(
        repository: repo,
        platform: platform,
        supportedOverride: true,
      );
      final worker = DownloadConnectionManager(
        repository: repo,
        platform: platform,
        supportedOverride: true,
      );
      await ui.save(
        scope,
        DownloadConnectionSettings(
          mode: DownloadConnectionMode.hysteria2,
          profile: Hysteria2Profile.parse(link),
        ),
      );
      final first = await worker.acquireDownload(scope);
      expect(first.mode, DownloadConnectionMode.hysteria2);
      expect(first.proxy!.host, '127.0.0.1');
      expect((await ui.status()).downloads, 1);
      await expectLater(
        ui.delete(scope),
        throwsA(
          isA<DownloadConnectionException>().having(
            (error) => error.code,
            'busy',
            'configBusy',
          ),
        ),
      );
      await first.close();
      await first.close();
      expect((await ui.status()).isBusy, isFalse);
      await ui.save(
        scope,
        (await ui.load(scope)).copyWith(mode: DownloadConnectionMode.direct),
      );
      final second = await worker.acquireDownload(scope);
      expect(second.proxy, isNull);
      expect(platform.connections, 1);
      await second.close();
    },
  );

  test('playback blocks settings but does not open a tunnel', () async {
    final platform = _GatePlatform();
    final manager = DownloadConnectionManager(
      platform: platform,
      repository: DownloadConnectionRepository(storage: _Storage()),
      supportedOverride: true,
    );
    final playback = await manager.acquirePlayback();
    await expectLater(
      manager.save(scope, const DownloadConnectionSettings()),
      throwsA(isA<DownloadConnectionException>()),
    );
    expect(platform.connections, 0);
    await playback!.close();
    await manager.save(scope, const DownloadConnectionSettings());
  });

  test(
    'tunnel failure releases native gate without implicit direct fallback',
    () async {
      final platform = _GatePlatform()..failConnect = true;
      final repo = DownloadConnectionRepository(storage: _Storage());
      final manager = DownloadConnectionManager(
        platform: platform,
        repository: repo,
        supportedOverride: true,
      );
      await manager.save(
        scope,
        DownloadConnectionSettings(
          mode: DownloadConnectionMode.hysteria2,
          profile: Hysteria2Profile.parse(link),
        ),
      );
      await expectLater(
        manager.acquireDownload(scope),
        throwsA(
          isA<DownloadConnectionException>().having(
            (error) => error.code,
            'failure',
            'tunnelUnavailable',
          ),
        ),
      );
      expect((await manager.status()).isBusy, isFalse);
      expect(platform.connections, 1);
      expect(
        (await manager.load(scope)).mode,
        DownloadConnectionMode.hysteria2,
      );
    },
  );

  test(
    'non Android acquisition does not load or instantiate native core',
    () async {
      final platform = _GatePlatform()..failConnect = true;
      final manager = DownloadConnectionManager(
        platform: platform,
        supportedOverride: false,
      );
      final lease = await manager.acquireDownload(scope);
      expect(lease.mode, DownloadConnectionMode.direct);
      expect(platform.leases, isEmpty);
      await lease.close();
    },
  );
}

class _Storage implements SessionStorage {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

class _GatePlatform extends Hysteria2Platform {
  final leases = <String, String>{};
  int next = 0, connections = 0;
  bool failConnect = false;
  @override
  Future<String> acquire({required String scope, required String kind}) async {
    if ((kind == 'configuration' && leases.isNotEmpty) ||
        leases.containsValue('configuration')) {
      throw PlatformException(code: 'configBusy');
    }
    final id = '${++next}';
    leases[id] = kind;
    return id;
  }

  @override
  Future<Map<String, Object?>> connect({
    required String leaseId,
    required Map<String, Object?> config,
  }) async {
    connections++;
    expect(jsonEncode(config), contains('example.test'));
    if (failConnect) {
      throw PlatformException(code: 'unavailable', message: 'must not escape');
    }
    return {
      'host': '127.0.0.1',
      'port': 18080,
      'username': 'local',
      'password': 'local-secret',
    };
  }

  @override
  Future<void> release(String leaseId) async {
    leases.remove(leaseId);
  }

  @override
  Future<Map<String, Object?>> status() async => {
    'downloads': leases.values.where((kind) => kind == 'download').length,
    'playbacks': leases.values.where((kind) => kind == 'playback').length,
    'editing': leases.containsValue('configuration'),
  };
}
