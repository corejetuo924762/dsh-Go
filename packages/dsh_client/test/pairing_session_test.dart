import 'dart:async';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

const _lanLink = 'http://192.168.1.5:3088/?auth=ABCD2345';
const _tunnelLink = 'https://unsigned-unlimited-show-bumper.trycloudflare.com/?auth=ABCD2345';

void main() {
  group('DshPairingInput.tryParse', () {
    test('a LAN access link yields its entry and its credential', () {
      final input = DshPairingInput.tryParse(_lanLink)!;
      expect(input.entry!.baseUri.toString(), 'http://192.168.1.5:3088');
      expect(input.entry!.authority, '192.168.1.5:3088');
      expect(input.entry!.isTunnel, isFalse);
      expect(input.entry!.originHeader, isNull, reason: 'a LAN entry sends no Origin');
      expect(input.code, 'ABCD2345');
    });

    test('a tunnel access link is a tunnel entry and carries its own Origin', () {
      final input = DshPairingInput.tryParse(_tunnelLink)!;
      expect(input.entry!.baseUri.toString(), _tunnelLink.split('/?').first);
      expect(input.entry!.isTunnel, isTrue);
      expect(input.entry!.originHeader, _tunnelLink.split('/?').first);
      expect(input.code, 'ABCD2345');
    });

    test('a bare pairing code is a credential without an entry', () {
      for (final typed in <String>['ABCD2345', 'abcd2345', '  abcd2345  ']) {
        final input = DshPairingInput.tryParse(typed)!;
        expect(input.entry, isNull, reason: typed);
        expect(input.code, 'ABCD2345', reason: typed);
      }
    });

    test('an entry address plus a code parses as both parts', () {
      final input = DshPairingInput.tryParse('192.168.1.5:3088 ABCD2345')!;
      expect(input.entry!.baseUri.toString(), 'http://192.168.1.5:3088');
      expect(input.entry!.isTunnel, isFalse);
      expect(input.code, 'ABCD2345');
    });

    test('a public hostname without a scheme is a tunnel entry', () {
      final input = DshPairingInput.tryParse('unset-lineup-allowances-invitations.trycloudflare.com ABCD2345')!;
      expect(input.entry!.isTunnel, isTrue);
      expect(input.entry!.baseUri.toString(), 'https://unset-lineup-allowances-invitations.trycloudflare.com');
      expect(input.code, 'ABCD2345');
    });

    test('an IPv6 entry keeps its brackets and its port', () {
      final link = DshPairingInput.tryParse('http://[fe80::1]:3088/?auth=ABCD2345')!;
      expect(link.entry!.authority, '[fe80::1]:3088');
      expect(link.entry!.baseUri.toString(), 'http://[fe80::1]:3088');
      expect(link.code, 'ABCD2345');

      final bare = DshPairingInput.tryParse('[fe80::1]:3088 ABCD2345')!;
      expect(bare.entry!.authority, '[fe80::1]:3088');
      expect(bare.code, 'ABCD2345');
    });

    test('a missing port is not a malformed address', () {
      final input = DshPairingInput.tryParse('http://192.168.1.5/?auth=ABCD2345')!;
      expect(input.entry!.baseUri.host, '192.168.1.5');
      expect(input.entry!.baseUri.port, 80);
      expect(input.code, 'ABCD2345');
    });

    test('extra query parameters are dropped, never mistaken for the code', () {
      final input = DshPairingInput.tryParse('http://192.168.1.5:3088/?auth=ABCD2345&utm=chat')!;
      expect(input.entry!.baseUri.toString(), 'http://192.168.1.5:3088');
      expect(input.entry!.baseUri.hasQuery, isFalse);
      expect(input.code, 'ABCD2345');
    });

    test('a link without a code is an entry with no credential', () {
      final input = DshPairingInput.tryParse('http://192.168.1.5:3088/')!;
      expect(input.entry!.authority, '192.168.1.5:3088');
      expect(input.code, isNull);
    });

    test('a dsh web launch token is not a pairing credential', () {
      final input = DshPairingInput.tryParse('http://127.0.0.1:3080/?token=c2VjcmV0')!;
      expect(input.entry!.authority, '127.0.0.1:3080');
      expect(input.code, isNull);
      expect(input.entry!.toString(), isNot(contains('c2VjcmV0')));
    });

    test('malformed input fails instead of guessing', () {
      for (final bad in <String>[
        '',
        '   ',
        'http://',
        'ftp://192.168.1.5:3088/?auth=ABCD2345',
        '192.168.1.5:3088/?auth=ABCD2345',
        // Userinfo is password-shaped content and never enters a pairing input.
        'http://user:pass@192.168.1.5:3088/?auth=ABCD2345',
        // Not an 8-character code from the gateway alphabet.
        'http://192.168.1.5:3088/?auth=abc',
        'http://192.168.1.5:3088/?auth=ABCD23456',
        'ABCD234',
        'ABCD23456',
        'ABCD234O',
        'ABCD234I',
        '192.168.1.5:3088 SHORT1',
        'notanaddress',
        'notanaddress ABCD2345',
      ]) {
        expect(DshPairingInput.tryParse(bad), isNull, reason: bad);
      }
    });

    test('a code-only input carries no entry for the caller to fill in', () {
      final input = DshPairingInput.tryParse('abcd2345')!;
      expect(input.entry, isNull);
      expect(input.code, 'ABCD2345');
      expect(DshPairingInput.codeOf('abcd2345'), 'ABCD2345');
    });
  });

  protocolTests();
}

// ── protocol ────────────────────────────────────────────────────────────────

const _ticket = 'v1.1750000000000.1752592000000.c2lnbmF0dXJl';

/// One fake access entry: records what the phone sent and answers with the
/// shapes the PC gateway is observed to produce.
class _Gateway {
  _Gateway(this.server);

  final HttpServer server;
  final List<Map<String, Object?>> requests = [];
  FutureOr<void> Function(HttpRequest request)? handler;

  String get origin => 'http://127.0.0.1:${server.port}';

  DshPairingEntry get lanEntry => DshPairingEntry.lan(Uri.parse(origin));

  static Future<_Gateway> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final gateway = _Gateway(server);
    server.listen((request) async {
      gateway.requests.add({
        'method': request.method,
        'path': request.uri.path,
        'query': request.uri.queryParameters,
        'cookie': request.headers.value(HttpHeaders.cookieHeader),
        'origin': request.headers.value('origin'),
        'accept': request.headers.value(HttpHeaders.acceptHeader),
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

/// The gateway's browse-navigation challenge: a login page, no cookie.
Future<void> _challenge(HttpRequest request, {int status = 401, int? retryAfter}) async {
  if (retryAfter != null) request.response.headers.set('retry-after', '$retryAfter');
  request.response.headers.contentType = ContentType.html;
  request.response.statusCode = status;
  request.response.write('<form method="post"><input name="code"></form>');
  await request.response.close();
}

/// The gateway's successful exchange: a redirect carrying the ticket.
Future<void> _mint(HttpRequest request, {String ticket = _ticket, int status = 302}) async {
  request.response.statusCode = status;
  request.response.headers.set('location', '/');
  request.response.headers.set(
    'set-cookie',
    'dsh_remote_session=$ticket; Max-Age=2592000; Path=/; HttpOnly; SameSite=Lax',
  );
  await request.response.close();
}

void protocolTests() {
  late _Gateway gateway;

  setUp(() async => gateway = await _Gateway.start());
  tearDown(() async => gateway.close());

  DshPairingSession session({DateTime Function()? now}) => DshPairingSession(
    gateway.lanEntry,
    now: now ?? () => DateTime.utc(2025, 6, 15, 15, 6, 40),
  );

  test('an entry that needs no credential connects without exchanging', () async {
    gateway.handler = (request) async {
      request.response.statusCode = 200;
      await request.response.close();
    };

    final outcome = await session().connect();

    expect(outcome, isA<DshPairingConnected>());
    final connected = outcome as DshPairingConnected;
    expect(connected.session, isNull, reason: 'nothing was minted');
    expect(connected.entry.authority, '127.0.0.1:${gateway.server.port}');
    expect(gateway.requests, hasLength(1));
    expect(gateway.requests.single['cookie'], isNull, reason: 'the probe carries no cookie');
    expect(gateway.requests.single['origin'], isNull, reason: 'a LAN entry sends no Origin');
  });

  test('an entry that wants a credential asks for the code before dialing on', () async {
    gateway.handler = (request) => _challenge(request);

    final outcome = await session().connect();

    expect(outcome, isA<DshPairingNeedsCode>());
    expect(gateway.requests, hasLength(1), reason: 'the probe stops at 401');
  });

  test('the exchange trades the code for a ticket and reads its lifetime', () async {
    gateway.handler = (request) {
      if (request.uri.queryParameters.containsKey('auth')) return _mint(request);
      // The gateway verified its own ticket: the PC behind it is happy.
      if (request.headers.value(HttpHeaders.cookieHeader) != null) {
        request.response.statusCode = 200;
        return request.response.close();
      }
      return _challenge(request);
    };

    final outcome = await session().connect(code: 'abcd2345');

    expect(outcome, isA<DshPairingConnected>());
    final connected = outcome as DshPairingConnected;
    expect(connected.session!.value, _ticket);
    expect(connected.session!.issuedAt, DateTime.utc(2025, 6, 15, 15, 6, 40));
    expect(connected.session!.expiresAt, DateTime.utc(2025, 7, 15, 15, 6, 40));

    final exchange = gateway.requests.firstWhere((request) => (request['query']! as Map).containsKey('auth'));
    expect(exchange['path'], '/');
    expect(exchange['query'], {'pair': '1', 'auth': 'ABCD2345'}, reason: 'the code is sent in the gateway upper case, and pair=1 forces a re-mint');
    expect((exchange['accept']! as String).toLowerCase(), contains('text/html'), reason: 'only a navigation exchange is minted');
    expect(exchange['cookie'], isNull, reason: 'the exchange never relies on an old cookie');
  });

  test('an unauthorized exchange means the code is stale and pairing must be redone', () async {
    gateway.handler = (request) {
      if (request.uri.queryParameters.containsKey('auth')) return _challenge(request, status: 401);
      return _challenge(request);
    };

    final outcome = await session().connect(code: 'ABCD2345');

    expect(outcome, isA<DshPairingCodeRejected>());
    expect((outcome as DshPairingCodeRejected).ticketRejected, isFalse, reason: 'a typed code was rejected, not the stored ticket');
  });

  test('a denied source is the entry refusing this phone, not a stale code', () async {
    gateway.handler = (request) => _challenge(request, status: 403);

    final outcome = await session().connect(code: 'ABCD2345');

    expect(outcome, isA<DshPairingRefused>());
    expect((outcome as DshPairingRefused).statusCode, 403);
    expect(gateway.requests, hasLength(1), reason: 'a denied source never reaches the exchange');
  });

  test('a gateway that cannot reach the host is the computer failing too', () async {
    gateway.handler = (request) => _challenge(request, status: 502);

    final outcome = await session().connect(code: 'ABCD2345');

    expect(outcome, isA<DshPairingComputerFailed>());
    expect((outcome as DshPairingComputerFailed).statusCode, 502);
  });

  test('a ban reports the seconds the gateway asked for and stops retrying', () async {
    var clock = DateTime.utc(2025, 6, 15, 15, 6, 40);
    gateway.handler = (request) => _challenge(request, status: 429, retryAfter: 30);
    final banned = session(now: () => clock);

    final first = await banned.connect(code: 'ABCD2345');
    expect(first, isA<DshPairingBanned>());
    expect((first as DshPairingBanned).remaining, const Duration(seconds: 30));
    final dialed = gateway.requests.length;

    // The same attempt does not dial again while the ban stands, it only
    // reports what is left of it.
    clock = clock.add(const Duration(seconds: 10));
    final second = await banned.connect(code: 'ABCD2345');
    expect(second, isA<DshPairingBanned>());
    expect((second as DshPairingBanned).remaining, const Duration(seconds: 20));
    expect(gateway.requests.length, dialed, reason: 'no retry during the ban');

    // Once the ban lapses the attempt dials again.
    clock = clock.add(const Duration(seconds: 21));
    await banned.connect(code: 'ABCD2345');
    expect(gateway.requests.length, greaterThan(dialed));
  });

  test('a ticket the host rejects right after minting points at the computer', () async {
    gateway.handler = (request) {
      if (request.uri.queryParameters.containsKey('auth')) return _mint(request);
      // The gateway verified its own ticket, forwarded, and the PC's own
      // session cookie could not be minted: the upstream answers 401.
      if (request.headers.value(HttpHeaders.cookieHeader) != null) return _challenge(request, status: 401);
      return _challenge(request);
    };

    final outcome = await session().connect(code: 'ABCD2345');

    expect(outcome, isA<DshPairingComputerFailed>());
    final check = gateway.requests.last;
    expect(check['cookie'], 'dsh_remote_session=$_ticket', reason: 'the check reuses the freshly minted ticket');
  });

  test('a redirect that carries no ticket is not a success', () async {
    gateway.handler = (request) {
      if (request.uri.queryParameters.containsKey('auth')) {
        request.response.statusCode = 302;
        request.response.headers.set('location', '/');
        return request.response.close();
      }
      return _challenge(request);
    };

    await expectLater(session().connect(code: 'ABCD2345'), throwsA(isA<DshProtocolException>()));
  });

  test('a tunnel entry sends its own Origin on every request', () async {
    gateway.handler = (request) => _challenge(request);
    final tunnel = DshPairingSession(DshPairingEntry.tunnel(Uri.parse(gateway.origin)));

    await tunnel.connect(code: 'ABCD2345');

    expect(gateway.requests, isNotEmpty);
    for (final request in gateway.requests) {
      expect(request['origin'], gateway.origin);
    }
  });

  test('a stored ticket is used to probe, so a paired entry needs no code again', () async {
    gateway.handler = (request) {
      final cookie = request.headers.value(HttpHeaders.cookieHeader);
      if (cookie == 'dsh_remote_session=$_ticket') {
        request.response.statusCode = 200;
        return request.response.close();
      }
      return _challenge(request);
    };
    final paired = session()..session = DshRemoteSession.tryParse(_ticket, authority: gateway.lanEntry.authority)!;

    final outcome = await paired.connect();

    expect(outcome, isA<DshPairingConnected>());
    expect((outcome as DshPairingConnected).session!.value, _ticket);
    expect(gateway.requests, hasLength(1), reason: 'no exchange, no code asked for');
    expect(gateway.requests.single['cookie'], 'dsh_remote_session=$_ticket');
  });

  test('a stored ticket the gateway no longer accepts asks for a new code', () async {
    gateway.handler = (request) => _challenge(request);
    final paired = session()..session = DshRemoteSession.tryParse(_ticket, authority: gateway.lanEntry.authority)!;

    final outcome = await paired.connect();

    expect(outcome, isA<DshPairingNeedsCode>());
  });

  test('an expired stored ticket is never sent, but the entry is still probed', () async {
    gateway.handler = (request) => _challenge(request);
    final expired = DshRemoteSession.tryParse('v1.1750000000000.1750100000000.sig', authority: gateway.lanEntry.authority)!;
    final paired = DshPairingSession(gateway.lanEntry, now: () => DateTime.utc(2025, 7, 1))..session = expired;

    final outcome = await paired.connect();

    expect(outcome, isA<DshPairingNeedsCode>());
    expect(gateway.requests, hasLength(1), reason: 'a dead ticket is useless against a gateway that still needs one');
    expect(gateway.requests.single['cookie'], isNull, reason: 'a lapsed ticket would only burn a rate-limit slot');
  });

  test('a ban without an announced wait is reported, not invented', () async {
    gateway.handler = (request) => _challenge(request, status: 429);

    final outcome = await session().connect(code: 'ABCD2345');

    expect(outcome, isA<DshPairingRefused>());
    expect((outcome as DshPairingRefused).statusCode, 429);
    expect(outcome.message, contains('等待秒数'), reason: 'the person is told the gateway gave no number');
  });

  test('a stored ticket the gateway rejects is a re-pair, not a retyped digit', () async {
    gateway.handler = (request) => _challenge(request);
    final paired = session()..session = DshRemoteSession.tryParse(_ticket, authority: gateway.lanEntry.authority)!;

    // The probe answers 401 for the lapsed ticket, and a code is at hand.
    final outcome = await paired.connect(code: 'ABCD2345');

    expect(outcome, isA<DshPairingCodeRejected>());
    expect((outcome as DshPairingCodeRejected).ticketRejected, isTrue);
  });

  test('an unreachable entry surfaces the transport failure instead of a guess', () async {
    final closed = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final deadOrigin = 'http://127.0.0.1:${closed.port}';
    await closed.close(force: true);

    await expectLater(
      DshPairingSession(DshPairingEntry.lan(Uri.parse(deadOrigin))).connect(code: 'ABCD2345'),
      throwsA(isA<DshTransportException>()),
    );
  });
}
