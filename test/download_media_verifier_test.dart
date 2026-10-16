import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:emby_my_client/downloads/download_integrity.dart';
import 'package:emby_my_client/downloads/download_media_verifier.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'unchanged lists reuse a digest while explicit verification reads again',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'media-verifier-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final disk = File('${directory.path}${Platform.pathSeparator}media.mkv');
      final bytes = List<int>.generate(512 * 1024, (index) => index % 256);
      await disk.writeAsBytes(bytes);
      final file = _CountingFile(disk);
      final digest = DownloadIntegrity.fromStored(
        'sha-256',
        base64Encode(sha256.convert(bytes).bytes),
      )!;
      final verifier = DownloadMediaVerifier();
      expect(
        await verifier.check(
          file,
          expectedBytes: bytes.length,
          integrity: digest,
        ),
        isNull,
      );
      expect(file.digestReads, 1);
      expect(
        await verifier.check(
          file,
          expectedBytes: bytes.length,
          integrity: digest,
        ),
        isNull,
      );
      expect(file.digestReads, 1);
      expect(
        await verifier.check(
          file,
          expectedBytes: bytes.length,
          integrity: digest,
          fresh: true,
        ),
        isNull,
      );
      expect(file.digestReads, 2);
      final modified = await disk.lastModified();
      bytes[bytes.length - 1] ^= 1;
      await disk.writeAsBytes(bytes);
      await disk.setLastModified(modified);
      expect(
        await verifier.check(
          file,
          expectedBytes: bytes.length,
          integrity: digest,
          fresh: true,
        ),
        'checksumMismatch',
      );
      expect(file.digestReads, 3);
      expect(await disk.readAsBytes(), bytes);
    },
  );

  test(
    'digest identity and expected size cannot reuse an earlier result',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'media-verifier-identity-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final disk = File('${directory.path}${Platform.pathSeparator}media.mkv');
      await disk.writeAsBytes([1, 2, 3, 4]);
      final file = _CountingFile(disk);
      final verifier = DownloadMediaVerifier();
      final original = DownloadIntegrity.fromStored(
        'md5',
        base64Encode(md5.convert([1, 2, 3, 4]).bytes),
      )!;
      final other = DownloadIntegrity.fromStored(
        'md5',
        base64Encode(md5.convert([4, 3, 2, 1]).bytes),
      )!;
      expect(await verifier.check(file, integrity: original), isNull);
      expect(
        await verifier.check(file, expectedBytes: 5, integrity: original),
        'localMediaCorrupt',
      );
      expect(await verifier.check(file, integrity: other), 'checksumMismatch');
      expect(file.digestReads, 2);
    },
  );
}

class _CountingFile implements File {
  _CountingFile(this.delegate);
  final File delegate;
  int digestReads = 0;
  @override
  String get path => delegate.path;
  @override
  Future<FileStat> stat() => delegate.stat();
  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) =>
      delegate.open(mode: mode);
  @override
  Stream<List<int>> openRead([int? start, int? end]) {
    digestReads++;
    return delegate.openRead(start, end);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
