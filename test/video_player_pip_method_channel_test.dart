import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:awesome_video_player_pip/video_player_pip_method_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  MethodChannelVideoPlayerPip platform = MethodChannelVideoPlayerPip();
  const MethodChannel channel = MethodChannel('video_player_pip');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (MethodCall methodCall) async {
        switch (methodCall.method) {
          case 'isPipSupported':
            return true;
          case 'enterPipMode':
          case 'exitPipMode':
          case 'isInPipMode':
          case 'enableAutoPip':
          case 'disableAutoPip':
            return true;
          default:
            return null;
        }
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      null,
    );
  });

  test('isPipSupported', () async {
    expect(await platform.isPipSupported(), true);
  });

  test('enterPipMode', () async {
    expect(await platform.enterPipMode(123, width: 100, height: 200), true);
  });

  test('exitPipMode', () async {
    expect(await platform.exitPipMode(), true);
  });

  test('isInPipMode', () async {
    expect(await platform.isInPipMode(), true);
  });

  test('enableAutoPip', () async {
    expect(await platform.enableAutoPip(123), true);
  });

  test('disableAutoPip', () async {
    expect(await platform.disableAutoPip(), true);
  });
}
