import 'package:emby_my_client/downloads/foreground_download_executor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'does not start the dataSync service from background restart events',
    () {
      final options = downloadForegroundTaskOptions();

      expect(options.autoRunOnBoot, isFalse);
      expect(options.autoRunOnMyPackageReplaced, isFalse);
      expect(options.allowAutoRestart, isFalse);
      expect(options.stopWithTask, isFalse);
    },
  );
}
