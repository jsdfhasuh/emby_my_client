import 'package:emby_my_client/playback/playback_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('optional mpv property failures do not escape', () async {
    final calls = <String>[];
    final writer = SafeNativePropertyWriter((property, value) async {
      calls.add('$property=$value');
      if (property == 'audio-delay' || property == 'sub-color') {
        throw StateError('unsupported optional property');
      }
    });

    await writer.write('audio-delay', '0.250');
    await writer.write('sub-delay', '-0.125');
    await writer.write('sub-font-size', '34.0');
    await writer.write('sub-color', '#FFFFFFFF');
    await writer.write('sub-border-color', '#FF000000');
    await writer.write('sub-pos', '100');

    expect(calls, [
      'audio-delay=0.250',
      'sub-delay=-0.125',
      'sub-font-size=34.0',
      'sub-color=#FFFFFFFF',
      'sub-border-color=#FF000000',
      'sub-pos=100',
    ]);
  });
}
