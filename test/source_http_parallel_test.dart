import 'dart:async';
import 'dart:typed_data';

import 'package:emby_my_client/playback/source_http_input.dart';
import 'package:flutter_test/flutter_test.dart';

import 'source_http_input_test.dart' show fixtureRequest;
import 'support/progressive_fixture.dart';

const block = SourceHttpInput.readAheadSize;

Future<void> until(bool Function() condition) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > const Duration(seconds: 5)) fail('Condition timed out');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

int offsetOf(FixtureRequest request) => int.parse(
  RegExp(r'bytes=(\d+)-').firstMatch(request.headers['range']!)![1]!,
);

Future<(ProgressiveOrigin, SourceHttpInput)> setup({
  int length = 40 * block,
  bool adaptive = false,
}) async {
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = (i ~/ block + i) % 251;
  }
  bytes.setRange(0, 12, progressiveVideo().take(12));
  final server = await ProgressiveOrigin.start(content: bytes);
  addTearDown(server.close);
  final input = SourceHttpInput(
    fixtureRequest('${server.origin}/parallel.avi'),
    embyServer: Uri.parse('https://emby.invalid'),
    rangeBytes: adaptive ? null : block,
  );
  addTearDown(input.close);
  await input.prepare();
  return (server, input);
}

void main() {
  test(
    'adaptive mixed ranges preserve coverage and budget and reset to 2 MiB on seek',
    () async {
      final (server, input) = await setup(adaptive: true);
      const mib = 1024 * 1024;
      var offset = mib;
      final tiers = <int>{input.rangeBytes};
      while (offset < 56 * mib) {
        final bytes = await input.read(offset, 65536);
        expect(bytes, server.bytes.sublist(offset, offset + bytes.length));
        offset += bytes.length;
        tiers.add(input.rangeBytes);
        expect(
          input.cachedBytes + input.reservedBytes,
          lessThanOrEqualTo(SourceHttpInput.cacheBudget),
        );
      }
      expect(tiers, containsAll([2 * mib, 4 * mib]));
      final spans = server.requests.skip(1).map((request) {
        final range = request.headers['range']!.substring(6).split('-');
        return (int.parse(range[0]), int.parse(range[1]));
      }).toList()..sort((a, b) => a.$1.compareTo(b.$1));
      for (var i = 1; i < spans.length; i++) {
        expect(spans[i].$1, spans[i - 1].$2 + 1);
      }
      input.cancelPendingPrefetch();
      expect(input.rangeBytes, 2 * mib);
      expect(input.prefetchConcurrency, 8);
      expect(
        await input.read(76 * mib, 16),
        server.bytes.sublist(76 * mib, 76 * mib + 16),
      );
      expect(input.rangeBytes, 2 * mib);
      expect(
        input.cachedBytes + input.reservedBytes,
        lessThanOrEqualTo(SourceHttpInput.cacheBudget),
      );
    },
  );

  test(
    'each parallel redirect strips credentials and preserves opaque targets',
    () async {
      final content = Uint8List(10 * block)
        ..setRange(0, 12, progressiveVideo().take(12));
      final first = await ProgressiveOrigin.start(content: content);
      final second = await ProgressiveOrigin.start(content: content);
      addTearDown(first.close);
      addTearDown(second.close);
      const target = '/movie%2fname?sign=%7e&x=1&x=2';
      first.intercept = (_) async => (
        status: 302,
        headers: {'Location': '${second.origin}$target'},
        body: <int>[],
      );
      final input = SourceHttpInput(
        fixtureRequest(
          '${first.origin}/video',
          headers: {
            'Authorization': 'fixture',
            'Cookie': 'fixture',
            'X-Private': 'fixture',
          },
        ),
        embyServer: Uri.parse('https://emby.invalid'),
        rangeBytes: block,
      );
      addTearDown(input.close);
      await input.prepare();
      await input.read(block, 16);
      await until(() => input.ranges == 9);
      expect(first.requests, hasLength(9));
      expect(second.requests, hasLength(9));
      for (final request in first.requests) {
        expect(request.headers['authorization'], 'fixture');
      }
      for (final request in second.requests) {
        expect(request.target, target);
        for (final header in ['authorization', 'cookie', 'x-private']) {
          expect(request.headers.containsKey(header), isFalse);
        }
      }
    },
  );

  test(
    'eight requests overlap; demand does not wait for background; out-of-order bytes stay correct',
    () async {
      final (server, input) = await setup(length: 10 * block);
      final gates = <int, Completer<FixtureReply?>>{};
      server.intercept = (request) {
        final gate = Completer<FixtureReply?>();
        gates[offsetOf(request)] = gate;
        return gate.future;
      };
      final current = input.read(block, 65536);
      await until(() => gates.length == 8);
      expect(gates.keys.toSet(), {for (var i = 1; i <= 8; i++) i * block});
      gates[block]!.complete(null);
      expect(
        await current.timeout(const Duration(seconds: 2)),
        server.bytes.sublist(block, block + 65536),
      );
      expect(gates.values.where((g) => !g.isCompleted), hasLength(7));
      for (var i = 8; i >= 2; i--) {
        gates[i * block]!.complete(null);
      }
      await until(() => input.ranges == 9);
      server.intercept = null;
      for (var i = 1; i <= 8; i++) {
        final offset = i * block + 123;
        expect(
          await input.read(offset, 1234),
          server.bytes.sublist(offset, offset + 1234),
        );
      }
      for (var i = 1; i <= 8; i++) {
        expect(
          server.requests.where((r) => offsetOf(r) == i * block),
          hasLength(1),
        );
      }
    },
  );

  test(
    'seek cancels old prefetch; completed cache survives and late replies are ignored',
    () async {
      final (server, input) = await setup();
      final gates = <int, Completer<FixtureReply?>>{};
      server.intercept = (request) async {
        final offset = offsetOf(request);
        if (offset >= 2 * block && offset < 9 * block) {
          return (gates[offset] = Completer<FixtureReply?>()).future;
        }
        return null;
      };
      await input.read(block, 16);
      await until(() => gates.length == 7);
      input.cancelPendingPrefetch();
      final newBytes = await input
          .read(20 * block, 65536)
          .timeout(const Duration(seconds: 2));
      expect(newBytes, server.bytes.sublist(20 * block, 20 * block + 65536));
      expect(gates.values.every((g) => !g.isCompleted), isTrue);
      input.cancelPendingPrefetch();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final oldNetworkBytes = input.networkBytes;
      for (final gate in gates.values) {
        gate.complete(null);
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(input.networkBytes, oldNetworkBytes);
      final oldCount = server.requests
          .where((r) => offsetOf(r) == block)
          .length;
      server.intercept = null;
      expect(
        await input.read(block, 16),
        server.bytes.sublist(block, block + 16),
      );
      expect(
        server.requests.where((r) => offsetOf(r) == block),
        hasLength(oldCount),
      );
      expect(input.failures, 0);
    },
  );

  test(
    'background failure falls back to single requests without failing playback',
    () async {
      final (server, input) = await setup();
      var rejected = false;
      server.intercept = (request) async {
        if (offsetOf(request) == 2 * block && !rejected) {
          rejected = true;
          return (status: 503, headers: <String, String>{}, body: <int>[]);
        }
        return null;
      };
      expect(
        await input.read(block, 16),
        server.bytes.sublist(block, block + 16),
      );
      await until(() => rejected);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final before = server.requests.length;
      expect(
        await input.read(20 * block, 16),
        server.bytes.sublist(20 * block, 20 * block + 16),
      );
      expect(server.requests.length, before + 1);
      expect(
        await input.read(2 * block, 16),
        server.bytes.sublist(2 * block, 2 * block + 16),
      );
      expect(input.failures, 0);
    },
  );

  test(
    'parallel validator failure never returns changed-source bytes',
    () async {
      final (server, input) = await setup(length: 10 * block);
      server.intercept = (request) async {
        final start = offsetOf(request);
        if (start == 2 * block) {
          return (
            status: 206,
            headers: {
              'Content-Range':
                  'bytes $start-${start + block - 1}/${server.bytes.length}',
              'ETag': '"changed"',
            },
            body: List<int>.filled(block, 0),
          );
        }
        return null;
      };
      await input.read(block, 16);
      await until(() => server.requests.any((r) => offsetOf(r) == 2 * block));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await expectLater(
        input.read(2 * block, 16),
        throwsA(
          isA<SourceInputException>().having(
            (e) => e.code,
            'code',
            'source_changed',
          ),
        ),
      );
    },
  );

  test('rolling parallel window remains bounded and EOF is clamped', () async {
    final (server, input) = await setup(length: 36 * block + 137);
    for (var offset = block; offset < 36 * block; offset += 65536) {
      expect(
        await input.read(offset, 65536),
        server.bytes.sublist(offset, offset + 65536),
      );
      expect(
        input.cachedBytes + input.reservedBytes,
        lessThanOrEqualTo(SourceHttpInput.cacheBudget),
      );
    }
    expect(
      await input.read(36 * block, 65536),
      server.bytes.sublist(36 * block),
    );
    expect(
      server.requests.every(
        (r) =>
            int.parse(r.headers['range']!.split('-').last) <
            server.bytes.length,
      ),
      isTrue,
    );
    input.close();
    expect(input.cachedBytes, 0);
  });

  test('close stops all eight transfers and queued native reads', () async {
    final (server, input) = await setup(length: 10 * block);
    final gates = <Completer<FixtureReply?>>[];
    server.intercept = (_) {
      final gate = Completer<FixtureReply?>();
      gates.add(gate);
      return gate.future;
    };
    final pending = expectLater(
      input.read(block, 16),
      throwsA(isA<SourceInputException>()),
    );
    final queued = expectLater(
      input.read(block + 16, 16),
      throwsA(isA<SourceInputException>()),
    );
    await until(() => gates.length == 8);
    input.close();
    await Future.wait([pending, queued]).timeout(const Duration(seconds: 2));
    for (final gate in gates) {
      gate.complete(null);
    }
    expect(input.cachedBytes, 0);
  });
}
