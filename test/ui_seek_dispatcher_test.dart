import 'package:emby_my_client/playback/playback_operation_coordinator.dart';
import 'package:emby_my_client/playback/ui_seek_dispatcher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('only the latest UI seek generation may update the presentation', () {
    final gate = UiSeekRequestGate();
    final first = gate.beginRequest();
    final second = gate.beginRequest();

    expect(
      gate.completionFor(
        generation: first,
        result: const SeekResult(
          disposition: SeekDisposition.executed,
          requestedTarget: Duration(seconds: 10),
          committedPosition: Duration(seconds: 10),
          settled: true,
        ),
      ),
      UiSeekCompletion.ignored,
    );
    expect(
      gate.completionFor(
        generation: second,
        result: const SeekResult(
          disposition: SeekDisposition.executed,
          requestedTarget: Duration(seconds: 20),
          committedPosition: Duration(seconds: 20),
          settled: true,
        ),
      ),
      UiSeekCompletion.committed,
    );
  });

  test('failed and cancelled UI seeks have distinct safe outcomes', () {
    final gate = UiSeekRequestGate();
    final failed = gate.beginRequest();
    expect(
      gate.completionFor(
        generation: failed,
        result: const SeekResult(
          disposition: SeekDisposition.failed,
          requestedTarget: Duration(seconds: 10),
          settled: false,
          failureKind: SeekFailureKind.engineError,
        ),
      ),
      UiSeekCompletion.failed,
    );

    final cancelled = gate.beginRequest();
    expect(
      gate.completionFor(
        generation: cancelled,
        result: const SeekResult(
          disposition: SeekDisposition.cancelled,
          requestedTarget: Duration(seconds: 10),
          settled: false,
          failureKind: SeekFailureKind.staleSession,
        ),
      ),
      UiSeekCompletion.cancelled,
    );
  });

  test('invalidate discards an in-flight UI seek', () {
    final gate = UiSeekRequestGate();
    final request = gate.beginRequest();
    gate.invalidate();

    expect(
      gate.completionFor(
        generation: request,
        result: const SeekResult(
          disposition: SeekDisposition.failed,
          requestedTarget: Duration(seconds: 5),
          settled: false,
          failureKind: SeekFailureKind.higherPriorityOperation,
        ),
      ),
      UiSeekCompletion.ignored,
    );
  });
}
