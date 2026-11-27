import 'dart:async';

import 'package:dsh_app/remote/link_status.dart';
import 'package:dsh_app/remote/paired/paired_host_store.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/paired_hosts_state.dart';
import 'package:dsh_client/dsh_client.dart';

/// A [HostLink] a test drives by hand.
///
/// Override [connect] to build the client for one connection attempt;
/// [drop] simulates the connection falling over so a retry reconnects
/// without a real host.
class FakeHostLink implements HostLink {
  HostLinkStatus _status = HostLinkStatus.idle;
  final _statuses = StreamController<HostLinkStatus>.broadcast(sync: true);
  final _clients = StreamController<DshClient>.broadcast(sync: true);
  final _opened = <DshClient>[];
  DshClient? _client;
  bool _closed = false;

  /// Builds the client for one connection attempt.
  Future<DshClient> connect() => throw UnimplementedError('connect');

  /// Every client an attempt produced, in order.
  List<DshClient> get opened => List.unmodifiable(_opened);

  @override
  HostLinkStatus get status => _status;

  @override
  Stream<HostLinkStatus> get statuses => _statuses.stream;

  @override
  Stream<DshClient> get clients => _clients.stream;

  @override
  DshClient? get currentClient => _status.isConnected ? _client : null;

  void _emit(HostLinkStatus next) {
    if (_closed && next.phase != HostLinkPhase.idle) return;
    _status = next;
    if (!_statuses.isClosed) _statuses.add(next);
  }

  @override
  Future<DshClient> open() async {
    if (_closed) throw StateError('link closed');
    final current = _client;
    if (current != null && _status.isConnected) return current;
    _emit(const HostLinkStatus(HostLinkPhase.connecting, step: HostLinkStep.connect));
    try {
      final client = _client = await connect();
      _opened.add(client);
      _emit(const HostLinkStatus(HostLinkPhase.connected, completed: {HostLinkStep.connect, HostLinkStep.login}));
      if (!_clients.isClosed) _clients.add(client);
      // The previous client goes only once the replacement is published.
      if (current != null) unawaited(current.close());
      return client;
    } on HostLinkError catch (error) {
      _emit(HostLinkStatus(HostLinkPhase.failed, error: error));
      rethrow;
    }
  }

  /// The connection fell over for good: [retry] opens a new client and
  /// publishes it on [clients], the way a real link does when it cannot
  /// recover in place.
  void drop() => _emit(
    const HostLinkStatus(
      HostLinkPhase.failed,
      error: HostLinkError(HostLinkErrorKind.unreachable, 'closed', retryable: true),
    ),
  );

  @override
  void kick() {}

  @override
  void retry() => unawaited(open().then((_) {}, onError: (Object _) {}));

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _client = null;
    _emit(HostLinkStatus.idle);
    await _statuses.close();
    await _clients.close();
  }
}

/// The access entry a fake paired host stands for.
DshPairingEntry fakePairedEntry([String authority = '192.168.1.5:3080']) =>
    DshPairingEntry.lan(Uri.parse('http://$authority'));

/// A paired computer already in the (in-memory) list, so
/// `activeConnectionProvider` resolves the host instead of treating it as
/// unknown. Its id comes from [authority], exactly as a real record's does.
class FakePairedHosts extends PairedHostsController {
  FakePairedHosts([String authority = '192.168.1.5:3080'])
    : record = PairedHostRecord(
        id: pairedHostId(fakePairedEntry(authority).authority),
        entry: fakePairedEntry(authority),
        name: '书房',
      );

  final PairedHostRecord record;

  /// The [HostRef] of [record].
  HostRef get host => HostRef.paired(record.id, name: record.name);

  @override
  PairedHostsState build() => PairedHostsState(records: [record], loaded: true);
}