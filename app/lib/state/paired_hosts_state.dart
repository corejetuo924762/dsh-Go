import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../remote/paired/paired_host_store.dart';
import '../remote/secret_store.dart';
import 'hosts_state.dart';
import 'read_list_epoch.dart';

/// Paired computers, as read from the encrypted store, plus the one-shot
/// pairing codes still waiting for their first connect (never persisted: a
/// code is spent the moment it is used).
class PairedHostsState {
  const PairedHostsState({this.records = const [], this.codes = const {}, this.loaded = false});

  final List<PairedHostRecord> records;

  /// Pairing code per host id, until the link spends it.
  final Map<String, String> codes;
  final bool loaded;

  PairedHostRecord? byId(String id) {
    for (final record in records) {
      if (record.id == id) return record;
    }
    return null;
  }
}

/// Where paired records live: the same [SecretStore] SSH, forum and workshop
/// credentials use, under keys of its own.
final pairedHostStoreProvider = Provider<PairedHostStore>(
  (ref) => PairedHostStore(ref.watch(secretStoreProvider)),
);

class PairedHostsController extends Notifier<PairedHostsState> {
  late Future<void> _loaded;
  final _codes = <String, String>{};

  PairedHostStore get _store => ref.read(pairedHostStoreProvider);

  @override
  PairedHostsState build() {
    _loaded = _load();
    return const PairedHostsState();
  }

  /// Completes once the saved records have been read.
  Future<void> get ready => _loaded;

  Future<void> _load() async {
    List<PairedHostRecord> records = const [];
    try {
      records = await _store.loadAll();
    } catch (_) {
      // An unreadable vault keeps the list empty rather than crashing startup.
    }
    _publish(records);
  }

  void _publish(List<PairedHostRecord> records) {
    state = PairedHostsState(records: List.unmodifiable(records), codes: Map.unmodifiable(_codes), loaded: true);
  }

  Future<void> _refresh() async => _publish(await _store.loadAll());

  /// Adds or replaces [record]. [code] is the 8-character code that just
  /// authorised it, held only until its first connect.
  Future<void> save(PairedHostRecord record, {String? code}) async {
    // One computer, one host: the id comes from the entry, never from a name,
    // so a second save of the same address replaces instead of duplicating.
    if (record.id != pairedHostId(record.entry.authority)) {
      throw ArgumentError.value(record.id, 'record', 'id is pairedHostId of the entry authority');
    }
    await _loaded;
    ref.read(readListCredentialEpochProvider.notifier).advance();
    if (code != null && code.isNotEmpty) {
      _codes[record.id] = code;
      // Keep the code on disk too, so a later connect can silently re-exchange
      // once the ticket lapses (a rename or a plain save never reaches here).
      await _store.saveRenewal(record.id, code);
    }
    await _store.save(record);
    await _refresh();
  }

  /// Keeps what a person handed the app — an access link, a bare code on top
  /// of an existing computer, or an address plus a code — as a host that can be
  /// connected. Returns the host, or null when the text is not a pairing input
  /// at all ([DshPairingInput.tryParse] refuses rather than guessing).
  ///
  /// The entry is normalized once here ([DshPairingEntry.canonical]) so the
  /// same computer keyed two ways is one host; the id is always derived from
  /// that entry, never from the name.
  Future<PairedHostRecord?> pair(String input, {String? name}) async {
    final parsed = DshPairingInput.tryParse(input);
    if (parsed == null) return null;
    // A bare code only means something when exactly one computer is already
    // known: it re-authorises that one instead of inventing an address.
    final parsedEntry = parsed.entry;
    final known = parsedEntry == null && state.records.length == 1 ? state.records.single : null;
    if (parsedEntry == null && known == null) return null;
    final entry = DshPairingEntry.canonical(parsedEntry?.baseUri ?? known!.entry.baseUri);
    final id = pairedHostId(entry.authority);
    // Pairing again is not renaming: an existing name survives unless the
    // caller names the computer here.
    final record = PairedHostRecord(id: id, entry: entry, name: name ?? known?.name ?? state.byId(id)?.name);
    await save(record, code: parsed.code);
    return record;
  }

  /// Renaming keeps the same identity, so the link (and its session) survives.
  Future<void> rename(String id, String name) async {
    await _loaded;
    final record = state.byId(id);
    if (record == null) return;
    await save(record.copyWith(name: () => name));
  }

  /// The code for [id], if one is still waiting to be spent.
  String? codeFor(String id) => _codes[id];

  void clearCode(String id) {
    if (_codes.remove(id) == null) return;
    state = PairedHostsState(records: state.records, codes: Map.unmodifiable(_codes), loaded: state.loaded);
  }

  /// Drops the record and its ticket; leaves the active host for 本机. A store
  /// that refused a delete keeps the record visible instead of pretending it
  /// was forgotten.
  Future<void> remove(String id) async {
    await _loaded;
    _codes.remove(id);
    try {
      await _store.remove(id);
    } finally {
      await _refresh();
    }
    unawaited(ref.read(activeHostProvider.notifier).forget((host) => host == HostRef.paired(id)));
  }

  Future<DshRemoteSession?> loadSession(String id) => _store.loadSession(id);

  /// Stores the ticket an exchange just minted.
  Future<void> saveSession(String id, DshRemoteSession session) => _store.saveSession(id, session);

  /// The renewal code kept for [id], or null. Read by a link when its stored
  /// ticket lapses so it can re-exchange without asking the person.
  Future<String?> loadRenewal(String id) => _store.loadRenewal(id);

  /// Drops a renewal code the gateway already rejected, so the phone stops
  /// presenting it and does not burn a rate-limit slot retrying.
  Future<void> clearRenewal(String id) => _store.clearRenewal(id);
}

final pairedHostsProvider = NotifierProvider<PairedHostsController, PairedHostsState>(
  PairedHostsController.new,
);
