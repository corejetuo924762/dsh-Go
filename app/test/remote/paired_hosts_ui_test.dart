// 主机列表 (#13): a paired computer shows its name and address, no
// fingerprint, no first-connect confirmation — and can be renamed, switched to
// and forgotten from the list it lives in.

import 'dart:async';

import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/paired_hosts_state.dart';
import 'package:dsh_app/ui/remote/host_switcher.dart';
import 'package:dsh_app/ui/remote/remote_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart';

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
    localRuntimeProvider.overrideWith(() => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus))),
    hostLinkStatusProvider.overrideWith((ref, host) => statuses.stream),
  ];

  /// A sheet holding nothing but itself, opened by a key: the real page pops
  /// its own drawer on the way, and these tests are about the list's rows.
  Future<ProviderContainer> pumpSheet(WidgetTester tester) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showHostSheet(context, onManage: () {}),
                child: const Text('open'),
              ),
            ),
          ),
        ),
        brightness: Brightness.light,
        overrides: overrides(),
      ),
    );
    await tester.pump();
    return ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
  }

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> seed(ProviderContainer scope, {String name = '书房'}) async {
    await scope.read(pairedHostsProvider.notifier).ready;
    await scope.read(pairedHostsProvider.notifier).pair('http://192.168.1.5:3088?auth=ABCD2345', name: name);
  }

  testWidgets('a paired computer is listed by name and address, with no fingerprint', (tester) async {
    final scope = await pumpSheet(tester);
    await seed(scope);
    await open(tester);

    expect(find.text('书房'), findsOneWidget);
    expect(find.text('192.168.1.5:3088'), findsOneWidget);
    expect(find.textContaining('指纹'), findsNothing);
    // No confirmation to click through: the row is the whole first connect.
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('renaming a paired computer keeps it the same host', (tester) async {
    final scope = await pumpSheet(tester);
    await seed(scope);
    final id = scope.read(pairedHostsProvider).records.single.id;
    await open(tester);

    await tester.longPress(find.text('书房'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重命名电脑'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '客厅');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(scope.read(pairedHostsProvider).records.single.id, id, reason: 'same identity');
    expect(scope.read(pairedHostsProvider).records.single.name, '客厅');
    expect(find.text('客厅'), findsOneWidget);
  });

  testWidgets('a forgotten paired computer leaves the list and goes back to 本机', (tester) async {
    final scope = await pumpSheet(tester);
    await seed(scope);
    final id = scope.read(pairedHostsProvider).records.single.id;
    scope.read(activeHostProvider.notifier).select(HostRef.paired(id));
    await open(tester);

    await tester.longPress(find.text('书房'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移除这台电脑'));
    await tester.pumpAndSettle();
    // The dialog's own confirm key.
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(scope.read(pairedHostsProvider).records, isEmpty);
    expect(secrets.values, isEmpty, reason: 'its ticket goes too');
    expect(scope.read(activeHostProvider), HostRef.local, reason: 'nothing left to be active');
    expect(find.text('书房'), findsNothing);
  });

  testWidgets('the remote page offers 添加配对电脑', (tester) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(home: const RemoteScreen(), brightness: Brightness.light, overrides: overrides()),
    );
    // The page keeps work of its own going (the account's hosts refresh); frames
    // are pumped by hand rather than settled.
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.text('添加配对电脑'), findsOneWidget);
    await tester.tap(find.text('添加配对电脑'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('扫码'), findsOneWidget, reason: 'the pairing page is open, on its scan entry');
    expect(find.text('粘贴链接'), findsOneWidget);
  });
}
