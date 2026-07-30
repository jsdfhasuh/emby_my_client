import 'package:flutter/services.dart';

class PictureInPictureController {
  PictureInPictureController({
    required this.onToggle,
    required this.onClose,
    this.onModeChanged,
  });

  static const _channel = MethodChannel('emby_my_client/picture_in_picture');

  final Future<void> Function() onToggle;
  final void Function() onClose;
  final void Function(bool active)? onModeChanged;

  bool isActive = false;
  bool isEntering = false;

  Future<void> initialize() async {
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  Future<bool> get isSupported async =>
      await _channel.invokeMethod<bool>('isSupported') ?? false;

  Future<bool> enter({required bool isPlaying}) async {
    isEntering = true;
    try {
      await updatePlaying(isPlaying);
      return await _channel.invokeMethod<bool>('enter') ?? false;
    } finally {
      isEntering = false;
    }
  }

  Future<void> updatePlaying(bool isPlaying) =>
      _channel.invokeMethod<void>('updatePlaying', isPlaying);

  Future<void> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'pipAction':
        if (call.arguments == 'toggle') {
          await onToggle();
        } else if (call.arguments == 'close') {
          onClose();
        }
      case 'pipModeChanged':
        isActive = call.arguments == true;
        onModeChanged?.call(isActive);
    }
  }

  void dispose() {
    _channel.setMethodCallHandler(null);
  }
}
