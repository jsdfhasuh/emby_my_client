import 'package:flutter/services.dart';

import '../platform/platform_capabilities.dart';

class PictureInPictureController {
  PictureInPictureController({
    required this.onToggle,
    required this.onClose,
    this.onModeChanged,
    PlatformCapabilities? capabilities,
  }) : _capabilities = capabilities ?? PlatformCapabilities.current();

  static const _channel = MethodChannel('emby_my_client/picture_in_picture');

  final Future<void> Function() onToggle;
  final void Function() onClose;
  final void Function(bool active)? onModeChanged;
  final PlatformCapabilities _capabilities;

  bool isActive = false;
  bool isEntering = false;

  Future<void> initialize() async {
    if (!_capabilities.supportsPictureInPicture) return;
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  Future<bool> get isSupported async {
    if (!_capabilities.supportsPictureInPicture) return false;
    try {
      return await _channel.invokeMethod<bool>('isSupported') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> enter({required bool isPlaying}) async {
    if (!await isSupported) return false;
    isEntering = true;
    try {
      await updatePlaying(isPlaying);
      try {
        return await _channel.invokeMethod<bool>('enter') ?? false;
      } on MissingPluginException {
        return false;
      } on PlatformException {
        return false;
      }
    } finally {
      isEntering = false;
    }
  }

  Future<void> updatePlaying(bool isPlaying) async {
    if (!_capabilities.supportsPictureInPicture) return;
    try {
      await _channel.invokeMethod<void>('updatePlaying', isPlaying);
    } on MissingPluginException {
      // iOS has no native channel in the Core milestone.
    } on PlatformException {
      // A missing or unavailable native implementation is a safe no-op.
    }
  }

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
    if (_capabilities.supportsPictureInPicture) {
      _channel.setMethodCallHandler(null);
    }
  }
}
