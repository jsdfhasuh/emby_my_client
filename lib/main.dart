import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'app.dart';
import 'core/diagnostic_log.dart';
import 'downloads/foreground_download_executor.dart';
import 'state/app_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  ForegroundDownloadExecutor.initializePlatform();
  await DiagnosticLog.instance.initialize();

  final controller = AppController();
  runApp(EmbyClientApp(controller: controller));
  unawaited(controller.initialize());
}
