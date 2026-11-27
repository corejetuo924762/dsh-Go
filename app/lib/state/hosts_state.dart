import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/l10n.dart';
import '../remote/secret_store.dart';
import '../remote/ssh/ssh_host_config.dart';
import '../remote/ssh/ssh_transport.dart';
import 'sessions_state.dart';
import 'read_list_epoch.dart';

export '../remote/link_status.dart' show HostLinkStatus, HostLinkPhase, HostLinkStep, HostLinkError, HostLinkErrorKind;
export '../remote/ssh/ssh_transport.dart' show PresentedHostKey;
export '../remote/ssh/ssh_host_config.dart';

/// The kinds of DSH host the app can talk to: the on-device engine, a saved
/// SSH host, or a computer paired from its access link.
enum HostKind { local, ssh, paired }

/// Identifies a host: the on-device engine, a saved SSH host, or a paired
/// computer. Equality is by kind + id; [name] is only a display name (paired
/// hosts keep the one the person chose).
class HostRef {
  const HostRef._(this.kind, this.id, [this.name]);

  static const local = HostRef._(HostKind.local, 'local');

  const HostRef.ssh(String id) : this._(HostKind.ssh, id);

  /// [id] is [pairedHostId] of the entry address, never the display [name].
  const HostRef.paired(String id, {String? name}) : this._(HostKind.paired, id, name);

  final HostKind kind;
  final String id;
  final String? name;

  bool get isLocal => kind == HostKind.local;

  String encode() => jsonEncode({'kind': kind.name, 'id': id, if (name != null) 'name': name});

  static HostRef decode(String? raw) {
    if (raw == null || raw.isEmpty) return local;
    try {
      final map = jsonDecode(raw);
      if (map is! Map) return local;
      final id = map['id'];
      final name = map['name'];
      if (id is! String || id.isEmpty) return local;
      return switch (map['kind']) {
        'ssh' => HostRef.ssh(id),
        'paired' => HostRef.paired(id, name: name is String ? name : null),
        // A saved "relay" host has no home any more: fall back to 本机
        // (its orphaned relay credentials are purged on start, below).
        _ => local,
      };
    } catch (_) {
      return local;
    }
  }

  @override
  bool operator ==(Object other) => other is HostRef && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);

  @override
  String toString() => 'HostRef(${kind.name}:$id)';
}

/// Chat-header label for a connection: "本机", "电脑 · SSH", "书房 · 配对".
String hostLabel(HostKind kind, String? name) => switch (kind) {
  HostKind.local => appL10n.commonThisPhone,
  HostKind.ssh => '${_short(name ?? appL10n.stateSshHost)} · SSH',
  HostKind.paired => appL10n.stateHostPairedLabel(_short(name ?? appL10n.commonRemoteHost)),
};

/// Stable identity of a paired computer, derived from the entry address its
/// access link parsed to (`host:port`, tunnel host included). The name the
/// person gives it is not part of the identity: renaming keeps the same host.
String pairedHostId(String authority) =>
    'paired-${sha1.convert(utf8.encode(authority)).toString().substring(0, 12)}';

String _short(String name) {
  final t = name.trim();
  return t.length <= 14 ? t : '${t.substring(0, 13)}…';
}

// ── Secrets ──────────────────────────────────────────────────────────────────

/// Keystore-backed in the app; tests override with [MemorySecretStore].
final secretStoreProvider = Provider<SecretStore>((ref) => SecureSecretStore());

// ── Saved SSH hosts ──────────────────────────────────────────────────────────

class HostsState {
  const HostsState({this.ssh = const [], this.loaded = false});

  final List<SshHostConfig> ssh;
  final bool loaded;

  SshHostConfig? sshById(String id) {
    for (final h in ssh) {
      if (h.id == id) return h;
    }
    return null;
  }
}

/// Saved SSH hosts: configs in SharedPreferences, secrets in [SecretStore].
class HostsController extends Notifier<HostsState> {
  static const prefsKey = 'remote_ssh_hosts';

  SecretStore get _secrets => ref.read(secretStoreProvider);
  late Future<void> _loaded;

  @override
  HostsState build() {
    _loaded = _load();
    return const HostsState();
  }

  /// Completes once the saved list has been read (writes wait for it, so an
  /// early save can't clobber what's on disk).
  Future<void> get ready => _loaded;

  Future<void> _load() async {
    var hosts = const <SshHostConfig>[];
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(prefsKey);
      if (raw != null) {
        final list = jsonDecode(raw);
        if (list is List) hosts = list.map(SshHostConfig.fromJson).whereType<SshHostConfig>().toList();
      }
    } catch (_) {
      // No preferences backend (tests) or a corrupt entry: start empty.
    }
    await _purgeRelaySecrets();
    // The purge awaits secure storage; a provider disposed meanwhile (tests
    // tearing down, a rebuild) must not have its state written.
    if (!ref.mounted) return;
    state = HostsState(ssh: hosts, loaded: true);
  }

  /// Drops the encrypted credentials DSH Remote kept (`dsh_remote.v1.*`): with
  /// the relay gone they can never be used again. SSH, forum and workshop keys
  /// in the same store are left untouched.
  Future<void> _purgeRelaySecrets() async {
    final store = _secrets;
    if (store is! SecureSecretStore) return;
    try {
      await store.purgeKeysWithPrefix('dsh_remote.v1.');
    } catch (_) {
      // No usable secure storage: nothing to purge.
    }
  }

  Future<bool> _persist(List<SshHostConfig> hosts) async {
    state = HostsState(ssh: List.unmodifiable(hosts), loaded: true);
    try {
      final prefs = await SharedPreferences.getInstance();
      return await prefs.setString(prefsKey, jsonEncode([for (final h in hosts) h.toJson()]));
    } catch (_) {
      return false;
    }
  }

  /// Adds or replaces [config]. With [secrets], stores the one matching the
  /// auth method and deletes the other kind, so a host never keeps a stale
  /// password next to its key.
  /// Returns the preferences write result. A false result does not undo the
  /// in-memory config or any completed secret operations.
  Future<bool> saveSsh(SshHostConfig config, {SshSecrets? secrets}) async {
    await _loaded;
    ref.read(readListCredentialEpochProvider.notifier).advance();
    if (secrets != null) await _writeSecrets(config, secrets);
    final hosts = [...state.ssh];
    final index = hosts.indexWhere((h) => h.id == config.id);
    if (index >= 0) {
      hosts[index] = config;
    } else {
      hosts.add(config);
    }
    return _persist(hosts);
  }

  Future<void> _writeSecrets(SshHostConfig config, SshSecrets secrets) async {
    final id = config.id;
    Future<void> put(String key, String? value) async {
      if (value == null || value.isEmpty) {
        await _secrets.delete(key);
      } else {
        await _secrets.write(key, value);
      }
    }

    if (config.auth == SshAuthMethod.password) {
      await put(SshSecrets.passwordKey(id), secrets.password);
      await _secrets.delete(SshSecrets.privateKeyKey(id));
      await _secrets.delete(SshSecrets.passphraseKey(id));
    } else {
      await put(SshSecrets.privateKeyKey(id), secrets.privateKey?.trim());
      await put(SshSecrets.passphraseKey(id), secrets.passphrase);
      await _secrets.delete(SshSecrets.passwordKey(id));
    }
    // A failure writing the credential the person just entered must be
    // reported as that failure, not hidden behind unrelated token cleanup.
    await put(
      SshSecrets.attachTokenKey(id),
      config.dshMode == SshDshMode.attachOnly ? secrets.attachToken?.trim() : null,
    );
  }

  Future<SshSecrets> loadSecrets(String id) async {
    Future<String?> get(String key) async {
      try {
        return await _secrets.read(key);
      } catch (_) {
        return null;
      }
    }

    return SshSecrets(
      password: await get(SshSecrets.passwordKey(id)),
      privateKey: await get(SshSecrets.privateKeyKey(id)),
      passphrase: await get(SshSecrets.passphraseKey(id)),
      attachToken: await get(SshSecrets.attachTokenKey(id)),
    );
  }

  /// Removes the host and its secrets; switches back to 本机 if it was active.
  Future<void> removeSsh(String id) async {
    await _loaded;
    await _persist([...state.ssh.where((h) => h.id != id)]);
    for (final key in [
      SshSecrets.passwordKey(id),
      SshSecrets.privateKeyKey(id),
      SshSecrets.passphraseKey(id),
      SshSecrets.attachTokenKey(id),
    ]) {
      try {
        await _secrets.delete(key);
      } catch (_) {}
    }
    unawaited(ref.read(activeHostProvider.notifier).forget((h) => h == HostRef.ssh(id)));
  }

  /// Trust on first use: remembers the key the person accepted.
  Future<void> pinHostKey(String id, PresentedHostKey key) async {
    final host = state.sshById(id);
    if (host == null) return;
    await saveSsh(host.copyWith(hostKeyType: () => key.type, hostKeyFingerprint: () => key.fingerprint));
  }

  /// Forgets the pinned key (after the person confirmed the machine changed).
  Future<void> resetHostKey(String id) async {
    final host = state.sshById(id);
    if (host == null) return;
    await saveSsh(host.copyWith(hostKeyType: () => null, hostKeyFingerprint: () => null));
  }
}

final hostsProvider = NotifierProvider<HostsController, HostsState>(HostsController.new);

// ── Active host ──────────────────────────────────────────────────────────────

/// Whether a cold start restores the last host. Manual connects and their
/// short-network-outage recovery are independent of this preference.
class RemoteAutoConnectController extends Notifier<bool> {
  static const prefsKey = 'remote_auto_connect_on_startup';
  late Future<void> _loaded;

  @override
  bool build() {
    _loaded = _load();
    return true;
  }

  Future<void> _load() async {
    try {
      final stored = (await SharedPreferences.getInstance()).getBool(prefsKey);
      if (stored != null && ref.mounted) state = stored;
    } catch (_) {}
  }

  Future<void> set(bool value) async {
    await _loaded;
    if (!ref.mounted) return;
    state = value;
    try {
      await (await SharedPreferences.getInstance()).setBool(prefsKey, value);
    } catch (_) {}
  }
}

final remoteAutoConnectProvider = NotifierProvider<RemoteAutoConnectController, bool>(RemoteAutoConnectController.new);

/// Which host the chat, session list and new chats use. Persisted.
class ActiveHostController extends Notifier<HostRef> {
  static const prefsKey = 'active_host';
  bool _touched = false;
  late Future<void> _loaded;

  @override
  HostRef build() {
    // Read the startup preference now, so the remote hosts page shows the
    // stored value from its first frame.
    ref.read(remoteAutoConnectProvider);
    _loaded = _restore();
    return HostRef.local;
  }

  /// The startup host choice has settled, including a disabled auto-connect
  /// preference or an earlier explicit selection.
  Future<void> get ready => _loaded;

  Future<void> _restore() async {
    final owner = ref;
    try {
      final prefs = await SharedPreferences.getInstance();
      final restored = HostRef.decode(prefs.getString(prefsKey));
      final autoConnect = prefs.getBool(RemoteAutoConnectController.prefsKey) ?? true;
      if (!_touched && owner.mounted && autoConnect) state = restored;
    } catch (_) {
      // No preferences backend (tests): stay on 本机.
    }
  }

  /// Switches hosts. The open conversation belongs to the old host, so the
  /// chat goes back to "新对话".
  void select(HostRef host) {
    _touched = true;
    if (host == state && host.name == state.name) return;
    final changed = host != state;
    state = host;
    if (changed) ref.read(currentSessionProvider.notifier).select(null);
    unawaited(
      SharedPreferences.getInstance()
          .then((prefs) => prefs.setString(prefsKey, host.encode()))
          .catchError((_) => false),
    );
  }

  /// Hosts matching [gone] no longer exist (a deleted SSH host, a removed
  /// paired computer): leave one in use for 本机, and drop one only saved for
  /// the next launch (with 连接上次使用的主机 off, this launch never used it).
  Future<void> forget(bool Function(HostRef host) gone) async {
    if (gone(state)) {
      select(HostRef.local);
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      if (gone(HostRef.decode(prefs.getString(prefsKey)))) await prefs.setString(prefsKey, HostRef.local.encode());
    } catch (_) {}
  }
}

final activeHostProvider = NotifierProvider<ActiveHostController, HostRef>(ActiveHostController.new);
