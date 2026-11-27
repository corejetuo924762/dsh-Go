// The paired link end to end against a real loopback gateway: probe, exchange,
// open the socket, and the failure kinds a person must be able to tell apart.
// The WebSocket client is injected, so no second server is needed.

import 'dart:async';
import 'dart:io';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/remote/link_status.dart';
import 'package:dsh_app/remote/paired/paired_link.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// A ticket the gateway would mint today: valid for 30 days from now.
String _liveTicket() {
  final now = DateTime.now().millisecondsSinceEpoch;
  return 'v1.$now.${now + const Duration(days: 30).inMilliseconds}.c2lnbmF0dXJl';
}

/// A ticket from long ago, for the mint path (the link uses a freshly minted
/// ticket directly, without an expiry check).
const _ticket = 'v1.1750000000000.1752592000000.c2lnbmF0dXJl';

/// One fake access entry: records what the phone sent, answers like the PC
/// gateway is observed to.
class _Gateway {
  _Gateway(this.server);

  final HttpServer server;
  final List<Map<String, Object?>> requests = [];
  FutureOr<void> Function(HttpRequest request)? handler;

  String get origin => 'http://127.0.0.1:${server.port}';

  DshPairingEntry get entry => DshPairingEntry.lan(Uri.parse(origin));

  static Future<_Gateway> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final gateway = _Gateway(server);
    server.listen((request) async {
      gateway.requests.add({
        'method': request.method,
        'path': request.uri.path,
        'query': request.uri.queryParameters,
        'cookie': request.headers.value(HttpHeaders.cookieHeader),
      });
      final handler = gateway.handler;
      if (handler == null) {
        request.response.statusCode = 500;
        await request.response.close();
        return;
      }
      await handler(request);
    });
    return gateway;
  }

  Future<void> close() => server.close(force: true);
}

Future<void> _challenge(HttpRequest request, {int status = 401, int? retryAfter}) async {
  if (retryAfter != null) request.response.headers.set('retry-after', '$retryAfter');
  request.response.headers.contentType = ContentType.html;
  request.response.statusCode = status;
  request.response.write('<form method="post"><input name="code"></form>');
  await request.response.close();
}

Future<void> _mint(HttpRequest request, {String? ticket}) async {
  request.response.statusCode = 302;
  request.response.headers.set('location', '/');
  request.response.headers.set(
    'set-cookie',
    'dsh_remote_session=${ticket ?? _ticket}; Max-Age=2592000; Path=/; HttpOnly; SameSite=Lax',
  );
  await request.response.close();
}

/// A client that never dials; only its identity matters to the link's tests.
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

/// Records the ticket the link hands the client, so a renewal is visible.
class _Connector {
  final List<DshRemoteSession?> sessions = [];
  final List<String> origins = [];

  /// Lets a test return a fresh client per call (for the lost-then-renewed
  /// mux path) or throw to fail the connect.
  Future<DshClient> Function(DshRemoteSession? session)? onConnect;

  int get calls => sessions.length;

  Future<DshClient> call({required DshPairingEntry entry, required DshRemoteSession? session}) async {
    sessions.add(session);
    origins.add(entry.originHeader ?? '');
    final custom = onConnect;
    if (custom != null) return custom(session);
    return DshClient.withCarrier(_IdleCarrier());
  }
}

/// A carrier whose mux link can be pushed an `$events` frame and then made to
/// lose its ticket (openLink refuses 401 → mux `unauthorized`), so the link's
/// re-exchange-on-unauthorized path can be exercised.
class _ScriptedCarrier extends DshCarrier {
  _ScriptedLink? link;

  /// When true the next openLink refuses with 401, driving the mux unauthorized.
  bool refuse = false;

  @override
  String get kind => 'scripted';

  @override
  DshTracer? get tracer => null;

  @override
  bool allowsEndpoint(String endpoint) => true;

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) =>
      throw UnsupportedError(endpoint);

  @override
  Future<DshMuxLink> openLink(MuxOptions options) async {
    if (refuse) throw const DshHttpException(401, 'ticket revoked');
    return link = _ScriptedLink();
  }

  @override
  Future<void> close() async {}
}

class _ScriptedLink implements DshMuxLink {
  DshMuxFrameHandler? _onFrame;
  DshMuxLossHandler? _onLost;
  String? _eventsId;

  @override
  void start({required DshMuxFrameHandler onFrame, required DshMuxLossHandler onLost}) {
    _onFrame = onFrame;
    _onLost = onLost;
  }

  @override
  void open(String streamId, String endpoint, Map<String, Object?> payload) {
    if (endpoint != r'$events') return;
    _eventsId = streamId;
    scheduleMicrotask(
      () => _onFrame?.call({
        'type': 'item',
        'streamId': _eventsId,
        'value': {
          'type': 'ready',
          'clientId': 'client-1',
          'host': {'home': '/home/u'},
        },
      }),
    );
  }

  /// Drops the socket as the gateway revoking the ticket would.
  void drop() => _onLost?.call(const DshCarrierLostException('socket dropped'), null);

  @override
  void sendItem(String streamId, Object? value) {}

  @override
  void endUplink(String streamId) {}

  @override
  void cancel(String streamId) {}

  @override
  Future<void> close(int code, String reason) async {}
}

void main() {
  // No widget binding here: the gateway is a real loopback server, and a test
  // binding would answer every HttpClient request with 400.
  late _Gateway gateway;
  late DshPairingEntry entry;
  late DshRemoteSession? stored;
  late List<DshRemoteSession> saved;
  late _Connector connector;
  late String? renewal;

  setUp(() async {
    gateway = await _Gateway.start();
    entry = gateway.entry;
    stored = null;
    saved = [];
    connector = _Connector();
    renewal = null;
  });
  tearDown(() async => gateway.close());

  PairedHostLink link({String? code, bool withRenewal = false}) => PairedHostLink(
    entry: entry,
    loadSession: () async => stored,
    saveSession: (session) async {
      saved.add(session);
      stored = session;
    },
    code: code,
    connectClient: connector.call,
    loadRenewal: withRenewal ? () async => renewal : null,
    clearRenewal: withRenewal ? () async => renewal = null : null,
    backoff: Backoff(initial: const Duration(milliseconds: 5), maxAttempts: 1),
  );

  test('an entry that needs no ticket connects without an exchange', () async {
    gateway.handler = (request) async {
      request.response.statusCode = 200;
      await request.response.close();
    };
    final l = link();
    addTearDown(l.close);

    final client = await l.open();

    expect(client, isNotNull);
    expect(l.status.isConnected, isTrue);
    expect(l.status.completed, HostLinkStep.values.toSet());
    expect(saved, isEmpty, reason: 'nothing was minted');
    expect(connector.sessions.single, isNull);
    expect(gateway.requests, hasLength(1), reason: 'the probe only');
  });

  test('a gated entry trades the code for a ticket and keeps it', () async {
    gateway.handler = (request) {
      if (request.uri.queryParameters.containsKey('auth')) return _mint(request);
      if (request.headers.value(HttpHeaders.cookieHeader) != null) {
        request.response.statusCode = 200;
        return request.response.close();
      }
      return _challenge(request);
    };
    final l = link(code: 'abcd2345');
    addTearDown(l.close);

    await l.open();

    expect(saved, hasLength(1), reason: 'the minted ticket is persisted');
    expect(saved.single.value, _ticket);
    expect(connector.sessions.single?.value, _ticket, reason: 'the socket presents the fresh ticket');
    expect(l.code, isNull, reason: 'a code is single-use');
  });

  test('a stored ticket needs no code on the next connect', () async {
    final live = _liveTicket();
    gateway.handler = (request) {
      if (request.headers.value(HttpHeaders.cookieHeader) == 'dsh_remote_session=$live') {
        request.response.statusCode = 200;
        return request.response.close();
      }
      return _challenge(request);
    };
    stored = DshRemoteSession.tryParse(live, authority: entry.authority);
    final l = link();
    addTearDown(l.close);

    await l.open();

    expect(l.status.isConnected, isTrue);
    expect(connector.sessions.single?.value, live);
    expect(gateway.requests, hasLength(1), reason: 'the live ticket opened the entry outright');
  });

  test('an expired ticket and no code asks for a repair, not a retry', () async {
    gateway.handler = (request) => _challenge(request);
    final l = link();
    addTearDown(l.close);

    await expectLater(l.open(), throwsA(isA<HostLinkError>()));

    final error = l.status.error!;
    expect(error.kind, HostLinkErrorKind.authFailed);
    expect(error.retryable, isFalse);
    expect(error.diagnosticCode, HostLinkDiagnosticCode.pairedTicketRejected);
    expect(error.message, appL10n.pairedErrNeedsRepair);
    expect(l.status.phase, HostLinkPhase.failed);
  });

  test('a ban reports its seconds and refuses to retry', () async {
    gateway.handler = (request) => _challenge(request, status: 429, retryAfter: 30);
    final l = link();
    addTearDown(l.close);

    await expectLater(l.open(), throwsA(isA<HostLinkError>()));

    final error = l.status.error!;
    expect(error.kind, HostLinkErrorKind.unreachable);
    expect(error.retryable, isFalse, reason: 'never dial a sleeping gateway');
    expect(l.status.phase, HostLinkPhase.failed);
    expect(error.diagnosticCode, HostLinkDiagnosticCode.pairedBanned);
    expect(error.message, appL10n.pairedErrBanned(30));
  });

  test('a computer-side failure points at the computer', () async {
    gateway.handler = (request) => _challenge(request, status: 502);
    final l = link();
    addTearDown(l.close);

    await expectLater(l.open(), throwsA(isA<HostLinkError>()));

    final error = l.status.error!;
    expect(error.kind, HostLinkErrorKind.other);
    expect(error.diagnosticCode, HostLinkDiagnosticCode.pairedComputerFailed);
    expect(error.message, appL10n.pairedErrComputer);
  });

  test('nothing answering is unreachable and worth retrying', () async {
    await gateway.close();
    final l = link();
    addTearDown(l.close);

    await expectLater(l.open(), throwsA(isA<HostLinkError>()));

    final error = l.status.error!;
    expect(error.kind, HostLinkErrorKind.unreachable);
    expect(error.retryable, isTrue);
    expect(error.diagnosticCode, HostLinkDiagnosticCode.pairedUnreachable);
  });

  test('an expired ticket with a permanent renewal code re-exchanges silently', () async {
    // First connect had minted a ticket (now stale); the renewal code is the
    // link's permanent token, which the gateway keeps accepting.
    final stale = 'v1.1600000000000.1602592000000.c3RhbGU';
    final fresh = _liveTicket();
    gateway.handler = (request) {
      if (request.uri.queryParameters['auth'] == 'RENEW234') return _mint(request, ticket: fresh);
      if (request.headers.value(HttpHeaders.cookieHeader) == 'dsh_remote_session=$fresh') {
        request.response.statusCode = 200;
        return request.response.close();
      }
      return _challenge(request);
    };
    stored = DshRemoteSession.tryParse(stale, authority: entry.authority);
    renewal = 'RENEW234';
    final l = link(withRenewal: true);
    addTearDown(l.close);

    await l.open();

    // The stale ticket is never presented (that would only burn a rate-limit
    // slot); the renewal code mints silently and the fresh ticket is kept.
    expect(l.status.isConnected, isTrue);
    final auths = gateway.requests.map((r) => (r['query'] as Map)['auth']).toList();
    expect(auths, contains('RENEW234'));
    expect(saved, isNotEmpty, reason: 'the re-minted ticket is persisted (30 days rolled forward)');
    expect(saved.last.value, fresh);
    expect(connector.sessions.single?.value, fresh);
    expect(renewal, 'RENEW234', reason: 'a permanent code stays usable for the next lapse');
  });

  test('a rejected renewal code names an identity change and is dropped once', () async {
    // Both the stored ticket and the renewal code are refused (401).
    gateway.handler = (request) => _challenge(request);
    stored = DshRemoteSession.tryParse(_ticket, authority: entry.authority);
    renewal = 'DEAD2345';
    final l = link(withRenewal: true);
    addTearDown(l.close);

    await expectLater(l.open(), throwsA(isA<HostLinkError>()));

    final error = l.status.error!;
    expect(error.kind, HostLinkErrorKind.authFailed, reason: 'a credential problem, not the network');
    expect(error.retryable, isFalse);
    expect(error.diagnosticCode, HostLinkDiagnosticCode.pairedTicketRejected);
    expect(error.message, appL10n.pairedErrIdentityChanged);
    expect(renewal, isNull, reason: 'a dead code is dropped so it is not presented again');
    // Exactly one exchange with the renewal code: never loop a dead token.
    final authAttempts = gateway.requests.where((r) => (r['query'] as Map).containsKey('auth')).length;
    expect(authAttempts, 1);
  });

  test('a ban carries its remaining seconds structurally', () async {
    gateway.handler = (request) => _challenge(request, status: 429, retryAfter: 42);
    final l = link();
    addTearDown(l.close);

    await expectLater(l.open(), throwsA(isA<HostLinkError>()));

    final error = l.status.error!;
    expect(error.diagnosticCode, HostLinkDiagnosticCode.pairedBanned);
    expect(error.banRemaining, const Duration(seconds: 42));
    expect(error.message, appL10n.pairedErrBanned(42));
  });

  test('the four disconnect causes each read differently', () async {
    // 1) Credential lapse, no renewal code → ask for a re-pair.
    gateway.handler = (request) => _challenge(request);
    var l = link();
    addTearDown(l.close);
    await expectLater(l.open(), throwsA(isA<HostLinkError>()));
    final expired = l.status.error!;
    expect(expired.diagnosticCode, HostLinkDiagnosticCode.pairedTicketRejected);
    expect(expired.message, appL10n.pairedErrNeedsRepair);

    // 2) Ban → its own code and sentence.
    gateway.handler = (request) => _challenge(request, status: 429, retryAfter: 9);
    l = link();
    addTearDown(l.close);
    await expectLater(l.open(), throwsA(isA<HostLinkError>()));
    final banned = l.status.error!;
    expect(banned.diagnosticCode, HostLinkDiagnosticCode.pairedBanned);

    // 3) PC-side mint failure → point at the computer.
    gateway.handler = (request) => _challenge(request, status: 502);
    l = link();
    addTearDown(l.close);
    await expectLater(l.open(), throwsA(isA<HostLinkError>()));
    final pc = l.status.error!;
    expect(pc.diagnosticCode, HostLinkDiagnosticCode.pairedComputerFailed);
    expect(pc.message, appL10n.pairedErrComputer);

    // 4) Network down → unreachable, retryable.
    await gateway.close();
    l = link();
    addTearDown(l.close);
    await expectLater(l.open(), throwsA(isA<HostLinkError>()));
    final net = l.status.error!;
    expect(net.diagnosticCode, HostLinkDiagnosticCode.pairedUnreachable);
    expect(net.retryable, isTrue);
    expect(net.message, appL10n.remoteErrHostUnreachable);

    expect(
      {expired.diagnosticCode, banned.diagnosticCode, pc.diagnosticCode, net.diagnosticCode},
      hasLength(4),
    );
  });

  test('a later mux unauthorized re-exchanges with the renewal code', () async {
    final live = _liveTicket();
    final fresh = _liveTicket();
    gateway.handler = (request) {
      // After revocation only the renewal code mints.
      if (request.uri.queryParameters['auth'] == 'RENEW234') return _mint(request, ticket: fresh);
      if (request.headers.value(HttpHeaders.cookieHeader) == 'dsh_remote_session=$live') {
        request.response.statusCode = 200;
        return request.response.close();
      }
      return _challenge(request);
    };
    stored = DshRemoteSession.tryParse(live, authority: entry.authority);
    renewal = 'RENEW234';
    final carriers = <_ScriptedCarrier>[];
    connector.onConnect = (session) async {
      final carrier = _ScriptedCarrier();
      carriers.add(carrier);
      final client = DshClient.withCarrier(
        carrier,
        muxOptions: const MuxOptions(
          readyTimeout: Duration(seconds: 2),
          retryCaps: [Duration(milliseconds: 10)],
        ),
      );
      await client.mux.ready();
      return client;
    };
    final l = link(withRenewal: true);
    addTearDown(l.close);

    await l.open();
    expect(l.status.isConnected, isTrue);
    expect(connector.calls, 1);

    // The gateway revokes the ticket: the stored cookie stops working and the
    // socket drops, so the mux redials, gets 401 (unauthorized).
    gateway.handler = (request) {
      if (request.uri.queryParameters['auth'] == 'RENEW234') return _mint(request, ticket: fresh);
      // The freshly minted ticket is honoured; only the revoked one is not.
      if (request.headers.value(HttpHeaders.cookieHeader) == 'dsh_remote_session=$fresh') {
        request.response.statusCode = 200;
        return request.response.close();
      }
      return _challenge(request);
    };
    carriers.single.refuse = true; // next redial of the old carrier is refused
    carriers.single.link!.drop();

    await _until(
      () => connector.calls >= 2 && saved.any((s) => s.value == fresh),
      what: 'the revoked ticket is re-exchanged from the renewal code',
    );
    expect(l.status.isConnected, isTrue);
    expect(renewal, 'RENEW234', reason: 'the renewal code survived a successful recovery');
  });
}

/// Waits until [condition] holds, or fails after a short budget.
Future<void> _until(bool Function() condition, {required String what}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 8));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}