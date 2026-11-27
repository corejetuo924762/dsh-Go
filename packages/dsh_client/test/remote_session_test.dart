import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

import 'support/fake_dsh.dart';

/// The gateway's ticket, as it appears in `Set-Cookie` and in the stored
/// `dsh_remote_session` cookie value.
const ticket = 'v1.1750000000.1752592000.c2lnbmF0dXJl';
const authority = '127.0.0.1:3088';

void main() {
  group('DshRemoteSession', () {
    test('reads the four-segment ticket and its lifetime', () {
      final session = DshRemoteSession.tryParse(ticket, authority: authority)!;
      expect(session.value, ticket);
      expect(session.authority, authority);
      expect(session.name, 'dsh_remote_session');
      expect(session.header, 'dsh_remote_session=$ticket');
      expect(session.issuedAt, DateTime.utc(2025, 6, 15, 15, 6, 40));
      expect(session.expiresAt, DateTime.utc(2025, 7, 15, 15, 6, 40));
      expect(session.isExpiredAt(DateTime.utc(2025, 7, 15, 15, 6, 39)), isFalse);
      expect(session.isExpiredAt(DateTime.utc(2025, 7, 15, 15, 6, 40)), isTrue);
    });

    test('the login cookie shape is not a remote session', () {
      // `dsh-auth-*` carries three segments; sessions carry four.
      expect(DshRemoteSession.tryParse('v1.payload.sig', authority: authority), isNull);
    });

    test('malformed values fail instead of guessing', () {
      for (final bad in <String>[
        '',
        'v2.1750000000.1752592000.sig',
        'v1.1750000000.1752592000',
        'v1.1750000000.1752592000.sig.extra',
        'v1..1752592000.sig',
        'v1.1750000000..sig',
        'v1.1750000000.1752592000.',
        'v1.not-a-time.1752592000.sig',
        'v1.1750000000.soon.sig',
      ]) {
        expect(DshRemoteSession.tryParse(bad, authority: authority), isNull, reason: bad);
      }
    });

    test('reads the gateway Set-Cookie and ignores any other cookie', () {
      final session = DshRemoteSession.fromSetCookie(
        'dsh_remote_session=$ticket; Max-Age=2592000; Path=/; HttpOnly; SameSite=Lax',
        authority: authority,
      )!;
      expect(session.header, 'dsh_remote_session=$ticket');
      expect(session.expiresAt, DateTime.utc(2025, 7, 15, 15, 6, 40));

      expect(
        DshRemoteSession.fromSetCookie('dsh-auth-abc=v1.payload.sig; Path=/', authority: authority),
        isNull,
      );
      expect(DshRemoteSession.fromSetCookie('dsh_remote_session=; Path=/', authority: authority), isNull);
    });

    test('a ticket without an expiry keeps no expiry', () {
      final session = DshRemoteSession.tryParse('v1.1750000000.0.sig', authority: authority)!;
      expect(session.issuedAt, DateTime.utc(2025, 6, 15, 15, 6, 40));
      expect(session.expiresAt, isNull);
      expect(session.isExpiredAt(DateTime.utc(2100)), isFalse);
    });

    test('survives the JSON round-trip used by secure storage', () {
      final session = DshRemoteSession.tryParse(ticket, authority: authority)!;
      final restored = DshRemoteSession.fromJson(session.toJson());
      expect(restored.header, session.header);
      expect(restored.authority, session.authority);
      expect(restored.issuedAt, session.issuedAt);
      expect(restored.expiresAt, session.expiresAt);
      expect(restored.toJson(), session.toJson());
    });
  });

  group('connection cookie channel', () {
    late FakeDsh host;

    setUp(() async => host = await FakeDsh.start());
    tearDown(() async => host.close());

    const muxOptions = MuxOptions(readyTimeout: Duration(seconds: 2), retryCaps: [Duration(milliseconds: 20)]);

    Future<DshClient> client() => DshClient.connect(
      baseUri: host.baseUri,
      token: FakeDsh.token,
      muxOptions: muxOptions,
      startMux: false,
    );

    test('the cookie header carries both cookies, login first', () async {
      final connected = await client();
      addTearDown(connected.close);
      final connection = connected.connection;
      expect(connection.cookie, isNotNull);
      expect(connection.cookieHeader, '${FakeDsh.cookieName}=${FakeDsh.cookieValue}');

      connection.remoteSession = DshRemoteSession.tryParse(ticket, authority: '127.0.0.1:${host.port}');
      expect(connection.cookieHeader, '${FakeDsh.cookieName}=${FakeDsh.cookieValue}; dsh_remote_session=$ticket');

      connection.cookie = null;
      expect(connection.cookieHeader, 'dsh_remote_session=$ticket');

      connection.remoteSession = null;
      expect(connection.cookieHeader, isNull);
    });

    test('requests carry both cookies and still carry no Origin', () async {
      host.handlers['session/list'] = (_) => {
        'ok': true,
        'value': {'items': <Object?>[]},
      };
      final connected = await client();
      addTearDown(connected.close);
      connected.connection.remoteSession = DshRemoteSession.tryParse(ticket, authority: '127.0.0.1:${host.port}');

      expect(await connected.listSessions(), isEmpty);

      final request = host.requests.last;
      expect(request['cookie'], '${FakeDsh.cookieName}=${FakeDsh.cookieValue}; dsh_remote_session=$ticket');
      expect(request['origin'], isNull);
      // The login cookie keeps its own authority and expiry handling.
      expect(connected.connection.cookie!.authority, '127.0.0.1:${host.port}');
      expect(connected.connection.cookie!.expiresAt!.isAfter(DateTime.now().add(const Duration(days: 29))), isTrue);
    });
  });

  group('entry origin', () {
    late FakeDsh host;

    setUp(() async => host = await FakeDsh.start());
    tearDown(() async => host.close());

    const muxOptions = MuxOptions(readyTimeout: Duration(seconds: 2), retryCaps: [Duration(milliseconds: 20)]);
    const tunnelOrigin = 'https://unsigned-unlimited-show-bumper.trycloudflare.com';

    DshRemoteSession remote() => DshRemoteSession.tryParse(ticket, authority: '127.0.0.1:${host.port}')!;

    test('a LAN entry sends no Origin at all', () async {
      host.handlers['session/list'] = (_) => {
        'ok': true,
        'value': {'items': <Object?>[]},
      };
      final connected = await DshClient.connect(
        baseUri: host.baseUri,
        token: FakeDsh.token,
        muxOptions: muxOptions,
        startMux: false,
      );
      addTearDown(connected.close);
      connected.connection.remoteSession = remote();

      expect(await connected.listSessions(), isEmpty);
      final request = host.requests.last;
      expect(request['origin'], isNull);
      expect((request['headerNames']! as List).cast<String>(), isNot(contains('origin')));
    });

    test('a tunnel entry sends exactly its own Origin, nothing else new', () async {
      host.handlers['session/list'] = (_) => {
        'ok': true,
        'value': {'items': <Object?>[]},
      };
      final lan = await DshClient.connect(
        baseUri: host.baseUri,
        token: FakeDsh.token,
        muxOptions: muxOptions,
        startMux: false,
      );
      addTearDown(lan.close);
      lan.connection.remoteSession = remote();
      await lan.listSessions();
      final lanRequest = host.requests.last;

      host.trustedOrigins.add(tunnelOrigin);
      final tunneled = DshClient(
        DshConnection(
          host.baseUri,
          originHeader: tunnelOrigin,
          cookie: lan.connection.cookie,
          remoteSession: remote(),
        ),
      );
      addTearDown(tunneled.close);
      await tunneled.listSessions();
      final tunnelRequest = host.requests.last;

      expect(tunnelRequest['origin'], tunnelOrigin);
      expect(tunnelRequest['cookie'], lanRequest['cookie']);
      final lanNames = (lanRequest['headerNames']! as List).cast<String>().toSet();
      final tunnelNames = (tunnelRequest['headerNames']! as List).cast<String>().toSet();
      expect(tunnelNames.difference(lanNames), {'origin'});
    });

    test('a tunnel WebSocket upgrade carries the ticket and the origin', () async {
      final login = DshConnection(host.baseUri);
      addTearDown(login.close);
      final cookie = await login.login(FakeDsh.token);
      host.trustedOrigins.add(tunnelOrigin);
      final connection = DshConnection(
        host.baseUri,
        originHeader: tunnelOrigin,
        cookie: cookie,
        remoteSession: remote(),
      );
      final connected = DshClient(connection, muxOptions: muxOptions);
      addTearDown(connected.close);

      await connected.mux.ready(timeout: const Duration(seconds: 5));

      final upgrade = host.requests.lastWhere((request) => request['path'] == '/api/remote.mux');
      expect(upgrade['origin'], tunnelOrigin);
      expect(upgrade['cookie'], '${cookie.header}; dsh_remote_session=$ticket');
    });

    test('a malformed origin is refused before any request', () {
      expect(() => DshConnection(host.baseUri, originHeader: 'tunnel.example'), throwsArgumentError);
    });
  });

  group('every request path', () {
    const tunnelOrigin = 'https://unsigned-unlimited-show-bumper.trycloudflare.com';

    test('background session reads keep both cookies and the entry origin', () async {
      Map<String, Object?>? seen;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        final body = jsonDecode(await utf8.decodeStream(request)) as Map<String, Object?>;
        seen = {
          'path': request.uri.path,
          'cookie': request.headers.value(HttpHeaders.cookieHeader),
          'origin': request.headers.value('origin'),
        };
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'type': 'server-response',
            'rpcId': body['rpcId'],
            'result': {
              'ok': true,
              'value': {'items': <Object?>[]},
            },
          }),
        );
        await request.response.close();
      });
      final serverAuthority = '127.0.0.1:${server.port}';
      final connection = DshConnection(
        Uri.parse('http://$serverAuthority'),
        originHeader: tunnelOrigin,
        cookie: DshCookie(name: 'dsh-auth-test', value: 'opaque', authority: serverAuthority),
        remoteSession: DshRemoteSession.tryParse(ticket, authority: serverAuthority),
      );
      final client = DshClient(connection, backgroundSessionLists: true);
      addTearDown(client.close);

      expect(await client.listSessions(), isEmpty);
      expect(seen, {
        'path': '/api/session/list',
        'cookie': 'dsh-auth-test=opaque; dsh_remote_session=$ticket',
        'origin': tunnelOrigin,
      });
    });

    test('connect wires the entry origin and the ticket into its connection', () async {
      final host = await FakeDsh.start();
      addTearDown(host.close);
      host.handlers['session/list'] = (_) => {
        'ok': true,
        'value': {'items': <Object?>[]},
      };
      host.trustedOrigins.add(tunnelOrigin);
      final connected = await DshClient.connect(
        baseUri: host.baseUri,
        token: FakeDsh.token,
        originHeader: tunnelOrigin,
        remoteSession: DshRemoteSession.tryParse(ticket, authority: '127.0.0.1:${host.port}'),
        muxOptions: const MuxOptions(readyTimeout: Duration(seconds: 2)),
        startMux: false,
      );
      addTearDown(connected.close);
      expect(connected.connection.originHeader, tunnelOrigin);
      expect(connected.connection.remoteSession!.value, ticket);

      expect(await connected.listSessions(), isEmpty);
      final request = host.requests.last;
      expect(request['origin'], tunnelOrigin);
      expect(request['cookie'], '${FakeDsh.cookieName}=${FakeDsh.cookieValue}; dsh_remote_session=$ticket');
    });
  });
}