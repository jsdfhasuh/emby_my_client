import 'package:emby_my_client/library/library_watch_status.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('containers never inherit a leaf watch badge from user data', () {
    for (final type in [
      'Folder',
      'CollectionFolder',
      'PhotoAlbum',
      'Series',
      'Season',
    ]) {
      expect(
        LibraryWatchStatus.forItem(
          _item(type: type, data: const EmbyUserData(isPlayed: true)),
        ),
        isNull,
        reason: type,
      );
    }
  });

  test('a partial video is in progress without being marked watched', () {
    final status = LibraryWatchStatus.forItem(
      _item(data: const EmbyUserData(playedPercentage: 32)),
    )!;

    expect(status.state, LibraryWatchState.inProgress);
    expect(status.progress, 0.32);
    expect(status.label, '观看中 32%');
  });

  test('position supplies progress when the server omits its percentage', () {
    final status = LibraryWatchStatus.forItem(
      _item(data: const EmbyUserData(playbackPositionTicks: 25), duration: 100),
    )!;

    expect(status.progress, 0.25);
    expect(status.label, '观看中 25%');
  });

  test('unknown duration shows watching without inventing a percentage', () {
    final status = LibraryWatchStatus.forItem(
      _item(data: const EmbyUserData(playbackPositionTicks: 25)),
    )!;

    expect(status.state, LibraryWatchState.inProgress);
    expect(status.progress, isNull);
    expect(status.label, '观看中');
  });

  test('the played flag wins over a stale resume position', () {
    final status = LibraryWatchStatus.forItem(
      _item(
        data: const EmbyUserData(
          isPlayed: true,
          playbackPositionTicks: 25,
          playedPercentage: 25,
        ),
      ),
    )!;

    expect(status.state, LibraryWatchState.watched);
    expect(status.label, '已观看');
    expect(status.progress, isNull);
  });

  test('photos use viewing labels and ignore playback progress', () {
    for (final played in [false, true]) {
      final status = LibraryWatchStatus.forItem(
        _item(
          type: 'Photo',
          data: EmbyUserData(
            isPlayed: played,
            playbackPositionTicks: 25,
            playedPercentage: 25,
          ),
        ),
      )!;

      expect(status.isPhoto, isTrue);
      expect(status.label, played ? '已查看' : '未查看');
      expect(status.progress, isNull);
    }
  });

  test('invalid percentages do not make an unwatched video look started', () {
    for (final percentage in [double.nan, double.infinity, -1.0, 0.0]) {
      final status = LibraryWatchStatus.forItem(
        _item(data: EmbyUserData(playedPercentage: percentage)),
      )!;

      expect(status.state, LibraryWatchState.unwatched);
      expect(status.progress, isNull);
      expect(status.label, '未观看');
    }
  });

  test('progress is bounded without inferring a played flag', () {
    for (final data in [
      const EmbyUserData(playedPercentage: 150),
      const EmbyUserData(playbackPositionTicks: 150),
    ]) {
      final status = LibraryWatchStatus.forItem(
        _item(data: data, duration: 100),
      )!;

      expect(status.progress, 1);
      expect(status.state, LibraryWatchState.inProgress);
    }
  });
}

EmbyItem _item({
  String type = 'Video',
  EmbyUserData data = const EmbyUserData(),
  int? duration,
}) => EmbyItem(
  id: 'item',
  name: 'Item',
  type: type,
  mediaType: type == 'Photo' ? 'Photo' : 'Video',
  runTimeTicks: duration,
  imageTags: const {},
  backdropImageTags: const [],
  genres: const [],
  userData: data,
);
