// 扫码 entry, movable to any pairing page (#13): the Android camera (with its
// photo fallback) and the HarmonyOS system scanner. The old relay pairing page
// and the paired-computer page both use this, so it lives in its own place.

import 'dart:async';

import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/ui/remote/pairing/scan_box.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../chat/support/harness.dart';

const _code = 'https://dsh.r2049.cn/pair?auth=ABCD2345';

/// A camera that never opens and reports nothing.
class _NoCamera extends MobileScannerPlatform {
  @override
  Stream<BarcodeCapture?> get barcodesStream => const Stream.empty();
  @override
  Stream<TorchState> get torchStateStream => const Stream.empty();
  @override
  Stream<double> get zoomScaleStateStream => const Stream.empty();

  @override
  Future<MobileScannerViewAttributes> start(StartOptions options) => Completer<MobileScannerViewAttributes>().future;

  @override
  Widget buildCameraView() => const ColoredBox(color: Colors.black);
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const appChannel = MethodChannel('dsh/app');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late MobileScannerPlatform original;
  late List<String> reported;
  late List<String> calls;
  late Future<Object?> Function() answer;

  setUp(() {
    reported = [];
    calls = [];
    answer = () async => _code;
    original = MobileScannerPlatform.instance;
    MobileScannerPlatform.instance = _NoCamera();
    messenger.setMockMethodCallHandler(appChannel, (call) {
      calls.add(call.method);
      return answer();
    });
  });

  tearDown(() {
    MobileScannerPlatform.instance = original;
    messenger.setMockMethodCallHandler(appChannel, null);
  });

  Widget app(String os) => testApp(
    Scaffold(
      body: Consumer(
        builder: (context, ref, _) => ref.watch(scanBoxProvider)(context, reported.add),
      ),
    ),
    overrides: [operatingSystemProvider.overrideWithValue(os)],
  );

  Future<void> leave(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(tester.takeException(), isNull);
  }

  testWidgets('HarmonyOS: the box opens the system scan page and reports its text', (tester) async {
    await tester.pumpWidget(app('ohos'));
    await tester.tap(find.text('扫码'));
    await tester.pumpAndSettle();
    expect(calls, ['scanQrCode']);
    expect(reported, [_code]);
    await leave(tester);
  });

  testWidgets('HarmonyOS: a scan page that will not open says the paste way is still there', (tester) async {
    answer = () async => throw PlatformException(code: 'unavailable');
    await tester.pumpWidget(app('ohos'));
    await tester.tap(find.text('扫码'));
    await tester.pumpAndSettle();
    expect(find.textContaining('二维码识别器不可用'), findsOneWidget);
    expect(reported, isEmpty);
    await leave(tester);
  });

  testWidgets('Android: the camera box waits for the SDK and never asks for the system scan page', (tester) async {
    final ready = Completer<Object?>();
    answer = () => ready.future;
    await tester.pumpWidget(app('android'));
    await tester.pump();
    expect(find.byType(MobileScanner), findsNothing, reason: 'the shared SDK is not ready yet');
    expect(calls, ['initializePairingScanner']);
    ready.complete(null);
    await tester.pumpAndSettle();
    expect(find.byType(MobileScanner), findsOneWidget);
    expect(calls, ['initializePairingScanner'], reason: 'HarmonyOS only');
    await leave(tester);
  });
}
