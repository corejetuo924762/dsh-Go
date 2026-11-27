// The ban countdown in LinkErrorBox: the remaining seconds drain once a second
// and the retry button is withheld until the ban lapses, so a sleeping gateway
// is never dialed again mid-ban.

import 'package:dsh_app/remote/link_status.dart';
import 'package:dsh_app/ui/remote/link_progress.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpBox(WidgetTester tester, {required HostLinkError error, VoidCallback? onRetry}) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        home: Scaffold(
          body: Center(
            child: LinkErrorBox(error: error, action: onRetry == null ? null : ('重试', onRetry)),
          ),
        ),
        brightness: Brightness.light,
      ),
    );
    await tester.pump();
  }

  TextButton retryButton(WidgetTester tester) => tester.widget<TextButton>(find.widgetWithText(TextButton, '重试'));

  testWidgets('a ban counts down each second and disables retry while it lasts', (tester) async {
    var retries = 0;
    await pumpBox(
      tester,
      error: const HostLinkError(
        HostLinkErrorKind.unreachable,
        'banned',
        retryable: false,
        diagnosticCode: HostLinkDiagnosticCode.pairedBanned,
        banRemaining: Duration(seconds: 3),
      ),
      onRetry: () => retries++,
    );

    expect(find.text('配对尝试次数过多，还需等待 3 秒'), findsOneWidget);
    expect(retryButton(tester).onPressed, isNull, reason: 'during the ban, retry is withheld');

    await tester.pump(const Duration(seconds: 1));
    expect(find.text('配对尝试次数过多，还需等待 2 秒'), findsOneWidget);
    expect(retryButton(tester).onPressed, isNull);

    await tester.pump(const Duration(seconds: 2));
    expect(find.text('配对尝试次数过多，还需等待 0 秒'), findsOneWidget);
    expect(retryButton(tester).onPressed, isNotNull, reason: 'once it lapses, retry works again');
    expect(retries, 0, reason: 'tapping was never possible during the ban');
  });

  testWidgets('a non-ban error keeps its own message and its retry enabled', (tester) async {
    await pumpBox(
      tester,
      error: const HostLinkError(
        HostLinkErrorKind.other,
        '那台电脑没能确认这次访问',
        diagnosticCode: HostLinkDiagnosticCode.pairedComputerFailed,
      ),
      onRetry: () {},
    );

    expect(find.text('那台电脑没能确认这次访问'), findsOneWidget);
    expect(retryButton(tester).onPressed, isNotNull);
  });
}
