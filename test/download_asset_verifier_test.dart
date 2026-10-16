import 'dart:convert';
import 'dart:io';

import 'package:emby_my_client/downloads/download_asset_verifier.dart';
import 'package:emby_my_client/downloads/download_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void main() {
  test(
    'legacy relative sidecars become verified without a network request',
    () async {
      final directory = await Directory.systemTemp.createTemp('asset-legacy-');
      addTearDown(() => directory.delete(recursive: true));
      final subtitle = File(path.join(directory.path, 'subtitle.srt'));
      await subtitle.writeAsString(
        '1\n00:00:00,000 --> 00:00:01,000\nFixture\n',
      );
      final cover = File(path.join(directory.path, 'cover.png'));
      await cover.writeAsBytes(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
        ),
      );
      final metadata = OfflineMediaMetadata.fromJson({
        'name': 'Fixture',
        'itemType': 'Movie',
        'primaryImagePath': 'cover.png',
        'mediaStreams': [
          {
            'Index': 3,
            'Type': 'Subtitle',
            'Codec': 'srt',
            'IsExternal': true,
            'DeliveryUrl': 'subtitle.srt',
          },
        ],
      });
      final checked = await verifyOfflineAssets(metadata, directory: directory);
      expect(checked.primaryImageState, OfflineAssetState.available);
      expect(checked.primaryImagePath, cover.path);
      expect(checked.playbackStreams.single['DeliveryUrl'], subtitle.path);
      expect(
        checked.playbackStreams.single['OfflineSubtitleState'],
        'available',
      );
      expect(
        OfflineMediaMetadata.fromJson(checked.toJson()).primaryImageState,
        OfflineAssetState.available,
      );
    },
  );

  test(
    'missing corrupt and remote sidecars never appear as available',
    () async {
      final directory = await Directory.systemTemp.createTemp('asset-corrupt-');
      addTearDown(() => directory.delete(recursive: true));
      final corrupt = File(path.join(directory.path, 'corrupt.srt'));
      await corrupt.writeAsString('<html>authentication required</html>');
      final cover = File(path.join(directory.path, 'cover.jpg'));
      await cover.writeAsBytes([0xff, 0xd8, 0xff, 0xd9]);
      final checked = await verifyOfflineAssets(
        OfflineMediaMetadata(
          name: 'Fixture',
          itemType: 'Movie',
          primaryImagePath: cover.path,
          primaryImageState: OfflineAssetState.available,
          subtitleDiscoveryComplete: true,
          mediaStreams: [
            for (final entry in [
              (1, corrupt.path),
              (2, path.join(directory.path, 'missing.srt')),
              (3, 'https://fixture.invalid/subtitle.srt'),
            ])
              {
                'Index': entry.$1,
                'Type': 'Subtitle',
                'Codec': 'srt',
                'IsExternal': true,
                'OfflineSubtitleState': 'available',
                'DeliveryUrl': entry.$2,
              },
            {
              'Index': 4,
              'Type': 'Subtitle',
              'Codec': 'srt',
              'IsExternal': false,
            },
          ],
        ),
        directory: directory,
      );
      expect(checked.primaryImagePath, isNull);
      expect(checked.primaryImageState, OfflineAssetState.failed);
      expect(checked.playbackStreams.single['Index'], 4);
      expect(checked.subtitlesNeedRepair, isTrue);
      expect(checked.mediaStreams.first['OfflineSubtitleState'], 'failed');
    },
  );

  test(
    'extracted embedded subtitle is verified and missing output is excluded',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'asset-extracted-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final local = File(path.join(directory.path, 'output.srt'));
      await local.writeAsString('1\n00:00:00,000 --> 00:00:01,000\nFixture\n');
      final metadata = OfflineMediaMetadata(
        name: 'Fixture',
        itemType: 'Movie',
        subtitleDiscoveryComplete: true,
        mediaStreams: [
          {
            'Index': 9,
            'Type': 'Subtitle',
            'Codec': 'pgs',
            'Format': 'srt',
            'IsExternal': false,
            'DeliveryMethod': 'External',
            'DeliveryUrl': local.path,
          },
        ],
      );
      final verified = await verifyOfflineAssets(
        metadata,
        directory: directory,
      );
      expect(verified.playbackStreams.single['Codec'], 'pgs');
      expect(verified.playbackStreams.single['IsExternal'], isFalse);
      expect(
        verified.playbackStreams.single['OfflineSubtitleState'],
        'available',
      );
      expect(verified.assetPaths, [local.path]);
      expect(verified.subtitlesNeedRepair, isFalse);
      await local.delete();
      final missing = await verifyOfflineAssets(verified, directory: directory);
      expect(missing.playbackStreams, isEmpty);
      expect(missing.mediaStreams.single['OfflineSubtitleState'], 'missing');
      expect(missing.subtitlesNeedRepair, isTrue);
    },
  );

  test('paths outside the download root are not read or exposed', () async {
    final directory = await Directory.systemTemp.createTemp('asset-boundary-');
    addTearDown(() => directory.delete(recursive: true));
    final outside = File(path.join(directory.path, 'outside.srt'));
    await outside.writeAsString('1\n00:00:00,000 --> 00:00:01,000\nFixture\n');
    final root = await Directory(
      path.join(directory.path, 'downloads'),
    ).create();
    final checked = await verifyOfflineAssets(
      OfflineMediaMetadata(
        name: 'Fixture',
        itemType: 'Movie',
        mediaStreams: [
          {
            'Index': 1,
            'Type': 'Subtitle',
            'Codec': 'srt',
            'IsExternal': true,
            'OfflineSubtitleState': 'available',
            'DeliveryUrl': '../outside.srt',
          },
        ],
      ),
      directory: root,
    );
    expect(checked.playbackStreams, isEmpty);
    expect(await outside.exists(), isTrue);
  });
}
