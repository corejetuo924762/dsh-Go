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

Future<void> _mint(HttpRequest request) async {
  request.response.statusCode = 302;
  request.response.headers.set('location', '/');
  request.response.headers.set(
    'set-cookie',
    'dsh_remote_session=$_ticket; Max-Age=2592000; Path=/; HttpOnly; SameSite=Lax',
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

  Future<DshClient> call({required DshPairingEntry entry, required DshRemoteSession? session}) async {
    sessions.add(session);
    origins.add(entry.originHeader ?? '');
    return DshClient.withCarrier(_IdleCarrier());
  }
}

void main() {
  // No widget binding here: the gateway is a real loopback server, and a test
  // binding would answer every HttpClient request with 400.
  late _Gateway gateway;
  late DshPairingEntry entry;
  late DshRemoteSession? stored;
  late List<DshRemoteSession> saved;
  late _Connector connector;

  setUp(() async {
    gateway = await _Gateway.start();
    entry = gateway.entry;
    stored = null;
    saved = [];
    connector = _Connector();
  });
  tearDown(() async => gateway.close());

  PairedHostLink link({String? code}) => PairedHostLink(
    entry: entry,
    loadSession: () async => stored,
    saveSession: (session) async {
      saved.add(session);
      stored = session;
    },
    code: code,
    connectClient: connector.call,
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
}
