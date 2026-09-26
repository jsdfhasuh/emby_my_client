import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:emby_my_client/core/diagnostic_log.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('production diagnostic log budgets remain bounded', () {
    expect(DiagnosticLog.maxFileBytesForTesting, 750 * 1024);
    expect(DiagnosticLog.retainedFileBytesForTesting, 640 * 1024);
  });

  test('testing budgets support every valid minimum-size boundary', () {
    for (var maxBytes = 256; maxBytes < 320; maxBytes++) {
      expect(
        DiagnosticLog.forTesting(maxFileBytes: maxBytes),
        isA<DiagnosticLog>(),
        reason: 'maxFileBytes=$maxBytes should produce a valid default tail',
      );
    }

    expect(
      () => DiagnosticLog.forTesting(maxFileBytes: 255),
      throwsArgumentError,
    );
    expect(
      () => DiagnosticLog.forTesting(maxFileBytes: 512, retainedFileBytes: 0),
      throwsArgumentError,
    );
    expect(
      () => DiagnosticLog.forTesting(maxFileBytes: 512, retainedFileBytes: 512),
      throwsArgumentError,
    );
  });

  test(
    'tail reader only requests a bounded suffix of a virtual 100 MiB log',
    () async {
      final source = _VirtualLargeLogSource(100 * 1024 * 1024);

      final snapshot = await DiagnosticLogTailReader.read(
        source,
        maxBytes: 4096,
      );

      expect(snapshot.sourceTruncated, isTrue);
      expect(snapshot.bytesRead, 4096);
      expect(source.readCalls, 1);
      expect(source.maxRequestedBytes, 4096);
      expect(source.lastOffset, 100 * 1024 * 1024 - 4096);
      expect(snapshot.content, 'line=界🙂\nlast=ok\n');
    },
  );

  test(
    'runtime rollover keeps the file bounded and the newest complete lines',
    () async {
      final fixture = await _fixture(maxBytes: 512, retainedBytes: 320);
      final log = fixture.log;

      for (var index = 0; index < 40; index++) {
        log.info(
          'rolling',
          'event=rolling_entry count=$index payload=${'x' * 36}',
        );
      }
      final content = await log.read();

      expect(await fixture.file.length(), lessThanOrEqualTo(512));
      expect(content, contains(DiagnosticLog.truncationMarker));
      expect(content, contains('count=39'));
      expect(content, isNot(contains('count=0 ')));
      expect(content.endsWith('\n'), isTrue);
    },
  );

  test(
    'initialization preserves a bounded recent tail instead of clearing it',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'diagnostic-log-initialize-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}${Platform.pathSeparator}log.txt');
      await file.writeAsString(
        '${List<String>.generate(80, (index) => 'entry=$index payload=${'y' * 24}').join('\n')}\n',
      );
      final log = DiagnosticLog.forTesting(
        maxFileBytes: 512,
        retainedFileBytes: 320,
      );

      await log.initializeFileForTesting(file);
      final content = await log.read();

      expect(await file.length(), lessThanOrEqualTo(512));
      expect(content, contains(DiagnosticLog.truncationMarker));
      expect(content, contains('entry=79'));
      expect(content, isNot(contains('entry=0 ')));
    },
  );

  test(
    'initialization recovers malformed UTF-8 and subsequent writes continue',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'diagnostic-log-malformed-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}${Platform.pathSeparator}log.txt');
      await file.writeAsBytes(<int>[
        ...utf8.encode('entry=before\n'),
        0xff,
        0xfe,
        0x0a,
      ]);
      final log = DiagnosticLog.forTesting(
        maxFileBytes: 512,
        retainedFileBytes: 320,
      );

      await expectLater(log.initializeFileForTesting(file), completes);
      log.info('fixture', 'event=after_malformed');
      final content = await log.read();

      expect(await file.length(), lessThanOrEqualTo(512));
      expect(content, contains(DiagnosticLog.truncationMarker));
      expect(content, contains('reason=unreadable_content'));
      expect(content, contains('event=after_malformed'));
      expect(content, isNot(contains('\uFFFD')));
    },
  );

  test('tail byte boundaries never split multibyte UTF-8 lines', () async {
    final directory = await Directory.systemTemp.createTemp(
      'diagnostic-log-utf8-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}${Platform.pathSeparator}log.txt');
    const expected = 'keep=界🙂\nlast=完成🙂\n';
    await file.writeAsString('old=${'界🙂' * 50}\n$expected');
    final budget = utf8.encode(expected).length + 7;

    final snapshot = await DiagnosticLogTailReader.read(
      FileDiagnosticLogByteSource(file),
      maxBytes: budget,
    );

    expect(snapshot.sourceTruncated, isTrue);
    expect(snapshot.content, expected);
    expect(snapshot.content, isNot(contains('\uFFFD')));
  });

  test('tail reader retries one short read before failing', () async {
    final source = _ShortReadOnceSource(utf8.encode('first=old\nlast=ok\n'));

    final snapshot = await DiagnosticLogTailReader.read(
      source,
      maxBytes: source.bytes.length,
    );

    expect(source.readCalls, 2);
    expect(snapshot.content, 'first=old\nlast=ok\n');
  });

  test('tail reader discards an incomplete final line', () async {
    final source = _MemoryLogSource(utf8.encode('first=ok\npartial'));

    final snapshot = await DiagnosticLogTailReader.read(
      source,
      maxBytes: source.bytes.length,
    );

    expect(snapshot.content, 'first=ok\n');
  });

  test('tail reader rejects malformed UTF-8', () async {
    final source = _MemoryLogSource(<int>[0xff, 0x0a]);

    await expectLater(
      DiagnosticLogTailReader.read(source, maxBytes: source.bytes.length),
      throwsA(isA<FormatException>()),
    );
  });

  test(
    'one oversized entry is replaced by a bounded diagnostic marker',
    () async {
      final fixture = await _fixture(maxBytes: 512, retainedBytes: 320);

      fixture.log.error('fixture', 'z' * 2000);
      final content = await fixture.log.read();

      expect(await fixture.file.length(), lessThanOrEqualTo(512));
      expect(content, contains('event=diagnostic_entry_dropped'));
      expect(content, contains('reason=oversized'));
      expect(content, isNot(contains('z' * 100)));
    },
  );

  test(
    'clear remains ordered with pending writes and removes truncation state',
    () async {
      final fixture = await _fixture(maxBytes: 512, retainedBytes: 320);

      fixture.log.info('fixture', 'event=before_clear');
      final clear = fixture.log.clear();
      fixture.log.info('fixture', 'event=after_clear');
      await clear;
      final content = await fixture.log.read();

      expect(content, contains('Diagnostic log cleared'));
      expect(content, contains('event=after_clear'));
      expect(content, isNot(contains('event=before_clear')));
      expect(content, isNot(contains(DiagnosticLog.truncationMarker)));
    },
  );
}

Future<({DiagnosticLog log, File file})> _fixture({
  required int maxBytes,
  required int retainedBytes,
}) async {
  final directory = await Directory.systemTemp.createTemp(
    'diagnostic-log-runtime-',
  );
  addTearDown(() => directory.delete(recursive: true));
  final file = File('${directory.path}${Platform.pathSeparator}log.txt');
  final log = DiagnosticLog.forTesting(
    maxFileBytes: maxBytes,
    retainedFileBytes: retainedBytes,
  );
  await log.initializeFileForTesting(file);
  return (log: log, file: file);
}

final class _VirtualLargeLogSource implements DiagnosticLogByteSource {
  _VirtualLargeLogSource(this.totalLength);

  final int totalLength;
  int readCalls = 0;
  int maxRequestedBytes = 0;
  int? lastOffset;

  @override
  Future<int> length() async => totalLength;

  @override
  Future<Uint8List> read(int offset, int length) async {
    readCalls++;
    lastOffset = offset;
    if (length > maxRequestedBytes) maxRequestedBytes = length;
    final suffix = utf8.encode('partial-fragment\nline=界🙂\nlast=ok\n');
    final prefixLength = length - suffix.length;
    if (prefixLength < 0) {
      throw StateError('fixture suffix exceeds requested window');
    }
    return Uint8List.fromList([
      ...List<int>.filled(prefixLength, 0x78),
      ...suffix,
    ]);
  }
}

class _MemoryLogSource implements DiagnosticLogByteSource {
  _MemoryLogSource(List<int> bytes) : bytes = Uint8List.fromList(bytes);

  final Uint8List bytes;

  @override
  Future<int> length() async => bytes.length;

  @override
  Future<Uint8List> read(int offset, int length) async {
    return Uint8List.sublistView(bytes, offset, offset + length);
  }
}

final class _ShortReadOnceSource extends _MemoryLogSource {
  _ShortReadOnceSource(super.bytes);

  int readCalls = 0;

  @override
  Future<Uint8List> read(int offset, int length) async {
    readCalls++;
    final actualLength = readCalls == 1 ? length - 1 : length;
    return super.read(offset, actualLength);
  }
}
