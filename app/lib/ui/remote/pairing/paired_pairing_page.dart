// 配对电脑: the three ways a person can hand this phone a computer — scan the
// code on its screen, paste the access link, or type its 8-character code —
// then the progress of the one thing that follows (解析 → 兑换 → 连接), and one
// sentence when it fails.
//
// The code lives only as long as its first connect: it is single use and good
// for 5 minutes; what keeps the computer paired afterwards is its 30-day ticket.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart' show DshPairingInput;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../remote/link_status.dart';
import '../../../state/connection_state.dart';
import '../../../state/hosts_state.dart';
import '../../../remote/paired/paired_host_store.dart';
import '../../../state/paired_hosts_state.dart';
import '../../common/brief_notice.dart';
import '../../settings/settings_widgets.dart';
import '../../shell/page_frame.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import '../host_key_dialog.dart' show activateHost;
import 'scan_box.dart';

/// The three entries, in the order the page shows them.
enum PairingEntry { scan, paste, code }

class PairedPairingPage extends ConsumerStatefulWidget {
  const PairedPairingPage({super.key});

  static Route<void> route() => MaterialPageRoute<void>(builder: (_) => const PairedPairingPage());

  @override
  ConsumerState<PairedPairingPage> createState() => _PairedPairingPageState();
}

class _PairedPairingPageState extends ConsumerState<PairedPairingPage> {
  PairingEntry _entry = PairingEntry.scan;

  /// What the reader said, when it could not run at all.
  ScanBoxTrouble? _trouble;

  /// The 8-character code as typed; shown and sent upper case.
  final _code = TextEditingController();

  /// The computer being paired with, once it is kept.
  PairedHostRecord? _pairing;
  HostLinkStatus? _status;
  String? _problem;
  bool _busy = false;
  ProviderSubscription<AsyncValue<HostLinkStatus>>? _statusSub;


  @override
  void initState() {
    super.initState();
    _code.addListener(_onTyped);
  }

  @override
  void dispose() {
    _statusSub?.close();
    _code.removeListener(_onTyped);
    _code.dispose();
    super.dispose();
  }

  /// Upper case as it is typed: the code travels that way, and a phone that
  /// starts in lower case must not make the person fix it.
  void _onTyped() {
    final upper = _code.text.toUpperCase();
    if (upper == _code.text) return;
    _code.value = TextEditingValue(text: upper, selection: TextSelection.collapsed(offset: upper.length));
  }

  /// The reader could not run: offer the ways in that need no camera, and say
  /// why they are the ones on offer.
  void _onTrouble(ScanBoxTrouble trouble) {
    if (!mounted || _trouble == trouble) return;
    setState(() {
      _trouble = trouble;
      if (_entry == PairingEntry.scan) _entry = PairingEntry.paste;
    });
  }

  Future<void> _pasteLink() async {
    final text = await _clipboard();
    if (text == null || !mounted) return;
    _entry = PairingEntry.paste;
    await _pair(text);
  }

  Future<String?> _clipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (!mounted) return null;
    if (text.isEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showBriefNotice(context.l10n.remotePairPasteEmpty);
      return null;
    }
    return text;
  }

  /// Keeps the computer the input names, then connects to it once. The code is
  /// spent by that connect, whatever it answers.
  Future<void> _pair(String input) async {
    if (_busy) return;
    final l10n = context.l10n;
    setState(() {
      _busy = true;
      _problem = null;
      _pairing = null;
      _status = null;
    });
    _statusSub?.close();
    _statusSub = null;

    final records = ref.read(pairedHostsProvider.notifier);
    final record = await records.pair(input);
    if (!mounted) return;
    if (record == null) {
      setState(() {
        _busy = false;
        // A bare code needs a computer to belong to; anything else is not a
        // pairing input at all.
        _problem = DshPairingInput.codeOf(input) != null ? l10n.remotePairErrBareCode : l10n.remotePairErrNotPairing;
      });
      return;
    }
    setState(() => _pairing = record);
    // No confirmation of the computer here: pairing already named it, and the
    // first connect is the test of it.
    final host = HostRef.paired(record.id, name: record.name);
    _statusSub = ref.listenManual(hostLinkStatusProvider(host), (_, next) {
      final value = next.value;
      if (!mounted || value == null) return;
      setState(() => _status = value);
      if (value.phase == HostLinkPhase.failed && value.error != null) {
        setState(() => _problem = _sentence(value.error!));
      }
    }, fireImmediately: true);

    final ok = await activateHost(context, ref, host);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) setState(() => _problem = l10n.remotePairErrNotConnected);
  }

  /// One sentence a person can act on, per failure kind. The gateway's own
  /// message never reaches the page: it is not written for a person holding a
  /// phone.
  static String _sentence(HostLinkError error) => switch (error.diagnosticCode) {
    HostLinkDiagnosticCode.pairedTicketRejected => appL10n.remotePairErrCodeStale,
    HostLinkDiagnosticCode.pairedBanned => appL10n.pairedErrBanned(_firstNumber(error.message)),
    HostLinkDiagnosticCode.pairedComputerFailed => appL10n.pairedErrComputer,
    HostLinkDiagnosticCode.pairedGatewayRefused => appL10n.pairedErrEntryRefused(_firstNumber(error.message)),
    HostLinkDiagnosticCode.pairedUnreachable => appL10n.remoteErrHostUnreachable,
    _ => switch (error.kind) {
      HostLinkErrorKind.authFailed => appL10n.remotePairErrCodeStale,
      HostLinkErrorKind.unreachable => appL10n.remoteErrHostUnreachable,
      _ => appL10n.pairedErrComputer,
    },
  };

  static int _firstNumber(String text) => int.tryParse(RegExp(r'\d+').firstMatch(text)?.group(0) ?? '') ?? 0;

  void _retry() {
    final code = _code.text.trim();
    setState(() {
      _problem = null;
      _pairing = null;
      _status = null;
    });
    if (code.isNotEmpty) unawaited(_pair(code));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final pairing = _pairing;
    return AppPage.list(
      title: l10n.remotePairedPageTitle,
      subtitle: Text(l10n.remotePairSubtitle),
      children: [
        if (pairing == null)
          SettingsSection(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SegmentedPill<PairingEntry>(
                      segments: [
                        PillSegment(PairingEntry.scan, l10n.remotePairScan),
                        PillSegment(PairingEntry.paste, l10n.remotePairPaste),
                        PillSegment(PairingEntry.code, l10n.remotePairCode),
                      ],
                      selected: _entry,
                      onChanged: (value) => setState(() {
                        _entry = value;
                        _problem = null;
                      }),
                    ),
                    if (_trouble case final trouble?) ...[
                      const SizedBox(height: 10),
                      Text(
                        trouble == ScanBoxTrouble.permissionDenied
                            ? l10n.remotePairFallbackDenied
                            : l10n.remotePairFallbackFailed,
                        textAlign: TextAlign.center,
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(color: DshColors.of(context).warning, height: 1.5),
                      ),
                    ],
                    const SizedBox(height: 14),
                    switch (_entry) {
                      PairingEntry.scan => _ScanEntry(
                        onCode: _pair,
                        onTrouble: _onTrouble,
                        onPaste: () => unawaited(_pasteLink()),
                        onType: () => setState(() => _entry = PairingEntry.code),
                      ),
                      PairingEntry.paste => _LinkEntry(onSubmit: _pair),
                      PairingEntry.code => _CodeEntry(controller: _code, onSubmit: () => _pair(_code.text)),
                    },
                  ],
                ),
              ),
            ],
          ),
        if (pairing != null)
          _ProgressCard(
            record: pairing,
            status: _status,
            busy: _busy,
          ),
        if (_problem case final message?) _ProblemCard(message: message, onRetry: _retry),
        const SizedBox(height: 8),
      ],
    );
  }
}

/// Scan: the camera, or the ways in that need none when it cannot run.
class _ScanEntry extends ConsumerWidget {
  const _ScanEntry({
    required this.onCode,
    required this.onTrouble,
    required this.onPaste,
    required this.onType,
  });

  final ValueChanged<String> onCode;
  final ValueChanged<ScanBoxTrouble> onTrouble;
  final VoidCallback onPaste;
  final VoidCallback onType;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AspectRatio(
          aspectRatio: 1,
          child: ClipRSuperellipse(
            borderRadius: AppShape.radiusLg,
            child: ref.watch(scanBoxProvider)(context, onCode, onTrouble: onTrouble),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          l10n.remotePairScanHintBody,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant, height: 1.5),
        ),
        const SizedBox(height: 2),
        Wrap(
          alignment: WrapAlignment.center,
          children: [
            TextButton.icon(
              onPressed: onPaste,
              icon: const Icon(AppIcons.paste, size: 18),
              label: Text(l10n.remotePairPasteLink),
            ),
            TextButton.icon(
              onPressed: onType,
              icon: const Icon(AppIcons.enterPath, size: 18),
              label: Text(l10n.remotePairTypeCode),
            ),
          ],
        ),
      ],
    );
  }
}

/// Paste: the access link, and the key that reads the clipboard into it.
class _LinkEntry extends StatefulWidget {
  const _LinkEntry({required this.onSubmit});

  final ValueChanged<String> onSubmit;

  @override
  State<_LinkEntry> createState() => _LinkEntryState();
}

class _LinkEntryState extends State<_LinkEntry> {
  final _link = TextEditingController();

  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  /// Reads the clipboard into the field: a remainder of an earlier copy is
  /// visible before it is submitted.
  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (!mounted) return;
    if (text.isEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showBriefNotice(context.l10n.remotePairPasteEmpty);
      return;
    }
    _link.text = text;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const ValueKey('pairing-link'),
          controller: _link,
          keyboardType: TextInputType.url,
          autocorrect: false,
          enableSuggestions: false,
          minLines: 1,
          maxLines: 2,
          decoration: InputDecoration(hintText: l10n.remotePairLinkHint),
          onSubmitted: widget.onSubmit,
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            TextButton.icon(
              onPressed: () => unawaited(_paste()),
              icon: const Icon(AppIcons.paste, size: 18),
              label: Text(l10n.remotePairFromClipboard),
            ),
            const Spacer(),
            FilledButton(onPressed: () => widget.onSubmit(_link.text), child: Text(l10n.remotePairSubmit)),
          ],
        ),
        const SizedBox(height: 4),
        const _Lifetimes(),
      ],
    );
  }
}

/// Type: the 8-character code, upper case as it is shown and sent.
class _CodeEntry extends StatelessWidget {
  const _CodeEntry({required this.controller, required this.onSubmit});

  final TextEditingController controller;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const ValueKey('pairing-code'),
          controller: controller,
          autofocus: true,
          autocorrect: false,
          enableSuggestions: false,
          textCapitalization: TextCapitalization.characters,
          maxLength: DshPairingInput.codeLength,
          style: AppType.mono(size: 20),
          decoration: InputDecoration(hintText: l10n.remotePairCodeHint, counterText: ''),
          onSubmitted: (_) => onSubmit(),
        ),
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Text(
                l10n.remotePairCodeHintBody,
                style: theme.textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary, height: 1.5),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(onPressed: onSubmit, child: Text(l10n.remotePairSubmit)),
          ],
        ),
        const SizedBox(height: 4),
        _Lifetimes(),
      ],
    );
  }
}

/// The two lifetimes, told apart: the code is spent at once, the computer stays
/// paired for a month.
class _Lifetimes extends StatelessWidget {
  const _Lifetimes();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final style = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary, height: 1.6);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.remotePairLifetimeCode, style: style),
        Text(l10n.remotePairLifetimeTicket, style: style),
      ],
    );
  }
}

/// The progress of the one flow that follows an input: the computer kept, then
/// its first connect, step by step, and what it ended as.
class _ProgressCard extends StatelessWidget {
  const _ProgressCard({required this.record, required this.status, required this.busy});

  final PairedHostRecord record;
  final HostLinkStatus? status;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final phase = status?.phase;
    final connected = phase == HostLinkPhase.connected;
    final failed = phase == HostLinkPhase.failed;
    // A computer nobody renamed is known by the address its link named.
    final name = record.name ?? record.entry.authority;
    // The exchange is what the code is spent on; the connect comes after it.
    final sent = busy || status != null;
    _StageState stage(bool done, bool running) =>
        done ? _StageState.done : failed ? _StageState.failed : running ? _StageState.running : _StageState.pending;
    return SettingsSection(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    connected ? AppIcons.success : AppIcons.computer,
                    size: 20,
                    color: connected ? colors.success : theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      connected ? l10n.remotePairConnected(name) : l10n.remotePairProgressTitle(name),
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // Parsing already happened: the record in hand is its result.
              _Stage(label: l10n.remotePairStageParse, state: _StageState.done),
              _Stage(label: l10n.remotePairStageExchange, state: stage(connected, sent && !connected)),
              _Stage(label: l10n.remotePairStageConnect, state: stage(connected, sent && phase == HostLinkPhase.connecting)),
              const SizedBox(height: 4),
              Text(record.entry.authority, style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary)),
              if (connected) ...[
                const SizedBox(height: 8),
                Text(
                  l10n.remotePairLifetimeTicket,
                  style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary, height: 1.5),
                ),
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    child: Text(l10n.commonDone),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

enum _StageState { pending, running, done, failed }

class _Stage extends StatelessWidget {
  const _Stage({required this.label, required this.state});

  final String label;
  final _StageState state;

  @override
  Widget build(BuildContext context) {
    final colors = DshColors.of(context);
    final theme = Theme.of(context);
    final (Widget glyph, Color color) = switch (state) {
      _StageState.done => (Icon(AppIcons.completed, size: 16, color: colors.success), colors.success),
      _StageState.running => (
        SizedBox.square(
          dimension: 16,
          child: CircularProgressIndicator(strokeWidth: 2, color: theme.colorScheme.primary),
        ),
        theme.colorScheme.primary,
      ),
      _StageState.failed => (Icon(AppIcons.failed, size: 16, color: colors.danger), colors.danger),
      _StageState.pending => (Icon(AppIcons.waiting, size: 16, color: colors.textTertiary), colors.textTertiary),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          glyph,
          const SizedBox(width: 8),
          Expanded(child: Text(label, style: theme.textTheme.bodyMedium?.copyWith(color: color))),
        ],
      ),
    );
  }
}

/// What went wrong, as one sentence with the fix, plus the way to try again.
class _ProblemCard extends StatelessWidget {
  const _ProblemCard({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    return SettingsSection(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(AppIcons.warning, size: 20, color: colors.danger),
                  const SizedBox(width: 10),
                  Expanded(child: Text(l10n.remotePairFailedTitle, style: theme.textTheme.titleMedium)),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                message,
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant, height: 1.5),
              ),
            ],
          ),
        ),
        SettingsTile(icon: AppIcons.retry, tinted: false, title: l10n.remotePairTryAgain, onTap: onRetry),
      ],
    );
  }
}
