// 配对电脑 (#13): three ways in — scan the code, paste the link, type the
// 8-character code — plus the progress a person watches (parse → exchange →
// connect) and the one sentence a failure gives.

import 'dart:async';

import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/remote/link_status.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/paired_hosts_state.dart';
import 'package:dsh_app/ui/remote/pairing/paired_pairing_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../shell/golden_harness.dart';
import 'support/fake_relay.dart';

/// A camera the system refuses.
class _DeniedCamera extends MobileScannerPlatform {
  @override
  Stream<BarcodeCapture?> get barcodesStream => const Stream.empty();
  @override
  Stream<TorchState> get torchStateStream => const Stream.empty();
  @override
  Stream<double> get zoomScaleStateStream => const Stream.empty();

  @override
  Future<MobileScannerViewAttributes> start(StartOptions options) async =>
      throw const MobileScannerException(errorCode: MobileScannerErrorCode.permissionDenied);

  @override
  Widget buildCameraView() => const ColoredBox(color: Colors.black);
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}

  @override
  Future<BarcodeCapture?> analyzeImage(String path, {List<BarcodeFormat> formats = const []}) async => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MemorySecretStore secrets;
  late StreamController<HostLinkStatus> statuses;

  setUp(() {
    secrets = MemorySecretStore();
    statuses = StreamController<HostLinkStatus>.broadcast();
  });

  tearDown(() async => statuses.close());

  List<Override> overrides() => [
    secretStoreProvider.overrideWithValue(secrets),
    networkKicksProvider.overrideWithValue(const Stream.empty()),
    relayBackendProvider.overrideWithValue(FakeRelayBackend()),
    urlOpenerProvider.overrideWithValue((_) async => true),
    localRuntimeProvider.overrideWith(() => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus))),
    // This suite is about the page, not about dialing a gateway: the link's
    // own states are fed in by hand.
    hostLinkStatusProvider.overrideWith((ref, host) => statuses.stream),
  ];

  Future<ProviderContainer> pump(WidgetTester tester) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(home: const PairedPairingPage(), brightness: Brightness.light, overrides: overrides()),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    return ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
  }

  /// One computer already paired, so the bare-code entry has a target.
  Future<void> seedKnownComputer(WidgetTester tester, ProviderContainer scope) async {
    await scope.read(pairedHostsProvider.notifier).ready;
    await scope.read(pairedHostsProvider.notifier).pair('http://192.168.1.5:3088?auth=ABCD2345', name: '书房');
    await tester.pump();
  }

  Future<void> submit(WidgetTester tester, String text, {required String entry}) async {
    await tester.tap(find.text(entry));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), text);
    await tester.pump();
    await tester.tap(find.text('配对'));
    await tester.pumpAndSettle();
  }

  testWidgets('a pasted link becomes a paired computer and is switched to', (tester) async {
    final scope = await pump(tester);
    await submit(tester, 'http://192.168.1.5:3088?auth=abcd2345', entry: '粘贴链接');

    final records = scope.read(pairedHostsProvider).records;
    expect(records, hasLength(1));
    expect(records.single.entry.authority, '192.168.1.5:3088', reason: 'the address kept, the code not');
    expect(
      scope.read(pairedHostsProvider.notifier).codeFor(records.single.id),
      'ABCD2345',
      reason: 'typed in lower case, kept and sent upper case',
    );
    expect(scope.read(activeHostProvider), HostRef.paired(records.single.id), reason: 'switched to it at once');
  });

  testWidgets('the 8-character code is typed in lower case and travels upper case', (tester) async {
    final scope = await pump(tester);
    await seedKnownComputer(tester, scope);
    final id = scope.read(pairedHostsProvider).records.single.id;

    await tester.tap(find.text('手输配对码'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'wxyz6789');
    await tester.pump();
    // Shown upper case, the way it is sent.
    expect(find.widgetWithText(TextField, 'WXYZ6789'), findsOneWidget);

    await tester.tap(find.text('配对'));
    await tester.pumpAndSettle();
    expect(scope.read(pairedHostsProvider.notifier).codeFor(id), 'WXYZ6789');
    expect(scope.read(activeHostProvider), HostRef.paired(id), reason: 'a new code, the same computer');
  });

  testWidgets('a bare code with no known computer asks for the link instead', (tester) async {
    final scope = await pump(tester);
    await submit(tester, 'WXYZ6789', entry: '手输配对码');

    expect(scope.read(pairedHostsProvider).records, isEmpty);
    expect(scope.read(activeHostProvider), HostRef.local);
    expect(find.text('只输配对码要先有一台已知的电脑；先粘贴电脑上的配对链接'), findsOneWidget);
  });

  testWidgets('progress runs 解析 → 兑换 → 连接 and ends connected', (tester) async {
    final scope = await pump(tester);
    await submit(tester, 'http://192.168.1.5:3088?auth=ABCD2345', entry: '粘贴链接');

    for (final step in ['解析配对信息', '兑换配对码', '连接电脑']) {
      expect(find.text(step), findsOneWidget); // one line per stage it is going through
    }

    statuses.add(const HostLinkStatus(HostLinkPhase.connecting, step: HostLinkStep.connect, detail: '192.168.1.5:3088'));
    await tester.pump();
    statuses.add(
      const HostLinkStatus(HostLinkPhase.connected, completed: {...HostLinkStep.values}, detail: '192.168.1.5:3088'),
    );
    await tester.pumpAndSettle();

    expect(find.text('已连上「192.168.1.5:3088」'), findsOneWidget);
    expect(find.text('完成'), findsOneWidget);
    expect(scope.read(activeHostProvider), isNot(HostRef.local), reason: 'the paired computer is the active host');
  });

  testWidgets('a spent code says to refresh it on the computer, and offers a retry', (tester) async {
    await pump(tester);
    await submit(tester, 'http://192.168.1.5:3088?auth=ABCD2345', entry: '粘贴链接');

    statuses.add(
      const HostLinkStatus(
        HostLinkPhase.failed,
        step: HostLinkStep.connect,
        error: HostLinkError(
          HostLinkErrorKind.authFailed,
          '配对凭据已失效，需要重新配对',
          diagnosticCode: HostLinkDiagnosticCode.pairedTicketRejected,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('配对码已失效或已被使用，请回到电脑上刷新配对码'), findsOneWidget);
    expect(find.text('再试一次'), findsOneWidget);
  });

  testWidgets('a camera the system refuses hands over to the entries that need none', (tester) async {
    final original = MobileScannerPlatform.instance;
    MobileScannerPlatform.instance = _DeniedCamera();
    addTearDown(() => MobileScannerPlatform.instance = original);
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('dsh/app'), (call) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(const MethodChannel('dsh/app'), null));

    await pump(tester);
    await tester.pumpAndSettle();

    expect(find.text('相机用不了，改用粘贴链接或手输配对码'), findsOneWidget);
    // The entry that needs no camera is the one showing, so pairing can go on.
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('读取剪贴板'), findsOneWidget, reason: 'the paste entry, not the camera');
  });

  testWidgets('the two lifetimes are told apart: a 5-minute code, a 30-day computer', (tester) async {
    await pump(tester);
    await tester.tap(find.text('手输配对码'));
    await tester.pumpAndSettle();
    expect(find.text('配对码 5 分钟内有效，只能用一次；过期了回电脑上刷新'), findsOneWidget);
    expect(find.text('连上之后这台电脑保持 30 天，不用每次输入配对码'), findsOneWidget);
  });
}
