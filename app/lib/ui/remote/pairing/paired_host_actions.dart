// What can be done to a paired computer from where it is listed: rename it
// (the same identity, so the link survives), or forget it (the record and its
// 30-day ticket both go).
//
// None of this asks whether the computer is the right one: pairing already
// named it, and nothing here shows a fingerprint.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../remote/paired/paired_host_store.dart';
import '../../../state/paired_hosts_state.dart';
import '../../common/app_dialog.dart';
import '../../common/app_sheet.dart';
import '../../common/brief_notice.dart';
import '../../common/list_page_row.dart';
import '../../common/sheet_title_bar.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import '../../workspace/text_prompt.dart';

/// The per-computer sheet: 重命名 · 移除.
Future<void> showPairedHostActions(BuildContext context, PairedHostRecord record) {
  final l10n = context.l10n;
  return showAppSheet<void>(
    context,
    isScrollControlled: true,
    builder: (sheet) => SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetTitleBar(record.name ?? record.entry.authority),
          SheetGroup(
            margin: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 12),
            children: [
              ListPageRow(
                icon: AppIcons.rename,
                title: l10n.pairedHostRename,
                chevron: false,
                onTap: () {
                  Navigator.of(sheet).pop();
                  unawaited(renamePairedHost(context, record));
                },
              ),
              ListPageRow(
                icon: AppIcons.delete,
                title: l10n.pairedHostRemove,
                danger: true,
                chevron: false,
                onTap: () {
                  Navigator.of(sheet).pop();
                  unawaited(removePairedHost(context, record));
                },
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

/// Asks for a new name; the computer keeps its identity and its ticket.
Future<void> renamePairedHost(BuildContext context, PairedHostRecord record) async {
  final l10n = context.l10n;
  final container = ProviderScope.containerOf(context, listen: false);
  final name = await showTextPrompt(
    context,
    title: l10n.pairedHostRename,
    initial: record.name ?? '',
    hint: l10n.pairedHostName,
    maxLength: 40,
    validate: (value) => value.isEmpty ? l10n.pairedHostNameRequired : null,
  );
  if (name == null || name.isEmpty || name == record.name) return;
  await container.read(pairedHostsProvider.notifier).rename(record.id, name);
  if (!context.mounted) return;
  ScaffoldMessenger.maybeOf(context)?.showBriefNotice(l10n.pairedHostRenamed(name));
}

/// Confirms, then forgets the computer: the record, its ticket, and its place
/// in the list. Being the active host is not a reason to stop the person.
Future<void> removePairedHost(BuildContext context, PairedHostRecord record) async {
  final l10n = context.l10n;
  final container = ProviderScope.containerOf(context, listen: false);
  final name = record.name ?? record.entry.authority;
  final ok = await showAppDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text(l10n.pairedHostRemoveTitle(name)),
      content: Text(l10n.pairedHostRemoveBody),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.commonCancel)),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: DshColors.of(context).danger,
            foregroundColor: DshColors.of(context).onDanger,
          ),
          onPressed: () => Navigator.pop(dialog, true),
          child: Text(l10n.commonDelete),
        ),
      ],
    ),
  );
  if (ok != true) return;
  await container.read(pairedHostsProvider.notifier).remove(record.id);
  if (!context.mounted) return;
  ScaffoldMessenger.maybeOf(context)?.showBriefNotice(l10n.remoteWorkspaceRemoved(name));
}
