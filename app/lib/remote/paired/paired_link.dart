import 'dart:async';

import 'package:dsh_client/dsh_client.dart';

import '../../l10n/l10n.dart';
import '../link_status.dart';

/// Builds the pairing client for one entry; tests swap in fakes.
typedef PairedSessionFactory = DshPairingSession Function(DshPairingEntry entry);

/// Opens the `dsh web` behind the gateway once a ticket is in hand.
typedef PairedClientConnector = Future<DshClient> Function({
  required DshPairingEntry entry,
  required DshRemoteSession? session,
});

Future<DshClient> _defaultConnectClient({required DshPairingEntry entry, required DshRemoteSession? session}) =>
    DshClient.connect(
      baseUri: entry.baseUri,
      remoteSession: session,
      // A tunnel leg is cross-site without its own Origin; a LAN leg must not
      // send one at all.
      originHeader: entry.originHeader,
    );

/// A paired computer: the access entry the person paired with, its 30-day
/// gateway ticket, and the `dsh web` client behind it.
///
/// No account, no relay, no SSH: the phone dials the entry straight over HTTP
/// and WebSocket. The gateway ticket is re-minted on every successful exchange,
/// so a link that keeps working never needs the person to pair again; when the
/// entry stops accepting the stored ticket the link reports "需要重新配对"
/// instead of pretending the network is down.
class PairedHostLink implements HostLink {
  PairedHostLink({
    required this.entry,
    required this.loadSession,
    required this.saveSession,
    this.code,
    this.onCodeUsed,
    this.loadRenewal,
    this.clearRenewal,
    PairedSessionFactory? sessionFactory,
    PairedClientConnector? connectClient,
    Stream<void>? kicks,
    Backoff? backoff,
  }) : _sessionFactory = sessionFactory ?? ((entry) => DshPairingSession(entry)),
       _connectClient = connectClient ?? _defaultConnectClient,
       _backoff = backoff ?? Backoff() {
    _kickSub = kicks?.listen((_) => kick());
  }

  final DshPairingEntry entry;

  /// The stored ticket, read fresh on every attempt.
  final Future<DshRemoteSession?> Function() loadSession;

  /// Writes the ticket the exchange just minted (renewing the 30 days).
  final Future<void> Function(DshRemoteSession session) saveSession;

  /// The 8-character code, when the person just typed or scanned one. The
  /// gateway accepts it once; from then on the minted ticket carries the link.
  String? code;

  /// Called the first time [code] is spent, so the caller can drop it.
  final void Function()? onCodeUsed;

  /// The code the access link carried (permanent token or a fresh pairing
  /// code), read fresh on every attempt. When the stored ticket and any typed
  /// code stop working, the link silently re-exchanges with this so the person
  /// stays paired for as long as the code keeps minting (a permanent token
  /// mints forever, rolling the 30 days forward on every connect).
  final Future<String?> Function()? loadRenewal;

  /// Drops [loadRenewal]'s code after the gateway rejected it, so a dead token
  /// is not presented again (which would only burn a rate-limit slot).
  final Future<void> Function()? clearRenewal;


  final PairedSessionFactory _sessionFactory;
  final PairedClientConnector _connectClient;
  final Backoff _backoff;

  final _statuses = StreamController<HostLinkStatus>.broadcast(sync: true);
  final _clients = StreamController<DshClient>.broadcast();
  final _delay = InterruptibleDelay();
  StreamSubscription<void>? _kickSub;
  StreamSubscription<DshConnectionState>? _muxSub;
  HostLinkStatus _status = HostLinkStatus.idle;
  DshPairingSession? _pairing;
  DshClient? _client;
  Future<DshClient>? _opening;
  bool _closed = false;
  bool _recovering = false;
  bool _published = false;

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
    _statuses.add(next);
  }

  @override
  Future<DshClient> open() {
    if (_closed) return Future.error(StateError('link closed'));
    final client = _client;
    if (client != null && _status.isConnected) return Future.value(client);
    return _opening ??= _openFirst().whenComplete(() => _opening = null);
  }

  Future<DshClient> _openFirst() async {
    _backoff.reset();
    _emit(HostLinkStatus(HostLinkPhase.connecting, step: HostLinkStep.connect, detail: entry.authority));
    try {
      return await _connectOnce();
    } on HostLinkError catch (e) {
      if (!e.retryable) {
        _fail(e);
        rethrow;
      }
      return _recover(e);
    } catch (_) {
      final error = HostLinkError(HostLinkErrorKind.other, appL10n.commonConnectionFailed, retryable: true);
      _fail(error);
      throw error;
    }
  }

  void _fail(HostLinkError error) {
    _emit(HostLinkStatus(HostLinkPhase.failed, step: _status.step, completed: _status.completed, error: error));
  }

  void _checkOpen() {
    if (_closed) throw StateError('link closed');
  }

  /// One attempt: probe → (re)exchange when needed → open the WebSocket.
  Future<DshClient> _connectOnce() async {
    var step = _status.withStep(HostLinkStep.connect, detail: entry.authority);
    void at(HostLinkStep next, {String? detail}) {
      step = step.withStep(next, detail: detail);
      _emit(step);
    }

    final pairing = _pairing ??= _sessionFactory(entry);
    // The ticket on disk is this attempt's starting point; a fresh code (from
    // the person) and an expired one are both settled by the exchange.
    pairing.session = await loadSession();
    _checkOpen();

    final typed = code;
    var outcome = await _exchange(pairing, typed);
    _checkOpen();
    if (typed != null && code != null) {
      // A code is single-use: whether it minted or was refused, it is spent.
      code = null;
      onCodeUsed?.call();
    }

    // Both the stored ticket and any typed code failed to authorise. If the
    // original access link carried a renewal code (a permanent token, or a
    // still-fresh pairing code), exchange with it once — silently, so a lapsed
    // ticket, or a computer whose access entry was reset, re-pairs itself and
    // the person notices nothing. A single-use code past its 5 minutes fails
    // here too, and then the phone really does need a whole new pairing.
    if ((outcome is DshPairingNeedsCode || outcome is DshPairingCodeRejected) && loadRenewal != null) {
      final renewal = await loadRenewal!();
      _checkOpen();
      if (renewal != null && renewal.isNotEmpty) {
        outcome = await _exchange(pairing, renewal);
        _checkOpen();
        if (outcome is DshPairingCodeRejected) {
          // The renewal code itself is dead: the computer's identity changed
          // (its access token was rotated, or it was reset). Drop it so it is
          // not presented again, and say the computer must be re-paired — this
          // is a credential problem, never "the network is down".
          await clearRenewal?.call();
          throw HostLinkError(
            HostLinkErrorKind.authFailed,
            appL10n.pairedErrIdentityChanged,
            retryable: false,
            diagnosticCode: HostLinkDiagnosticCode.pairedTicketRejected,
          );
        }
      }
    }
    switch (outcome) {
      case DshPairingConnected(session: final minted):
        if (minted != null) {
          // A re-mint (or the first mint) rolls the 30 days forward.
          await saveSession(minted);
        }
      case DshPairingBanned(:final remaining):
        throw HostLinkError(
          HostLinkErrorKind.unreachable,
          appL10n.pairedErrBanned(remaining.inSeconds),
          retryable: false,
          diagnosticCode: HostLinkDiagnosticCode.pairedBanned,
          banRemaining: remaining,
        );
      case DshPairingNeedsCode() || DshPairingCodeRejected():
        throw HostLinkError(
          HostLinkErrorKind.authFailed,
          appL10n.pairedErrNeedsRepair,
          retryable: false,
          diagnosticCode: HostLinkDiagnosticCode.pairedTicketRejected,
        );
      case DshPairingComputerFailed(:final message):
        throw HostLinkError(
          HostLinkErrorKind.other,
          appL10n.pairedErrComputer,
          detail: message,
          diagnosticCode: HostLinkDiagnosticCode.pairedComputerFailed,
        );
      case DshPairingRefused(:final statusCode, :final message):
        throw HostLinkError(
          HostLinkErrorKind.other,
          appL10n.pairedErrEntryRefused(statusCode),
          detail: message,
          diagnosticCode: HostLinkDiagnosticCode.pairedGatewayRefused,
        );
    }
    _checkOpen();

    at(HostLinkStep.login, detail: entry.authority);
    final previous = _client;
    _client = null;
    if (previous != null) unawaited(previous.close().catchError((_) {}));
    final DshClient client;
    try {
      client = await _connectClient(entry: entry, session: pairing.session);
    } on DshHttpException catch (e) {
      throw HostLinkError(
        HostLinkErrorKind.other,
        appL10n.pairedErrComputer,
        detail: '$e',
        diagnosticCode: HostLinkDiagnosticCode.pairedComputerFailed,
      );
    } on DshException catch (e) {
      throw HostLinkError(
        HostLinkErrorKind.unreachable,
        appL10n.remoteErrHostUnreachable,
        detail: '$e',
        retryable: true,
        diagnosticCode: HostLinkDiagnosticCode.pairedUnreachable,
      );
    }
    if (_closed) {
      await client.close().catchError((_) {});
      throw StateError('link closed');
    }
    _client = client;
    _watchMux(client);
    _emit(
      HostLinkStatus(HostLinkPhase.connected, completed: HostLinkStep.values.toSet(), detail: entry.authority),
    );
    if (_published) _clients.add(client);
    _published = true;
    return client;
  }

  /// One connect through the pairing session, with transport/protocol failures
  /// mapped to the same HostLinkError kinds the rest of the link reports.
  Future<DshPairingOutcome> _exchange(DshPairingSession pairing, String? code) async {
    try {
      return await pairing.connect(code: code);
    } on DshTransportException catch (e) {
      throw HostLinkError(
        HostLinkErrorKind.unreachable,
        appL10n.remoteErrHostUnreachable,
        detail: '$e',
        retryable: true,
        diagnosticCode: HostLinkDiagnosticCode.pairedUnreachable,
      );
    } on DshProtocolException catch (e) {
      throw HostLinkError(
        HostLinkErrorKind.other,
        appL10n.remoteErrRemoteConnection,
        detail: '$e',
        diagnosticCode: HostLinkDiagnosticCode.pairedGatewayRefused,
      );
    }
  }

  /// The gateway ticket can stop working (expired, or the PC reset its access
  /// entry). The mux then reports `unauthorized`; that is a credential
  /// problem, not a dead socket, so the recovery loop re-exchanges first.
  void _watchMux(DshClient client) {
    unawaited(_muxSub?.cancel());
    _muxSub = client.mux.states.listen((state) {
      if (state == DshConnectionState.unauthorized && identical(client, _client) && !_recovering) {
        _lost(
          HostLinkError(
            HostLinkErrorKind.authFailed,
            appL10n.pairedErrNeedsRepair,
            retryable: true,
            diagnosticCode: HostLinkDiagnosticCode.pairedTicketRejected,
          ),
        );
      }
    });
  }

  void _lost(HostLinkError reason) {
    if (_closed || _recovering) return;
    unawaited(_recover(reason).then((_) {}, onError: (_) {}));
  }

  /// Reconnect loop with backoff. Resolves with the (possibly new) client.
  Future<DshClient> _recover(HostLinkError reason) async {
    _recovering = true;
    var last = reason;
    try {
      while (!_closed) {
        if (_backoff.exhausted) {
          final error = HostLinkError(
            last.kind,
            last.message,
            detail: [if (last.detail != null) last.detail!, appL10n.remoteRetryCount(_backoff.attempt)].join('\n'),
            retryable: true,
            diagnosticCode: last.diagnosticCode,
          );
          _fail(error);
          throw error;
        }
        final delay = _backoff.next();
        _emit(
          HostLinkStatus(
            HostLinkPhase.reconnecting,
            attempt: _backoff.attempt,
            error: last,
            nextRetryAt: DateTime.now().add(delay),
          ),
        );
        await _delay.wait(delay);
        if (_closed) break;
        try {
          final client = await _connectOnce();
          _backoff.reset();
          return client;
        } on HostLinkError catch (e) {
          if (_closed) break;
          if (!e.retryable) {
            _fail(e);
            rethrow;
          }
          last = e;
        } catch (_) {
          if (_closed) break;
          last = HostLinkError(HostLinkErrorKind.other, appL10n.commonConnectionFailed, retryable: true);
        }
      }
      throw StateError('link closed');
    } finally {
      _recovering = false;
    }
  }

  @override
  void kick() {
    if (_closed) return;
    switch (_status.phase) {
      case HostLinkPhase.connected:
        // A changed network kills sockets silently; the mux notices and the
        // recovery loop re-dials the entry.
        _client?.mux.reconnect();
      case HostLinkPhase.reconnecting:
        _backoff.reset();
        _delay.skip();
      case HostLinkPhase.failed:
        if (_status.error?.retryable ?? false) retry();
      case HostLinkPhase.idle || HostLinkPhase.connecting:
        break;
    }
  }

  @override
  void retry() {
    if (_closed) return;
    if (_status.phase == HostLinkPhase.reconnecting) {
      _backoff.reset();
      _delay.skip();
      return;
    }
    if (_status.isBusy) return;
    unawaited(open().then((_) {}, onError: (_) {}));
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _emit(HostLinkStatus.idle);
    _closed = true;
    _delay.cancel();
    await _kickSub?.cancel();
    await _muxSub?.cancel();
    final client = _client;
    _client = null;
    if (client != null) await client.close().catchError((_) {});
    await _statuses.close();
    await _clients.close();
  }
}
