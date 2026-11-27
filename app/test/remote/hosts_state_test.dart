// Hosts model: persistence (configs in prefs, secrets in the secret store),
// the active host, relay account flow, and activeConnectionProvider
// resolving to the right connection.

import 'dart:convert';

import 'package:dsh_app/remote/link_status.dart';
import 'package:dsh_app/remote/paired/paired_host_store.dart';
import 'package:dsh_app/remote/paired/paired_link.dart';
import 'package:dsh_app/remote/relay/dsh_remote_backend.dart';
import 'package:dsh_app/remote/relay/relay_backend.dart';
import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/remote/ssh/ssh_link.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/paired_hosts_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_relay.dart';
import 'support/fake_ssh.dart';
import 'support/wait.dart';

class _NoLocal extends LocalConnectionController {
  @override
  Future<HostConnection?> build() async => null;
}

/// Counts builds of the on-device engine connection: a paired host must not
/// open it (it would look like the paired computer while writing locally).
class _CountingLocal extends LocalConnectionController {
  static int builds = 0;

  @override
  Future<HostConnection?> build() async {
    builds++;
    return null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MemorySecretStore secrets;
  late FakeSshServer server;
  late FakeConnector connector;

  ProviderContainer container({FakeRelayBackend? relay, UrlOpener? opener}) {
    final c = ProviderContainer(
      overrides: [
        secretStoreProvider.overrideWithValue(secrets),
        localConnectionProvider.overrideWith(_NoLocal.new),
        networkKicksProvider.overrideWithValue(const Stream.empty()),
        relayBackendProvider.overrideWithValue(relay ?? FakeRelayBackend()),
        urlOpenerProvider.overrideWithValue(opener ?? (_) async => true),
        sshLinkFactoryProvider.overrideWithValue(
          (ref, config) => SshHostLink(
            config: config,
            loadSecrets: () => ref.read(hostsProvider.notifier).loadSecrets(config.id),
            pinHostKey: (key) => ref.read(hostsProvider.notifier).pinHostKey(config.id, key),
            transportFactory: server.connect,
            connectClient: connector.call,
            backoff: Backoff(initial: const Duration(milliseconds: 5), maxAttempts: 2),
          ),
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  Future<void> loaded(ProviderContainer c) async {
    await c.read(hostsProvider.notifier).ready;
    await Future<void>.delayed(Duration.zero);
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    secrets = MemorySecretStore();
    server = FakeSshServer();
    connector = FakeConnector();
    _CountingLocal.builds = 0;
  });

  group('HostRef', () {
    test('round-trips and compares by kind + id', () {
      for (final ref in [
        HostRef.local,
        const HostRef.ssh('ssh-1'),
        const HostRef.relay('mac', name: '家里的 Mac'),
        HostRef.paired(pairedHostId('192.168.1.5:3080'), name: '书房'),
      ]) {
        expect(HostRef.decode(ref.encode()), ref);
      }
      expect(HostRef.decode(const HostRef.relay('mac', name: 'A').encode()).name, 'A');
      expect(const HostRef.relay('mac', name: 'A'), const HostRef.relay('mac', name: 'B'));
      expect(HostRef.decode(null), HostRef.local);
      expect(HostRef.decode('{oops'), HostRef.local);
      expect(HostRef.decode('{"kind":"ssh"}'), HostRef.local);
    });

    test('a paired host keeps its kind through the stored record', () {
      final ref = HostRef.paired(pairedHostId('192.168.1.5:3080'), name: '书房');
      final encoded = jsonDecode(ref.encode()) as Map;
      expect(encoded['kind'], 'paired');
      expect(encoded['id'], pairedHostId('192.168.1.5:3080'));

      final restored = HostRef.decode(ref.encode());
      expect(restored.kind, HostKind.paired);
      expect(restored.id, ref.id);
      expect(restored.name, '书房');
    });

    test('paired host identity comes from the entry address, never the name', () {
      final id = pairedHostId('192.168.1.5:3080');
      expect(id, matches(RegExp(r'^paired-[0-9a-f]{12}$')));
      // Same address, same host — however often it is derived.
      expect(pairedHostId('192.168.1.5:3080'), id);
      // Another address in the same home is another host.
      expect(pairedHostId('192.168.1.5:3081'), isNot(id));
      expect(pairedHostId('nas.example.com'), isNot(id));

      final named = HostRef.paired(id, name: '书房');
      expect(HostRef.paired(id, name: '客厅'), named, reason: '改名不换身份');
      expect(HostRef.paired(id, name: '客厅').name, '客厅');
    });

    test('labels read well in the chat header', () {
      expect(hostLabel(HostKind.local, null), '本机');
      expect(hostLabel(HostKind.ssh, '电脑'), '电脑 · SSH');
      expect(hostLabel(HostKind.relay, '家里的 Mac'), '家里的 Mac · 远程');
      expect(hostLabel(HostKind.paired, '书房'), '书房 · 配对');
      expect(hostLabel(HostKind.paired, null), '远程主机 · 配对');
      expect(hostLabel(HostKind.ssh, '一个名字特别特别特别特别长的服务器'), endsWith('… · SSH'));
    });
  });

  group('SshHostConfig', () {
    test('json round-trip, defaults and validation', () {
      final full = sampleSsh.copyWith(workingDirectory: () => '~/code', launchCommand: '~/.nvm/bin/dsh web');
      expect(SshHostConfig.fromJson(jsonDecode(jsonEncode(full.toJson()))), full);
      final min = SshHostConfig.fromJson({'id': 'ssh-x', 'host': 'h', 'user': 'u', 'port': 99999})!;
      expect(min.port, 22);
      expect(min.name, 'h');
      expect(min.launchCommand, 'dsh web');
      expect(min.auth, SshAuthMethod.password);
      expect(min.dshMode, SshDshMode.managed);
      expect(min.compression, isTrue);
      expect(SshHostConfig.fromJson({'host': 'h'}), isNull);
      expect(SshHostConfig.newId(), matches(RegExp(r'^ssh-[0-9a-f]{16}$')));
    });

    test('attach settings and compression round-trip without secrets', () {
      final config = sampleSsh.copyWith(dshMode: SshDshMode.attachOnly, remotePort: 4080, compression: false);
      expect(SshHostConfig.fromJson(config.toJson()), config);
      expect(config.connectionKey, isNot(sampleSsh.connectionKey));
      expect(sampleSsh.copyWith(compression: false).connectionKey, isNot(sampleSsh.connectionKey));
      expect(config.toJson().containsKey('attachToken'), isFalse);
      expect(SshHostConfig.fromJson({...config.toJson(), 'remotePort': 0}), isNull);
    });

    test('moving to another machine forgets the pinned key; renaming does not', () {
      expect(sampleSsh.copyWith(name: '新名字').hostKeyFingerprint, isNotNull);
      expect(sampleSsh.copyWith(host: '10.0.0.9').hostKeyFingerprint, isNull);
      expect(sampleSsh.copyWith(port: 2222).hostKeyFingerprint, isNull);
      expect(sampleSsh.copyWith(name: 'x').connectionKey, sampleSsh.connectionKey);
      expect(sampleSsh.copyWith(launchCommand: 'dsh --profile w web').connectionKey, isNot(sampleSsh.connectionKey));
    });
  });

  group('HostsController', () {
    test('persists configs to prefs and secrets to the secret store only', () async {
      final c = container();
      await loaded(c);
      await c.read(hostsProvider.notifier).saveSsh(sampleSsh, secrets: const SshSecrets(password: 'hunter2'));

      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(HostsController.prefsKey)!;
      expect(raw, contains('192.168.1.20'));
      expect(raw, isNot(contains('hunter2')));
      expect(secrets.values[SshSecrets.passwordKey(sampleSsh.id)], 'hunter2');

      // A fresh container (app restart) reads the same host back.
      final again = container();
      await loaded(again);
      expect(again.read(hostsProvider).ssh.single, sampleSsh);
      expect((await again.read(hostsProvider.notifier).loadSecrets(sampleSsh.id)).password, 'hunter2');
    });

    test('attach token stays in secure storage and is removed with the host', () async {
      final c = container();
      await loaded(c);
      final hosts = c.read(hostsProvider.notifier);
      final config = sampleSsh.copyWith(dshMode: SshDshMode.attachOnly, remotePort: 4080);
      await hosts.saveSsh(config, secrets: const SshSecrets(password: 'pw', attachToken: 'synthetic-token'));
      final raw = (await SharedPreferences.getInstance()).getString(HostsController.prefsKey)!;
      expect(raw, isNot(contains('synthetic-token')));
      expect((await hosts.loadSecrets(config.id)).attachToken, 'synthetic-token');
      expect(secrets.values[SshSecrets.attachTokenKey(config.id)], 'synthetic-token');
      await hosts.removeSsh(config.id);
      expect(secrets.values, isEmpty);
    });

    test('switching back to managed mode drops the attach token', () async {
      final c = container();
      await loaded(c);
      final hosts = c.read(hostsProvider.notifier);
      await hosts.saveSsh(
        sampleSsh.copyWith(dshMode: SshDshMode.attachOnly),
        secrets: const SshSecrets(password: 'pw', attachToken: 'synthetic-token'),
      );
      await hosts.saveSsh(sampleSsh, secrets: const SshSecrets(password: 'pw'));
      expect((await hosts.loadSecrets(sampleSsh.id)).attachToken, isNull);
    });

    test('switching to key auth drops the stored password', () async {
      final c = container();
      await loaded(c);
      final hosts = c.read(hostsProvider.notifier);
      await hosts.saveSsh(sampleSsh, secrets: const SshSecrets(password: 'pw'));
      await hosts.saveSsh(
        sampleSsh.copyWith(auth: SshAuthMethod.privateKey),
        secrets: const SshSecrets(privateKey: '-----BEGIN KEY-----', passphrase: 'pp'),
      );
      expect(
        secrets.values.keys,
        unorderedEquals([SshSecrets.privateKeyKey(sampleSsh.id), SshSecrets.passphraseKey(sampleSsh.id)]),
      );
    });

    test('a save before the initial load completes keeps what was on disk', () async {
      SharedPreferences.setMockInitialValues({
        HostsController.prefsKey: jsonEncode([sampleSsh.toJson()]),
      });
      final c = container();
      final other = sampleSsh.copyWith(name: '服务器', host: '10.0.0.2');
      final second = SshHostConfig.fromJson({...other.toJson(), 'id': 'ssh-other'})!;
      await c.read(hostsProvider.notifier).saveSsh(second);
      expect(c.read(hostsProvider).ssh.map((h) => h.id), [sampleSsh.id, 'ssh-other']);
    });

    test('pin / reset host key', () async {
      final c = container();
      await loaded(c);
      final hosts = c.read(hostsProvider.notifier);
      await hosts.saveSsh(sampleSsh.copyWith(hostKeyFingerprint: () => null, hostKeyType: () => null));
      await hosts.pinHostKey(sampleSsh.id, const PresentedHostKey('ssh-ed25519', 'SHA256:abc'));
      expect(c.read(hostsProvider).sshById(sampleSsh.id)!.hostKeyFingerprint, 'SHA256:abc');
      await hosts.resetHostKey(sampleSsh.id);
      expect(c.read(hostsProvider).sshById(sampleSsh.id)!.hostKeyFingerprint, isNull);
    });

    test('removing the active host deletes its secrets and falls back to 本机', () async {
      final c = container();
      await loaded(c);
      final hosts = c.read(hostsProvider.notifier);
      await hosts.saveSsh(sampleSsh, secrets: const SshSecrets(password: 'pw'));
      c.read(activeHostProvider.notifier).select(HostRef.ssh(sampleSsh.id));
      await hosts.removeSsh(sampleSsh.id);
      expect(c.read(hostsProvider).ssh, isEmpty);
      expect(secrets.values, isEmpty);
      expect(c.read(activeHostProvider), HostRef.local);
    });
  });

  group('active host', () {
    test('is persisted and switching resets the open conversation', () async {
      final c = container();
      await Future<void>.delayed(Duration.zero);
      c.read(currentSessionProvider.notifier).select('local-session');
      c.read(activeHostProvider.notifier).select(const HostRef.ssh('ssh-test'));
      expect(c.read(currentSessionProvider), isNull);
      await Future<void>.delayed(Duration.zero);
      final prefs = await SharedPreferences.getInstance();
      expect(HostRef.decode(prefs.getString(ActiveHostController.prefsKey)), const HostRef.ssh('ssh-test'));

      final again = container();
      again.read(activeHostProvider);
      await until(again, activeHostProvider, (host) => host == const HostRef.ssh('ssh-test'), what: '已恢复活动主机');
      expect(again.read(activeHostProvider), const HostRef.ssh('ssh-test'));
    });
  });

  group('activeConnectionProvider', () {
    test('本机 → the local connection', () async {
      final c = container();
      final sub = c.listen(activeConnectionProvider, (_, _) {});
      addTearDown(sub.close);
      await until(c, activeConnectionProvider, (s) => !s.isLoading, what: '本机连接状态');
      expect(c.read(activeConnectionProvider).value, isNull);
    });

    test('paired host stays a client: no link yet, and never the on-device engine', () async {
      final c = ProviderContainer(
        overrides: [
          secretStoreProvider.overrideWithValue(secrets),
          localConnectionProvider.overrideWith(_CountingLocal.new),
          networkKicksProvider.overrideWithValue(const Stream.empty()),
          relayBackendProvider.overrideWithValue(FakeRelayBackend()),
        ],
      );
      addTearDown(c.dispose);
      final host = HostRef.paired(pairedHostId('192.168.1.5:3080'), name: '书房');
      c.read(activeHostProvider.notifier).select(host);
      final sub = c.listen(activeConnectionProvider, (_, _) {});
      addTearDown(sub.close);
      final statuses = c.listen(hostLinkStatusProvider(host), (_, _) {});
      addTearDown(statuses.close);

      await until(c, activeConnectionProvider, (s) => !s.isLoading, what: '配对主机连接状态');
      expect(c.read(activeConnectionProvider).value, isNull);
      expect(c.read(activeConnectionProvider).hasError, isFalse);
      expect(_CountingLocal.builds, 0, reason: '配对主机不拉起本机引擎');
      expect(c.read(hostLinkProvider(host)), isNull, reason: '配对链路随接通票落地');
      await until(c, hostLinkStatusProvider(host), (s) => s.value?.phase == HostLinkPhase.idle, what: '配对主机未连接');
      expect(secrets.values, isEmpty, reason: '这一步不写任何凭据');
    });

    test('SSH host → a remote HostConnection with a meaningful label and cwd', () async {
      final c = container();
      await loaded(c);
      await c
          .read(hostsProvider.notifier)
          .saveSsh(
            sampleSsh.copyWith(workingDirectory: () => '~/code'),
            secrets: const SshSecrets(password: 'pw'),
          );
      c.read(activeHostProvider.notifier).select(HostRef.ssh(sampleSsh.id));
      final seen = <AsyncValue<HostConnection?>>[];
      final sub = c.listen(activeConnectionProvider, (_, next) => seen.add(next), fireImmediately: true);
      addTearDown(sub.close);
      final statuses = c.listen(hostLinkStatusProvider(HostRef.ssh(sampleSsh.id)), (_, _) {});
      addTearDown(statuses.close);

      await until(c, activeConnectionProvider, (s) => s.value != null, what: '远程主机连接成功');
      final conn = c.read(activeConnectionProvider).value!;
      expect(conn.isLocal, isFalse);
      expect(conn.kind, HostKind.ssh);
      expect(conn.label, '电脑 · SSH');
      expect(conn.workingDirectory, '/home/me/code');
      expect(seen.first.isLoading, isTrue);
      expect(c.read(hostLinkStatusProvider(HostRef.ssh(sampleSsh.id))).value?.isConnected, isTrue);

      // Switching back to 本机 closes the SSH link (once nothing watches it).
      statuses.close();
      final closed = server.last.done;
      c.read(activeHostProvider.notifier).select(HostRef.local);
      await until(c, activeConnectionProvider, (s) => !s.isLoading && s.value == null, what: '已切回本机');
      await closed.timeout(const Duration(seconds: 5), onTimeout: () => fail('等待超时：旧 SSH 已关闭'));
      expect(c.read(activeConnectionProvider).value, isNull);
      expect(server.last.isClosed, isTrue);
    });

    test('resetting and pinning a changed key recovers the same active link', () async {
      final c = container();
      await loaded(c);
      await c
          .read(hostsProvider.notifier)
          .saveSsh(
            sampleSsh.copyWith(hostKeyFingerprint: () => 'SHA256:old'),
            secrets: const SshSecrets(password: 'pw'),
          );
      final host = HostRef.ssh(sampleSsh.id);
      c.read(activeHostProvider.notifier).select(host);
      final sub = c.listen(activeConnectionProvider, (_, _) {});
      addTearDown(sub.close);
      await until(c, activeConnectionProvider, (s) => s.hasError, what: '指纹不一致');
      final link = c.read(hostLinkProvider(host));
      await c.read(hostsProvider.notifier).resetHostKey(sampleSsh.id);
      await c.read(hostsProvider.notifier).pinHostKey(sampleSsh.id, server.hostKey);
      await until(c, activeConnectionProvider, (s) => s.value != null, what: '新指纹连接成功');
      expect(c.read(hostLinkProvider(host)), same(link));
      expect(c.read(activeConnectionProvider).value?.client, same(link!.currentClient));
    });

    test('cwd changes immediately without reconnecting the transport', () async {
      final c = container();
      await loaded(c);
      await c.read(hostsProvider.notifier).saveSsh(sampleSsh, secrets: const SshSecrets(password: 'pw'));
      final host = HostRef.ssh(sampleSsh.id);
      c.read(activeHostProvider.notifier).select(host);
      final sub = c.listen(activeConnectionProvider, (_, _) {});
      addTearDown(sub.close);
      await until(c, activeConnectionProvider, (s) => s.value != null, what: 'SSH 已连接');
      final client = c.read(activeConnectionProvider).value!.client;
      await c.read(hostsProvider.notifier).saveSsh(sampleSsh.copyWith(workingDirectory: () => '~/new'));
      await until(c, activeConnectionProvider, (s) => s.value?.workingDirectory == '/home/me/new', what: '工作目录已更新');
      expect(server.transports, hasLength(1));
      expect(c.read(activeConnectionProvider).value!.client, same(client));
    });

    test('name and fingerprint changes keep the existing link and transport', () async {
      final c = container();
      await loaded(c);
      await c.read(hostsProvider.notifier).saveSsh(sampleSsh, secrets: const SshSecrets(password: 'pw'));
      final host = HostRef.ssh(sampleSsh.id);
      c.read(activeHostProvider.notifier).select(host);
      final sub = c.listen(activeConnectionProvider, (_, _) {});
      addTearDown(sub.close);
      await until(c, activeConnectionProvider, (s) => s.value != null, what: 'SSH 已连接');
      final link = c.read(hostLinkProvider(host));
      await c
          .read(hostsProvider.notifier)
          .saveSsh(sampleSsh.copyWith(name: '办公室', hostKeyFingerprint: () => 'SHA256:next'));
      await until(c, activeConnectionProvider, (s) => s.value?.label == '办公室 · SSH', what: '主机名已更新');
      expect(c.read(hostLinkProvider(host)), same(link));
      expect(server.transports, hasLength(1));
      expect((link as SshHostLink).config.hostKeyFingerprint, 'SHA256:next');
    });

    test('a failed SSH host surfaces as AsyncError, and retry recovers', () async {
      server.failNext.add(const HostLinkError(HostLinkErrorKind.authFailed, '登录被拒绝'));
      final c = container();
      await loaded(c);
      await c.read(hostsProvider.notifier).saveSsh(sampleSsh, secrets: const SshSecrets(password: 'pw'));
      final host = HostRef.ssh(sampleSsh.id);
      c.read(activeHostProvider.notifier).select(host);
      final sub = c.listen(activeConnectionProvider, (_, _) {});
      addTearDown(sub.close);
      await until(c, activeConnectionProvider, (s) => s.hasError, what: 'SSH 连接失败');
      expect(c.read(activeConnectionProvider).hasError, isTrue);

      c.read(remoteConnectionProvider(host).notifier).retry();
      await until(c, activeConnectionProvider, (s) => s.value != null, what: 'SSH 重试成功');
      expect(c.read(activeConnectionProvider).value?.label, '电脑 · SSH');
    });

    test('an SSH host that no longer exists falls back to 本机', () async {
      final c = container();
      await loaded(c);
      c.read(activeHostProvider.notifier).select(const HostRef.ssh('ssh-gone'));
      final sub = c.listen(activeConnectionProvider, (_, _) {});
      addTearDown(sub.close);
      await until(c, activeConnectionProvider, (s) => !s.isLoading, what: '未知主机回到本机');
      // Same as 本机 (whose fake engine isn't running).
      expect(c.read(activeConnectionProvider), const AsyncData<HostConnection?>(null));
    });

    test('relay host → connects through the backend', () async {
      final relay = FakeRelayBackend(user: sampleRelayUser);
      final c = container(relay: relay);
      await c.read(relayAccountProvider.future);
      c.read(activeHostProvider.notifier).select(const HostRef.relay('mac', name: '家里的 Mac'));
      final sub = c.listen(activeConnectionProvider, (_, _) {});
      addTearDown(sub.close);
      await until(c, activeConnectionProvider, (s) => s.value != null, what: '远程主机连接成功');
      expect(c.read(activeConnectionProvider).value?.label, '家里的 Mac · 远程');
      expect(relay.connected, ['mac']);
    });

    test('offline relay host fails with a clear reason', () async {
      final relay = FakeRelayBackend(user: sampleRelayUser);
      final c = container(relay: relay);
      await c.read(relayAccountProvider.future);
      c.read(activeHostProvider.notifier).select(const HostRef.relay('nas'));
      final sub = c.listen(activeConnectionProvider, (_, _) {});
      addTearDown(sub.close);
      final statuses = c.listen(hostLinkStatusProvider(const HostRef.relay('nas')), (_, _) {});
      addTearDown(statuses.close);
      await until(
        c,
        hostLinkStatusProvider(const HostRef.relay('nas')),
        (s) => s.value?.error?.kind == HostLinkErrorKind.hostOffline,
        what: '主机离线状态',
      );
      final status = c.read(hostLinkStatusProvider(const HostRef.relay('nas'))).value;
      expect(status?.error?.kind, HostLinkErrorKind.hostOffline);
      expect(relay.connected, isEmpty);
    });
  });

  group('relay account', () {
    test('recheck clears a revoked account and its host list', () async {
      final relay = FakeRelayBackend(user: sampleRelayUser);
      final c = container(relay: relay);
      await c.read(relayAccountProvider.future);
      relay.user = null;
      await c.read(relayAccountProvider.notifier).recheck();
      expect(c.read(relayAccountProvider).value!.signedIn, isFalse);
      expect(c.read(relayAccountProvider).value!.hosts, isEmpty);
    });

    test('refresh failure keeps the list, flags it and rechecks the account', () async {
      final relay = FakeRelayBackend(user: sampleRelayUser);
      final c = container(relay: relay);
      await c.read(relayAccountProvider.future);
      relay.listError = StateError('secret server failure');
      await c.read(relayAccountProvider.notifier).refresh();
      expect(c.read(relayAccountProvider).value!.hostsFailed, isTrue);
      expect(c.read(relayAccountProvider).value!.hosts, isNotEmpty);
      expect(c.read(relayAccountProvider).value!.error, isNull);
      relay.user = null;
      await c.read(relayAccountProvider.notifier).refresh();
      expect(c.read(relayAccountProvider).value!.signedIn, isFalse);
    });

    test('initial host-list failure is distinct from an empty account', () async {
      final relay = FakeRelayBackend(user: sampleRelayUser)..listError = StateError('raw');
      final c = container(relay: relay);
      final account = await c.read(relayAccountProvider.future);
      expect(account.signedIn, isTrue);
      expect(account.hostsFailed, isTrue);
      expect(account.hosts, isEmpty);
    });

    test('unavailable backend: not signed in, login disabled', () async {
      final c = ProviderContainer(
        overrides: [
          secretStoreProvider.overrideWithValue(secrets),
          relayBackendProvider.overrideWithValue(const UnavailableRelayBackend()),
        ],
      );
      addTearDown(c.dispose);
      final state = await c.read(relayAccountProvider.future);
      expect(state.available, isFalse);
      expect(state.signedIn, isFalse);
    });

    test('default backend is dsh_remote: available, signed out with an empty store', () async {
      final c = ProviderContainer(overrides: [secretStoreProvider.overrideWithValue(secrets)]);
      addTearDown(c.dispose);
      expect(c.read(relayBackendProvider), isA<DshRemoteRelayBackend>());
      final state = await c.read(relayAccountProvider.future);
      expect(state.available, isTrue);
      expect(state.server, 'dsh.r2049.cn');
      expect(state.signedIn, isFalse);
    });

    test('a signed-out state carries the Server sign-in providers', () async {
      final c = container(relay: FakeRelayBackend());
      final state = await c.read(relayAccountProvider.future);
      expect(state.providers.map((p) => p.id), ['zhihu', 'github', 'google']);
      expect(state.providers.first.displayName, '知乎');
    });

    test('login(providerId) signs in with that provider', () async {
      final relay = FakeRelayBackend();
      final opened = <Uri>[];
      final c = container(
        relay: relay,
        opener: (u) async {
          opened.add(u);
          return true;
        },
      );
      await c.read(relayAccountProvider.future);
      final login = c.read(relayAccountProvider.notifier).login(providerId: 'github');
      await until(c, relayAccountProvider, (s) => s.value?.loginUrl != null, what: 'GitHub 登录已打开');
      expect(relay.loginProviderIds, ['github']);
      expect(opened.single.host, 'dsh.r2049.cn');
      relay.pendingLogin!.complete(sampleRelayUser);
      await login;
      expect(c.read(relayAccountProvider).value!.user!.provider, 'github');
    });

    test('browser login: opens the URL, waits, then lists hosts', () async {
      final relay = FakeRelayBackend();
      final opened = <Uri>[];
      final c2 = container(
        relay: relay,
        opener: (u) async {
          opened.add(u);
          return true;
        },
      );
      await c2.read(relayAccountProvider.future);
      final login = c2.read(relayAccountProvider.notifier).login();
      await until(c2, relayAccountProvider, (s) => s.value?.loginUrl != null, what: '浏览器登录已打开');
      expect(c2.read(relayAccountProvider).value!.loggingIn, isTrue);
      expect(opened.single.host, 'dsh.r2049.cn');
      relay.pendingLogin!.complete(sampleRelayUser);
      await login;
      final state = c2.read(relayAccountProvider).value!;
      expect(state.signedIn, isTrue);
      expect(state.loggingIn, isFalse);
      expect(state.hosts.map((h) => h.name), ['家里的 Mac', '书房 NAS']);
    });

    test('logout while a relay host is active switches back to 本机', () async {
      final c = container(relay: FakeRelayBackend(user: sampleRelayUser));
      await c.read(relayAccountProvider.future);
      c.read(activeHostProvider.notifier).select(const HostRef.relay('mac'));
      await c.read(relayAccountProvider.notifier).logout();
      expect(c.read(activeHostProvider), HostRef.local);
      expect(c.read(relayAccountProvider).value!.signedIn, isFalse);
    });
  });

  test('RelayHost subtitle', () {
    expect(sampleRelayHosts.first.subtitle, 'macOS · Harness 0.2.1-rc.2');
    expect(const RelayHost(id: 'x', name: 'x', online: false).subtitle, '离线');
  });

  test('status summaries', () {
    expect(const HostLinkStatus(HostLinkPhase.reconnecting, attempt: 3).summary, contains('第 3 次'));
    expect(HostLinkStatus.idle.summary, '未连接');
    expect(const HostLinkStatus(HostLinkPhase.connecting).withStep(HostLinkStep.tunnel).completed, {
      HostLinkStep.connect,
      HostLinkStep.verifyHostKey,
      HostLinkStep.startDsh,
    });
  });

  group('paired host', () {
    DshPairingEntry entry() => DshPairingInput.tryParse('http://192.168.1.5:3088/?auth=ABCD2345')!.entry!;

    ProviderContainer pairedContainer() {
      final c = ProviderContainer(
        overrides: [
          secretStoreProvider.overrideWithValue(secrets),
          localConnectionProvider.overrideWith(_CountingLocal.new),
          networkKicksProvider.overrideWithValue(const Stream.empty()),
          relayBackendProvider.overrideWithValue(FakeRelayBackend()),
          // The link seam: dial a stand-in client instead of a real gateway.
          pairedLinkFactoryProvider.overrideWithValue(
            (ref, record) => PairedHostLink(
              entry: record.entry,
              loadSession: () async => null,
              saveSession: (_) async {},
              // No HTTP at all: this suite tests the host model, not the
              // gateway protocol (test/remote/paired_link_test.dart does).
              sessionFactory: _OpenPairing.new,
              connectClient: ({required entry, required session}) async =>
                  DshClient.withCarrier(_IdleCarrier()),
              kicks: const Stream.empty(),
            ),
          ),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('a saved record gives the paired host a live connection and its name', () async {
      final c = pairedContainer();
      await c.read(pairedHostsProvider.notifier).ready;
      final e = entry();
      final id = pairedHostId(e.authority);
      await c.read(pairedHostsProvider.notifier).save(PairedHostRecord(id: id, entry: e, name: '书房'));

      final host = HostRef.paired(id);
      c.read(activeHostProvider.notifier).select(host);
      final sub = c.listen(activeConnectionProvider, (_, _) {});
      addTearDown(sub.close);
      final statuses = c.listen(hostLinkStatusProvider(host), (_, _) {});
      addTearDown(statuses.close);

      await until(c, activeConnectionProvider, (s) => s.value != null, what: '配对主机连上');
      final conn = c.read(activeConnectionProvider).value!;
      expect(conn.kind, HostKind.paired);
      expect(conn.isLocal, isFalse);
      expect(conn.hostId, id, reason: 'the read-list identity keys on this id');
      expect(conn.label, hostLabel(HostKind.paired, '书房'));
      expect(c.read(hostNameProvider(host)), '书房');
      expect(_CountingLocal.builds, 0, reason: '配对主机绝不拉起本机引擎');

      // Renaming is a name change, not a new host, and the link stays.
      await c.read(pairedHostsProvider.notifier).rename(id, '客厅');
      await until(
        c,
        activeConnectionProvider,
        (s) => s.value?.label == hostLabel(HostKind.paired, '客厅'),
        what: '改名跟上',
      );
      expect(c.read(activeHostProvider), host, reason: '改名不换身份');
      expect(c.read(hostLinkProvider(host)), isNotNull);
    });

    test('a pasted link becomes one host, however its address is written', () async {
      final c = pairedContainer();
      await c.read(pairedHostsProvider.notifier).ready;
      final records = c.read(pairedHostsProvider.notifier);

      final first = await records.pair('http://192.168.1.5:3088/?auth=ABCD2345', name: '书房');
      expect(first, isNotNull);
      expect(first!.entry.baseUri.toString(), 'http://192.168.1.5:3088');
      expect(first.id, pairedHostId('192.168.1.5:3088'));
      expect(records.codeFor(first.id), 'ABCD2345', reason: '首次连接要用的码还在');

      // The same computer written another way replaces, never duplicates.
      final again = await records.pair('192.168.1.5:3088 ABCD2345');
      expect(again!.id, first.id);
      expect(c.read(pairedHostsProvider).records, hasLength(1));

      // A bare code re-authorises the one known computer.
      records.clearCode(first.id);
      final recoded = await records.pair('WXYZ6789');
      expect(recoded!.id, first.id);
      expect(recoded.name, '书房', reason: '重配对不改名字');
      expect(records.codeFor(first.id), 'WXYZ6789');

      // Not a pairing input at all: nothing is invented.
      expect(await records.pair('随便说点什么'), isNull);
      expect(c.read(pairedHostsProvider).records, hasLength(1));
    });

    test('a bare code with no known computer pairs nothing', () async {
      final c = pairedContainer();
      await c.read(pairedHostsProvider.notifier).ready;
      expect(await c.read(pairedHostsProvider.notifier).pair('WXYZ6789'), isNull);
      expect(c.read(pairedHostsProvider).records, isEmpty);
    });

    test('removing the paired host leaves 本机 and drops its secrets', () async {
      final c = pairedContainer();
      await c.read(pairedHostsProvider.notifier).ready;
      final e = entry();
      final id = pairedHostId(e.authority);
      await c.read(pairedHostsProvider.notifier).save(PairedHostRecord(id: id, entry: e, name: '书房'));
      final host = HostRef.paired(id);
      c.read(activeHostProvider.notifier).select(host);
      final sub = c.listen(activeConnectionProvider, (_, _) {});
      addTearDown(sub.close);
      final statuses = c.listen(hostLinkStatusProvider(host), (_, _) {});
      addTearDown(statuses.close);
      await until(c, activeConnectionProvider, (s) => s.value != null, what: '配对主机连上');

      await c.read(pairedHostsProvider.notifier).remove(id);

      expect(c.read(pairedHostsProvider).records, isEmpty);
      expect(secrets.values, isEmpty, reason: '配对凭据随记录一并抹去');
      await until(c, activeConnectionProvider, (s) => !s.isLoading && s.value == null, what: '已回到本机');
      expect(c.read(activeHostProvider), HostRef.local);
    });
  });
}

/// An entry that needs no ticket: the host model tests never touch the wire.
class _OpenPairing extends DshPairingSession {
  _OpenPairing(super.entry);

  @override
  Future<DshPairingOutcome> connect({String? code}) async => DshPairingConnected(entry: entry);
}

/// A client that never dials: only its identity matters here.
class _IdleCarrier extends DshCarrier {
  @override
  String get kind => 'idle';

  @override
  DshTracer? get tracer => null;

  @override
  bool allowsEndpoint(String endpoint) => true;

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) =>
      throw UnsupportedError(endpoint);

  @override
  Future<DshMuxLink> openLink(MuxOptions options) => throw UnsupportedError('no streams');

  @override
  Future<void> close() async {}
}
