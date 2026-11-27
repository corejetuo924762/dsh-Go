/// What the app remembers about one paired computer: where its access entry
/// is, the name the person gave it, and the gateway ticket that keeps it paired
/// for 30 days.
///
/// They live in the encrypted [SecretStore] under keys of their own
/// (`paired.<id>.entry`, `paired.<id>.name`, `paired.<id>.session`, plus an
/// index at `paired.hosts`). A fifth key, `paired.<id>.renewal`, keeps the code
/// that the access link carried (a permanent token or a fresh pairing code) so a
/// later connect can silently re-exchange once the ticket lapses; it is only
/// touched when a new code arrives, so renaming never clears it. Nothing here
/// reads, rewrites or deletes the SSH, forum or workshop keys in the same store.
library;

import 'dart:convert';

import 'package:dsh_client/dsh_client.dart';

import '../secret_store.dart';

/// The stored half of a paired host: identity, entry and display name. The
/// ticket is read separately, only when a link is about to dial.
class PairedHostRecord {
  const PairedHostRecord({required this.id, required this.entry, this.name});

  /// Paired id of [entry]'s authority; never the display name. Renaming keeps
  /// it, which is what keeps one computer one host.
  final String id;
  final DshPairingEntry entry;

  /// The name the person chose; null until they rename it.
  final String? name;

  PairedHostRecord copyWith({String? Function()? name}) =>
      PairedHostRecord(id: id, entry: entry, name: name != null ? name() : this.name);

  /// Identity and entry only: two records of the same computer are equal
  /// whatever the person named them. `connection_state.dart` relies on this
  /// to keep the link across a rename.
  @override
  bool operator ==(Object other) => other is PairedHostRecord && other.id == id && other.entry == entry;

  @override
  int get hashCode => Object.hash(id, entry);

  @override
  String toString() => 'PairedHostRecord($id, ${entry.authority})';
}

/// Reads and writes paired hosts in the shared [SecretStore].
///
/// Every write is atomic per key and the index is written last, so an
/// interrupted save leaves an orphaned key set (harmless, cleaned by [remove])
/// rather than a host that cannot be read.
class PairedHostStore {
  PairedHostStore(this._secrets);

  final SecretStore _secrets;

  /// The id list, in the order hosts were added.
  static const indexKey = 'paired.hosts';

  static String entryKey(String id) => 'paired.$id.entry';

  static String nameKey(String id) => 'paired.$id.name';

  static String sessionKey(String id) => 'paired.$id.session';

  /// The code the access link carried, kept for silent re-exchange later.
  static String renewalKey(String id) => 'paired.$id.renewal';

  /// Every stored host, older additions first. Unreadable records are skipped;
  /// one bad value never hides the rest.
  Future<List<PairedHostRecord>> loadAll() async {
    final ids = await _index();
    final records = <PairedHostRecord>[];
    for (final id in ids) {
      final record = await load(id);
      if (record != null) records.add(record);
    }
    return records;
  }

  Future<PairedHostRecord?> load(String id) async {
    final raw = await _read(entryKey(id));
    if (raw == null) return null;
    final entry = _entryOf(raw);
    if (entry == null) return null;
    return PairedHostRecord(id: id, entry: entry, name: await _read(nameKey(id)));
  }

  /// Adds or replaces [record], keeping its position in the list. Callers
  /// derive the id from the entry (PairedHostsController does), so one computer
  /// is never kept twice under two names.
  Future<void> save(PairedHostRecord record) async {
    await _secrets.write(entryKey(record.id), _entryJson(record.entry));
    final name = record.name?.trim();
    if (name == null || name.isEmpty) {
      await _secrets.delete(nameKey(record.id));
    } else {
      await _secrets.write(nameKey(record.id), name);
    }
    final ids = await _index();
    if (!ids.contains(record.id)) {
      await _secrets.write(indexKey, jsonEncode([...ids, record.id]));
    }
  }

  /// Stores the gateway ticket. Absent or malformed means "no ticket": the
  /// next connect needs a fresh pairing.
  Future<DshRemoteSession?> loadSession(String id) async {
    final raw = await _read(sessionKey(id));
    if (raw == null) return null;
    try {
      final map = jsonDecode(raw);
      if (map is! Map<String, Object?>) return null;
      final session = DshRemoteSession.fromJson(map);
      return session.value.isEmpty || session.authority.isEmpty ? null : session;
    } catch (_) {
      return null;
    }
  }

  Future<void> saveSession(String id, DshRemoteSession session) =>
      _secrets.write(sessionKey(id), jsonEncode(session.toJson()));

  /// The renewal code for [id], or null when none was kept or it is unreadable.
  /// A blank value is "no code": the gateway never mints one.
  Future<String?> loadRenewal(String id) async {
    final raw = await _read(renewalKey(id));
    if (raw == null) return null;
    final code = raw.trim();
    return code.isEmpty ? null : code;
  }

  /// Stores the code an access link carried. Callers only pass a fresh code, so
  /// a rename or a plain save never reaches here and never overwrites it.
  Future<void> saveRenewal(String id, String code) =>
      _secrets.write(renewalKey(id), code.trim());

  /// Drops the renewal code, e.g. after the gateway rejected it once. A refused
  /// delete is reported for the same reason [remove] reports one.
  Future<void> clearRenewal(String id) => _secrets.delete(renewalKey(id));

  /// Drops [id] and its ticket. A refused delete is reported rather than
  /// swallowed: the caller told the person the computer was forgotten, so a
  /// ticket left behind must not be silently claimed gone.
  Future<void> remove(String id) async {
    final failures = <Object>[];
    for (final key in [entryKey(id), nameKey(id), sessionKey(id), renewalKey(id)]) {
      try {
        await _secrets.delete(key);
      } catch (error) {
        failures.add(error);
      }
    }
    final ids = await _index();
    if (ids.contains(id)) {
      final rest = [for (final other in ids) if (other != id) other];
      // An empty index is not a record: drop it, so the last removal leaves
      // nothing of this host family behind.
      if (rest.isEmpty) {
        await _secrets.delete(indexKey);
      } else {
        await _secrets.write(indexKey, jsonEncode(rest));
      }
    }
    if (failures.isNotEmpty) throw failures.first;
  }

  Future<List<String>> _index() async {
    final raw = await _read(indexKey);
    if (raw == null) return const [];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      return [for (final value in list) if (value is String && value.isNotEmpty) value];
    } catch (_) {
      return const [];
    }
  }

  Future<String?> _read(String key) async {
    try {
      return await _secrets.read(key);
    } catch (_) {
      return null;
    }
  }

  static String _entryJson(DshPairingEntry entry) =>
      jsonEncode({'baseUri': entry.baseUri.toString(), 'isTunnel': entry.isTunnel});

  static DshPairingEntry? _entryOf(String raw) {
    try {
      final map = jsonDecode(raw);
      if (map is! Map) return null;
      final baseUri = map['baseUri'];
      if (baseUri is! String) return null;
      final uri = Uri.tryParse(baseUri);
      if (uri == null || uri.host.isEmpty) return null;
      // Restored spellings go through the same canonical form as a fresh
      // parse, so an old record and a new link key one host.
      return DshPairingEntry.canonical(uri, isTunnel: map['isTunnel'] == true);
    } catch (_) {
      return null;
    }
  }
}
