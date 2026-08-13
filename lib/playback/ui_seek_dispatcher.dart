import 'playback_operation_coordinator.dart';

enum UiSeekCompletion { ignored, committed, cancelled, failed }

const uiSeekFailureMessage = '跳转失败，请重试';

class UiSeekRequestGate {
  int _generation = 0;

  int get generation => _generation;

  int invalidate() => ++_generation;

  int beginRequest() => ++_generation;

  bool isCurrent(int generation) => generation == _generation;

  UiSeekCompletion completionFor({
    required int generation,
    required SeekResult? result,
  }) {
    if (!isCurrent(generation)) return UiSeekCompletion.ignored;
    return switch (result?.disposition) {
      SeekDisposition.executed => UiSeekCompletion.committed,
      SeekDisposition.failed => UiSeekCompletion.failed,
      SeekDisposition.cancelled ||
      SeekDisposition.superseded ||
      null => UiSeekCompletion.cancelled,
    };
  }
}
