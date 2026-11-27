// 配对主机的端到端验收：一条链接 → 连上 → 列会话 → 看回复 → 发消息 →
// 上传图片 → 导出日志 → 复制为 Markdown → 重启后免配对。
//
// 这里跑真的 HTTP 与真的 WebSocket：`FakeDsh` 是 dsh_client 测试套件里那个
// 进程内 `dsh web` 替身，前面挡一层配对口（探针 401 / 兑换 302 铸票 / 凭票
// 放行；配对口本身只认票，别的一律 401）。网关协议条款的用例在
// packages/dsh_client，这里验的是应用侧有没有把那条链路真的接上。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_app/remote/paired/paired_host_store.dart';
import 'package:dsh_app/remote/paired/paired_link.dart';
import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/share_code/conversation_share.dart';
import 'package:dsh_app/state/compose_inbox.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/replay/continue_chat.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../packages/dsh_client/test/support/fake_dsh.dart';

/// The 配对口: every request to the entry is gated by the ticket, and the code
/// exchange is the only way to get one.
class _Gateway {
  _Gateway(this.host, this.server, this.ticket);

  final FakeDsh host;
  final HttpServer server;

  /// What the exchange mints and what a stored ticket holds.
  final String ticket;

  /// A minimal archive, byte-for-byte a ZIP, for the export route.
  static final gatewayZip = <int>[0x50, 0x4b, 0x05, 0x06, ...List<int>.filled(18, 0)];

  /// Codes it still accepts (single use, like the real gateway).
  final Set<String> codes = {'ABCD2345'};

  /// The session the gateway itself holds on `dsh web`: the computer side of
  /// the pairing, minted once so the phone never needs the launch token.
  String hostCookie = '';

  DshPairingEntry get entry => DshPairingEntry.lan(Uri.parse('http://127.0.0.1:${server.port}'));

  static Future<_Gateway> start() async {
    final host = await FakeDsh.start();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final now = DateTime.now().millisecondsSinceEpoch;
    final ticket = 'v1.$now.${now + const Duration(days: 30).inMilliseconds}.c2lnbmF0dXJl';
    final gateway = _Gateway(host, server, ticket);
    gateway.hostCookie = await gateway._mintHostSession();
    server.listen(gateway._handle);
    return gateway;
  }

  /// Logs in to `dsh web` the way the PC gateway does, and keeps the cookie.
  Future<String> _mintHostSession() async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(host.baseUri.replace(queryParameters: {'token': FakeDsh.token}));
      // The mint answers 303; following it would reach the gated root instead.
      request.followRedirects = false;
      final response = await request.close();
      await response.drain<void>();
      final raw = response.headers['set-cookie']?.first ?? '';
      return raw.split(';').first;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> close() async {
    await server.close(force: true);
    await host.close();
  }

  bool _hasTicket(HttpRequest request) =>
      (request.headers.value(HttpHeaders.cookieHeader) ?? '')
          .split(';')
          .map((s) => s.trim())
          .contains('dsh_remote_session=$ticket');

  /// Passes the request to the Host under the Host's own authority and with the
  /// session this gateway holds on its behalf — which is exactly what the real
  /// gateway does, and why a ticket it accepts never reaches `dsh web`.
  Future<void> _forward(HttpRequest request, {List<int>? body}) async {
    final client = HttpClient();
    try {
      final target = Uri.parse('http://127.0.0.1:${host.port}${request.uri}');
      final out = await client.openUrl(request.method, target);
      for (final name in ['origin', 'content-type', 'accept']) {
        final value = request.headers.value(name);
        if (value != null) out.headers.set(name, value);
      }
      out.headers.set(HttpHeaders.cookieHeader, hostCookie);
      out.headers.set('host', '127.0.0.1:${host.port}');
      if (body != null) {
        // Content-Length must be set before the first byte: writing body data
        // freezes the header map.
        out.contentLength = body.length;
        out.add(body);
      }
      final response = await out.close();
      final bytes = await response.fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk));
      request.response.statusCode = response.statusCode;
      for (final name in ['content-type', 'location']) {
        final value = response.headers.value(name);
        if (value != null) request.response.headers.set(name, value);
      }
      request.response.add(bytes);
    } finally {
      client.close(force: true);
      await request.response.close();
    }
  }

  /// The socket upgrade is not an HTTP exchange: the gateway takes the client's
  /// socket and relays frames to the Host, which is also what the real one does.
  Future<void> _bridgeMux(HttpRequest request) async {
    final WebSocket client;
    try {
      client = await WebSocketTransformer.upgrade(request);
    } on WebSocketException {
      return;
    }
    final WebSocket upstream;
    try {
      upstream = await WebSocket.connect(
        'ws://127.0.0.1:${host.port}/api/remote.mux',
        headers: {HttpHeaders.cookieHeader: hostCookie},
      );
    } catch (_) {
      await client.close(1011, 'gateway cannot reach dsh web');
      return;
    }
    void relay(WebSocket from, WebSocket to) {
      from.listen(
        to.add,
        onDone: () {
          // 1005 means "closed without a code"; forwarding it is an invalid code.
          final code = from.closeCode;
          if (code == null || code == 1005) {
            to.close();
          } else {
            to.close(code, from.closeReason);
          }
        },
        onError: (_) => to.close(1011, 'relay failed'),
        cancelOnError: true,
      );
    }

    relay(client, upstream);
    relay(upstream, client);
  }

  Future<void> _handle(HttpRequest request) async {
    final query = request.uri.queryParameters;
    if (query['pair'] == '1') {
      final code = query['auth'];
      if (code == null || !codes.remove(code.toUpperCase())) {
        request.response.statusCode = 401;
        request.response.write('<form>请输入配对码</form>');
        await request.response.close();
        return;
      }
      request.response.statusCode = 302;
      request.response.headers.set('location', '/');
      request.response.headers.set(
        'set-cookie',
        'dsh_remote_session=$ticket; Max-Age=2592000; Path=/; HttpOnly; SameSite=Lax',
      );
      await request.response.close();
      return;
    }
    if (!_hasTicket(request)) {
      // The probe, the socket upgrade and every API call reach here without a
      // ticket first: nothing but the exchange may proceed.
      request.response.statusCode = 401;
      request.response.write('<form>请输入配对码</form>');
      await request.response.close();
      return;
    }
    if (request.uri.path == '/api/remote.mux') {
      await _bridgeMux(request);
      return;
    }
    if (request.uri.path == '/api/session.export') {
      // The app fetches the Host's ZIP over this HTTP route; the Host stub used
      // here predates it, so the gateway answers with a real (small) archive.
      request.response.statusCode = 200;
      request.response.headers.contentType = ContentType('application', 'zip');
      request.response.add(gatewayZip);
      await request.response.close();
      return;
    }
    if (request.uri.path.startsWith('/api/') && request.method == 'POST') {
      final builder = BytesBuilder(copy: false);
      await for (final chunk in request) {
        builder.add(chunk);
      }
      await _forward(request, body: builder.takeBytes());
      return;
    }
    await _forward(request);
  }
}

Future<void> _until(bool Function() ready, {String what = ''}) async {
  final deadline = Stopwatch()..start();
  while (!ready()) {
    if (deadline.elapsed > const Duration(seconds: 10)) fail('等待超时：$what');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Future<DshClient> _connect(DshPairingEntry entry, DshRemoteSession? session) => DshClient.connect(
  baseUri: entry.baseUri,
  remoteSession: session,
  originHeader: entry.originHeader,
  muxOptions: const MuxOptions(readyTimeout: Duration(seconds: 5), retryCaps: [Duration(milliseconds: 20)]),
);

void main() {
  late _Gateway gateway;
  late MemorySecretStore secrets;
  late PairedHostStore store;
  late String id;

  setUp(() async {
    gateway = await _Gateway.start();
    gateway.host.handlers['session/list'] = (_) => {
      'ok': true,
      'value': {
        'items': [
          {
            'sessionId': 'session-1',
            'updatedAt': DateTime.now().millisecondsSinceEpoch,
            'cwd': '/home/user',
            'projections': {
              'kind': 'cached',
              'asOfSeq': 1,
              'values': {
                'title': '报价单',
                'sessionListMetadata': {'blank': false},
              },
            },
          },
        ],
      },
    };
    gateway.host.handlers['session/prompt'] = (_) => {'ok': true, 'value': <String, Object?>{}};
    gateway.host.onOpen = (socket, streamId, endpoint, payload) {
      if (endpoint != 'session/follow') return;
      socket.item(streamId, {
        'type': 'snapshot',
        'header': {'version': 4, 'id': 'session-1', 'createdAt': 1, 'cwd': '/home/user', 'isSeeded': false},
        'cursor': 0,
        'records': <Object?>[],
        'hasMore': false,
        'projections': {'asOfSeq': 0, 'values': <String, Object?>{}},
        'assistantStream': {'revision': 0},
      });
      socket.item(streamId, {
        'type': 'event',
        'event': {
          'type': 'assistant/message',
          'seq': 1,
          'time': DateTime.now().millisecondsSinceEpoch,
          'data': {
            'turn': 1,
            'step': 1,
            'message': {
              'role': 'assistant',
              'content': [
                {'type': 'text', 'text': '好的，我先看一下。'},
              ],
              'id': 'm1',
            },
          },
        },
      });
      socket.item(streamId, {
        'type': 'event',
        'event': {
          'type': 'turn/end',
          'seq': 2,
          'time': DateTime.now().millisecondsSinceEpoch,
          'data': {
            'turn': 1,
            'reason': {'kind': 'completed'},
          },
        },
      });
    };
    secrets = MemorySecretStore();
    store = PairedHostStore(secrets);
    id = pairedHostId(gateway.entry.authority);
  });
  tearDown(() async => gateway.close());

  PairedHostLink link({String? code}) => PairedHostLink(
    entry: gateway.entry,
    loadSession: () => store.loadSession(id),
    saveSession: (session) => store.saveSession(id, session),
    code: code,
    connectClient: ({required entry, required session}) => _connect(entry, session),
  );

  test('one link → connect → list → reply → send; the ticket is kept', () async {
    final paired = link(code: 'ABCD2345');
    addTearDown(paired.close);

    final client = await paired.open();
    expect(paired.status.isConnected, isTrue);
    expect(paired.status.completed, HostLinkStep.values.toSet());

    // 会话列表来自那台电脑。
    final sessions = await client.listSessions();
    expect(sessions.single.title, '报价单');
    expect(sessions.single.cwd, '/home/user');

    // 打开对话：follow 流把这一轮的回复送进来。
    final transcript = ChatTranscript();
    final sub = client.watch('session-1').listen(transcript.apply);
    addTearDown(sub.cancel);
    await _until(() => transcript.items.whereType<AssistantChatItem>().isNotEmpty, what: '看到回复');
    expect(transcript.items.whereType<AssistantChatItem>().single.text, contains('好的，我先看一下。'));

    // 发一条消息。
    final requestId = await client.prompt('session-1', '帮我整理这份报价');
    expect(requestId, isNotEmpty);
    expect(gateway.host.rpcCalls.map((c) => c['method']), contains('session/prompt'));

    // 配对结果留在加密存储里：重启后凭票直连，不需要重新配对。
    expect((await store.loadSession(id))!.value, gateway.ticket);
    final again = link();
    addTearDown(again.close);
    final second = await again.open();
    expect(again.status.isConnected, isTrue);
    expect((await second.listSessions()).single.title, '报价单');
  });

  test('uploads and exports over the paired gateway; capability, not host kind', () async {
    gateway.host.uploadFileBinary = (sessionId, name, bytes) => {
      'ok': true,
      'value': {
        'receiptId': 'r1',
        'file': {'name': name ?? 'image.png', 'bytes': bytes.length, 'mimeType': 'image/png'},
      },
    };
    final paired = link(code: 'ABCD2345');
    addTearDown(paired.close);
    final client = await paired.open();

    // 上传：能力来自这条连接自身，不再按主机类型一律拒绝。
    final connection = HostConnection(client: client, label: '书房 · 配对', isLocal: false, kind: HostKind.paired, hostId: id);
    expect(canStageFiles(connection, HostRef.paired(id)), isTrue);
    final bytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAYAAACp8Z5+AAAAEklEQVR4nGPwTt/yHxkzkC4AAAPnJlH/osXzAAAAAElFTkSuQmCC',
    );
    final receipt = await client.uploadFile('session-1', bytes, name: '截图.png');
    expect(receipt.receiptId, 'r1');
    expect(gateway.host.binaryUploads.single['bytes'], bytes.length);

    // 导出：HTTP 路由，在配对链路上就是可达的。
    expect(client.canExportSessionLog, isTrue);
    final zip = await client.exportSessionLog('session-1');
    expect(zip.length, greaterThan(0));

    // 复制为 Markdown：本地渲染，不经主机。
    final markdown = conversationMarkdown(
      ConversationShare(
        title: '报价单',
        start: DateTime(2026, 3, 5, 10),
        entries: [
          UserEntry(t: 0, text: '帮我整理这份报价'),
          ReplyEntry(t: 60, text: '好的，我先看一下。', plain: '好的，我先看一下。'),
        ],
      ),
    );
    expect(markdown, contains('# 报价单'));
    expect(markdown, contains('帮我整理这份报价'));
    expect(markdown, contains('好的，我先看一下。'));
  });
}
