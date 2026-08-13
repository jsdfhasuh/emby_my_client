import 'package:emby_my_client/playback/playback_operation_coordinator.dart';
import 'package:emby_my_client/playback/ui_seek_dispatcher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('seek failure message is fixed and contains no dynamic detail', () {
    expect(uiSeekFailureMessage, '跳转失败，请重试');
  });

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

  test('cross-source superseded seeks never become a presentation update', () {
    final gate = UiSeekRequestGate();
    final horizontal = gate.beginRequest();
    final remote = gate.beginRequest();

    expect(
      gate.completionFor(
        generation: horizontal,
        result: const SeekResult(
          disposition: SeekDisposition.superseded,
          requestedTarget: Duration(seconds: 10),
          settled: false,
        ),
      ),
      UiSeekCompletion.ignored,
    );
    expect(
      gate.completionFor(
        generation: remote,
        result: const SeekResult(
          disposition: SeekDisposition.executed,
          requestedTarget: Duration(seconds: 40),
          committedPosition: Duration(seconds: 40),
          settled: true,
        ),
      ),
      UiSeekCompletion.committed,
    );
  });

  test('all required cross-source matrices keep only the latest request', () {
    const matrices = [
      ('horizontal', 'remote'),
      ('progress', 'doubleTap'),
      ('horizontal', 'chapter'),
    ];
    for (final (firstSource, latestSource) in matrices) {
      final gate = UiSeekRequestGate();
      final first = gate.beginRequest();
      final latest = gate.beginRequest();
      for (final disposition in SeekDisposition.values) {
        expect(
          gate.completionFor(
            generation: first,
            result: SeekResult(
              disposition: disposition,
              requestedTarget: const Duration(seconds: 10),
              committedPosition: disposition == SeekDisposition.executed
                  ? const Duration(seconds: 10)
                  : null,
              settled: disposition == SeekDisposition.executed,
            ),
          ),
          UiSeekCompletion.ignored,
          reason: '$firstSource must not overwrite $latestSource',
        );
      }
      expect(
        gate.completionFor(
          generation: latest,
          result: const SeekResult(
            disposition: SeekDisposition.executed,
            requestedTarget: Duration(seconds: 40),
            committedPosition: Duration(seconds: 40),
            settled: true,
          ),
        ),
        UiSeekCompletion.committed,
      );
    }
  });

  test('only the latest failed request may surface a safe failure', () {
    final gate = UiSeekRequestGate();
    final old = gate.beginRequest();
    final latest = gate.beginRequest();
    const failure = SeekResult(
      disposition: SeekDisposition.failed,
      requestedTarget: Duration(seconds: 10),
      settled: false,
      failureKind: SeekFailureKind.engineError,
    );

    expect(
      gate.completionFor(generation: old, result: failure),
      UiSeekCompletion.ignored,
    );
    expect(
      gate.completionFor(generation: latest, result: failure),
      UiSeekCompletion.failed,
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

  test('route close invalidation rejects every late seek disposition', () {
    for (final disposition in SeekDisposition.values) {
      final gate = UiSeekRequestGate();
      final request = gate.beginRequest();
      gate.invalidate();

      expect(
        gate.completionFor(
          generation: request,
          result: SeekResult(
            disposition: disposition,
            requestedTarget: const Duration(seconds: 5),
            settled: disposition == SeekDisposition.executed,
            committedPosition: disposition == SeekDisposition.executed
                ? const Duration(seconds: 5)
                : null,
          ),
        ),
        UiSeekCompletion.ignored,
      );
    }
  });
}
