import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../runtime/local_footprint.dart';
import '../../runtime/runtime_state.dart';
import '../../state/app_info.dart';
import '../../state/connection_state.dart';
import '../../state/hosts_state.dart';
import '../../remote/paired/paired_host_store.dart';
import '../../state/paired_hosts_state.dart';
import '../common/ask_ai.dart';
import '../common/overview_card.dart';
import '../common/status_chip.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import '../web/web_view_page.dart';
import 'host_key_dialog.dart';
import 'host_status.dart';
import 'link_progress.dart';
import 'pairing/paired_host_actions.dart';
import 'pairing/paired_pairing_page.dart';
import 'ssh_host_form.dart';

/// 远程主机 (a list page): the computers this phone can drive.
///
/// From the top: the host in use; SSH hosts (self-contained: dsh-app starts
/// `dsh web` over SSH and tunnels to it); the computers paired from their
/// access links; then the connection settings and the rest. Picking a host
/// makes it the active one; the chat and the session list follow. A host's DSH
/// Web opens from 网页版, as on every host (dsh_web_launcher.dart).
class RemoteScreen extends ConsumerStatefulWidget {
  const RemoteScreen({super.key});

  @override
  ConsumerState<RemoteScreen> createState() => _RemoteScreenState();
}

class _RemoteScreenState extends ConsumerState<RemoteScreen> {
  void _openConsole() {
    final l10n = context.l10n;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => WebViewPage(
          url: Uri.parse(AppInfo.remoteConsole),
          title: l10n.remoteConsole,
          subtitle: 'dsh.r2049.cn',
          allowOpenExternal: true,
          // Android suspends the page in the background and its connection drops.
          reloadAfterBackground: const Duration(seconds: 60),
        ),
      ),
    );
  }

  Future<void> _use(HostRef host) async {
    final navigator = Navigator.of(context);
    if (ref.read(activeHostProvider) == host) {
      // Tapping the active host after a failure: confirm trust if that was
      // the problem, then connect again.
      final failed = ref.read(hostLinkStatusProvider(host)).value?.phase == HostLinkPhase.failed;
      if (!failed) {
        navigator.maybePop();
        return;
      }
      if (await activateHost(context, ref, host)) {
        ref.read(remoteConnectionProvider(host).notifier).retry();
      }
      return;
    }
    final ok = await activateHost(context, ref, host);
    if (ok && navigator.mounted) navigator.maybePop();
  }

  /// A host added while this phone has nothing to run on (no runtime, first
  /// run) is the one to use: take it at once instead of a second tap.
  Future<void> _addSsh() async {
    final saved = await Navigator.of(context)
        .push<SshHostConfig>(MaterialPageRoute(builder: (_) => const SshHostFormPage()));
    if (saved == null || !mounted) return;
    final nothingHere = ref.read(localRuntimeProvider).status.runtimeMissing;
    if (nothingHere && ref.read(activeHostProvider).isLocal) await _use(HostRef.ssh(saved.id));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final ssh = ref.watch(hostsProvider.select((s) => s.ssh));
    final paired = ref.watch(pairedHostsProvider).records;
    final active = ref.watch(activeHostProvider);
    void push(Widget page) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
    return AppPage.list(
      title: l10n.commonRemoteHost,
      subtitle: Text(l10n.remoteHostsIntro),
      actions: [const AskAiButton(AskAiTopic.remote)],
      children: [
        _ActiveCard(active: active),
        SettingsSection(
          title: l10n.remoteSshHosts,
          footer: Text(l10n.remoteSshRequirements),
          children: [
            for (final h in ssh)
              _SshRow(
                config: h,
                active: active == HostRef.ssh(h.id),
                onTap: () => unawaited(_use(HostRef.ssh(h.id))),
                onEdit: () => push(SshHostFormPage(existing: h)),
              ),
            SettingsTile(
              icon: AppIcons.add,
              tinted: false,
              spot: Spots.addSshHost,
              subtitle: ssh.isEmpty ? l10n.remoteSshDirect : null,
              onTap: () => unawaited(_addSsh()),
            ),
          ],
        ),
        // Paired computers stand next to SSH hosts: a phone reaches either the
        // same way, and neither needs an account.
        SettingsSection(
          title: l10n.remotePairedComputers,
          footer: Text(l10n.remotePairedComputersHint),
          children: [
            for (final h in paired)
              _PairedRow(
                record: h,
                active: active == HostRef.paired(h.id, name: h.name),
                onTap: () => unawaited(_use(HostRef.paired(h.id, name: h.name))),
                onManage: () => unawaited(showPairedHostActions(context, h)),
              ),
            SettingsTile(
              icon: AppIcons.qrCode,
              tinted: false,
              title: l10n.remotePairAddPairedComputer,
              subtitle: paired.isEmpty ? l10n.remotePairAddPairedComputerHint : null,
              onTap: () => push(const PairedPairingPage()),
            ),
          ],
        ),
        SettingsSection(
          title: l10n.remoteConnectionSettings,
          children: [
            // Only meaningful once there is a host to come back to.
            if (ssh.isNotEmpty || paired.isNotEmpty)
              SettingsSwitchTile(
                key: const ValueKey('remote-auto-connect'),
                spot: Spots.remoteAutoConnect,
                subtitle: l10n.remoteAutoConnectOnStartupHint,
                value: ref.watch(remoteAutoConnectProvider),
                onChanged: (value) => unawaited(ref.read(remoteAutoConnectProvider.notifier).set(value)),
              ),
          ],
        ),
        SettingsSection(
          title: l10n.commonMore,
          children: [
            SettingsTile(
              icon: AppIcons.webConsole,
              tinted: false,
              title: l10n.remoteWebConsole,
              subtitle: l10n.remoteWebConsoleProvider,
              onTap: _openConsole,
            ),
          ],
        ),
      ],
    );
  }
}

/// What the chat is talking to right now (only for a remote host), with live
/// state, the way back to 本机, and the failure with its one fix.
class _ActiveCard extends ConsumerWidget {
  const _ActiveCard({required this.active});

  final HostRef active;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    if (active.isLocal) return const SizedBox.shrink();
    final status = ref.watch(hostLinkStatusProvider(active)).value ?? HostLinkStatus.idle;
    final view = HostStatusView.ofLink(status);
    final name = ref.watch(hostNameProvider(active)) ?? l10n.commonRemoteHost;
    final ssh = active.kind == HostKind.ssh ? ref.watch(hostsProvider).sshById(active.id) : null;
    final error = status.error;
    // Errors a retry can't fix go to the host's settings (SSH).
    final needsSettings = ssh != null && error != null && !error.retryable;
    void reconnect() => ref.read(remoteConnectionProvider(active).notifier).retry();
    final failed = status.phase == HostLinkPhase.failed && error != null;
    // No runtime on this phone: 本机 is nowhere to go back to.
    final canGoLocal = ref.watch(localRuntimeProvider.select((s) => !s.status.runtimeMissing));
    return OverviewCard(
      leading: OverviewGlyph(hostKindIcon(active.kind), tint: hostKindTint(active.kind)),
      title: Text(l10n.remoteActiveHost(name)),
      subtitle: Row(
        children: [
          AnimatedStatusDot(tone: view.tone, size: 7),
          const SizedBox(width: 6),
          Flexible(
            child: Text(_statusLine(status, view, ssh?.address), maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
      trailing: canGoLocal
          ? _EdgeTextButton(
              label: l10n.remoteSwitchToPhone,
              onPressed: () => ref.read(activeHostProvider.notifier).select(HostRef.local),
            )
          : null,
      footer: failed
          ? Padding(
              padding: const EdgeInsets.only(left: OverviewCard.inset, right: OverviewCard.inset - 12),
              child: LinkErrorBox(
                error: error,
                action: needsSettings
                    ? (
                        l10n.remoteHostSettings,
                        () =>
                            Navigator.of(context)
                                .push(MaterialPageRoute<void>(builder: (_) => SshHostFormPage(existing: ssh))),
                      )
                    : (l10n.commonRetry, reconnect),
              ),
            )
          : null,
    );
  }

  static String _statusLine(HostLinkStatus status, HostStatusView view, String? address) {
    if (status.phase == HostLinkPhase.reconnecting) {
      final why = status.error?.message;
      return why == null ? appL10n.remoteReconnectingEllipsis : appL10n.remoteReconnectReason(why);
    }
    if (status.phase == HostLinkPhase.connected) {
      if (address != null) return appL10n.remoteConnectedSsh(address);
      return appL10n.remoteConnected;
    }
    return view.label;
  }
}

/// Dot + word on the right of a host row.
class _HostState extends StatelessWidget {
  const _HostState(this.view);

  final HostStatusView view;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedStatusDot(tone: view.tone, size: 7),
        const SizedBox(width: 6),
        Text(view.label),
      ],
    );
  }
}

/// A trailing text button whose label ends exactly at the row's 16dp edge.
class _EdgeTextButton extends StatelessWidget {
  const _EdgeTextButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  /// Horizontal padding inside the button.
  static const _pad = 8.0;

  @override
  Widget build(BuildContext context) {
    return Transform.translate(
      // Row padding (12) + button padding (8) − nudge (4) = 16 to the label.
      offset: const Offset(SettingsMetrics.trailingPad + _pad - SettingsMetrics.inset, 0),
      child: TextButton(
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: _pad),
          minimumSize: const Size(0, 40),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        onPressed: onPressed,
        child: Text(label),
      ),
    );
  }
}

/// A trailing 20dp icon button whose glyph ends at the row's 16dp edge.
class _EdgeIconButton extends StatelessWidget {
  const _EdgeIconButton({required this.icon, required this.tooltip, required this.onPressed});

  final Widget icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    // Compact box 40, glyph 20: 10 of air; row padding 12 → nudge 6.
    return Transform.translate(
      offset: const Offset(SettingsMetrics.trailingPad + 10 - SettingsMetrics.inset, 0),
      child: IconButton(
        tooltip: tooltip,
        visualDensity: VisualDensity.compact,
        color: DshColors.of(context).textTertiary,
        icon: icon,
        onPressed: onPressed,
      ),
    );
  }
}

class _SshRow extends ConsumerWidget {
  const _SshRow({required this.config, required this.active, required this.onTap, required this.onEdit});

  final SshHostConfig config;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final view = active ? watchHostStatus(ref, HostRef.ssh(config.id)) : null;
    return Semantics(
      selected: active,
      inMutuallyExclusiveGroup: true,
      child: SettingsTile(
        icon: hostKindIcon(HostKind.ssh),
        tinted: false,
        title: config.name,
        subtitle: config.address,
        onTap: onTap,
        value: view == null ? null : _HostState(view),
        trailing: _EdgeIconButton(
          icon: const Icon(AppIcons.configure, size: 20),
          tooltip: l10n.commonEdit,
          onPressed: onEdit,
        ),
      ),
    );
  }
}

/// A paired computer: the name the person gave it and the address its link
/// named. No fingerprint, and no confirmation on the first connect — pairing
/// already said which computer this is.
class _PairedRow extends ConsumerWidget {
  const _PairedRow({required this.record, required this.active, required this.onTap, required this.onManage});

  final PairedHostRecord record;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final host = HostRef.paired(record.id, name: record.name);
    final status = active ? ref.watch(hostLinkStatusProvider(host)).value : null;
    final view = status == null ? null : HostStatusView.ofLink(status);
    return Semantics(
      key: ValueKey('remote-paired-${record.id}'),
      selected: active,
      inMutuallyExclusiveGroup: true,
      hint: l10n.pairedHostManage,
      child: SettingsTile(
        icon: hostKindIcon(HostKind.paired),
        tinted: false,
        title: record.name ?? l10n.commonRemoteHost,
        subtitle: record.entry.authority,
        onTap: onTap,
        onLongPress: onManage,
        value: view == null
            ? null
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedStatusDot(tone: view.tone, size: 7),
                  const SizedBox(width: 6),
                  Text(view.label),
                ],
              ),
        trailing: active ? Icon(AppIcons.selected, size: 20, color: scheme.primary) : const SizedBox(width: 20),
        chevron: false,
      ),
    );
  }
}
