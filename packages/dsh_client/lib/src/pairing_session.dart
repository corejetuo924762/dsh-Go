/// Pairing input handed to the phone by a person, and the protocol that turns
/// it into a usable gateway session.
///
/// The PC-side gateway (`dsh-tauri-remote`) exposes `dsh web` behind one
/// access entry: a LAN address on `http`, or a Cloudflare tunnel on `https`.
/// Both are gated the same way — a browser-navigation exchange with the
/// pairing code trades it for a `dsh_remote_session` cookie, and only then may
/// the WebSocket upgrade open. This library is that whole protocol, with no
/// Flutter and no app state, so the flow can be exercised on its own.
///
/// Nothing here ever carries password-shaped content: the pairing code is the
/// only credential, and no userinfo is accepted in an entry address.
library;

import 'connection.dart';
import 'errors.dart';

/// One access entry of a paired computer: where to dial, and whether that
/// entry is the public tunnel leg (which must send an `Origin`).
class DshPairingEntry {
  DshPairingEntry({required this.baseUri, required this.isTunnel});

  DshPairingEntry.lan(Uri baseUri) : this(baseUri: baseUri, isTunnel: false);

  DshPairingEntry.tunnel(Uri baseUri) : this(baseUri: baseUri, isTunnel: true);

  /// The one spelling of a kept entry: scheme and host lower case, no default
  /// port, no trailing slash, no query or fragment. [#10] deliberately leaves
  /// [DshPairingInput]'s spelling alone, so the *app* normalizes what it
  /// stores: two ways of writing one address must key one host, never two.
  ///
  /// [isTunnel] overrides the scheme's own answer only for entries restored
  /// from storage, where the leg matters more than the scheme.
  factory DshPairingEntry.canonical(Uri baseUri, {bool? isTunnel}) {
    final scheme = baseUri.scheme.toLowerCase() == 'https' ? 'https' : 'http';
    final path = baseUri.path == '/' ? '' : baseUri.path;
    return DshPairingEntry(
      baseUri: Uri(
        scheme: scheme,
        host: baseUri.host.toLowerCase(),
        port: baseUri.hasPort ? baseUri.port : null,
        path: path,
      ),
      isTunnel: isTunnel ?? scheme == 'https',
    );
  }

  /// `http://192.168.1.5:3088` or the tunnel's `https://<public host>`, with
  /// no trailing slash and no query: the pairing code never stays in it.
  final Uri baseUri;

  /// The public tunnel leg. A tunnel entry refuses every request without an
  /// `Origin` matching its own address; a LAN entry must send none.
  final bool isTunnel;

  /// `Origin` this entry requires, or `null` for a LAN entry.
  String? get originHeader => isTunnel ? '${baseUri.scheme}://$authority' : null;

  /// `host:port`, bracketed for IPv6 and without the scheme's default port.
  String get authority => _authorityOf(baseUri);

  static String _authorityOf(Uri uri) {
    final host = uri.host.contains(':') ? '[${uri.host}]' : uri.host;
    final defaultPort = uri.scheme == 'https' ? 443 : 80;
    return uri.port == defaultPort ? host : '$host:${uri.port}';
  }

  @override
  bool operator ==(Object other) =>
      other is DshPairingEntry && other.baseUri == baseUri && other.isTunnel == isTunnel;

  @override
  int get hashCode => Object.hash(baseUri, isTunnel);

  @override
  String toString() => 'DshPairingEntry($authority, ${isTunnel ? 'tunnel' : 'lan'})';
}

/// What a person handed the phone: an [entry], a [code], or both.
///
/// The gateway's pairing code is 8 characters from
/// `23456789ABCDEFGHJKLMNPQRSTUVWXYZ` (no `I`, no `O`), single use, and
/// good for 5 minutes. Input is case-insensitive; [code] is always upper case.
class DshPairingInput {
  const DshPairingInput({this.entry, this.code});

  /// Where to dial; absent when the person typed the bare 8-character code.
  final DshPairingEntry? entry;

  /// The pairing code, upper-cased; absent for a link that carries no code.
  final String? code;

  /// The gateway's code alphabet, in the order the gateway draws from it.
  static const codeAlphabet = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';

  static const codeLength = 8;

  /// [value] upper-cased when it is exactly one pairing code
  /// (case-insensitive); `null` when it is not.
  static String? codeOf(String value) => _code(value);

  /// Reads the three input shapes a person can produce — an access link, a
  /// bare pairing code, or an address plus a code — and refuses everything
  /// else instead of guessing an address or a credential out of it.
  static DshPairingInput? tryParse(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;

    if (text.contains('://')) {
      final uri = Uri.tryParse(text);
      if (uri == null) return null;
      return _fromUri(uri);
    }

    final fields = text.split(RegExp(r'\s+'));
    if (fields.length == 1) {
      final single = fields.single;
      final code = _code(single);
      if (code != null) return DshPairingInput(code: code);
      // No slash: an address with a path can only be a link, and a link is
      // written with its scheme.
      if (single.contains('/')) return null;
      final entry = _entryOf(single);
      return entry == null ? null : DshPairingInput(entry: entry);
    }
    if (fields.length != 2) return null;
    final code = _code(fields[1]);
    if (code == null) return null;
    final entry = _entryOf(fields[0]);
    return entry == null ? null : DshPairingInput(entry: entry, code: code);
  }

  static DshPairingInput? _fromUri(Uri uri) {
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    // Userinfo would be password-shaped content; a pairing link never has one.
    if (uri.userInfo.isNotEmpty || uri.host.isEmpty) return null;
    // A link either names the code in `auth` or carries none at all. An `auth`
    // that is present but unreadable is a wrong paste, not "no code".
    final auth = uri.queryParameters['auth'];
    final code = auth == null ? null : _code(auth);
    if (auth != null && code == null) return null;
    return DshPairingInput(
      entry: DshPairingEntry(
        baseUri: Uri(scheme: uri.scheme, host: uri.host, port: uri.port, path: uri.path == '/' ? '' : uri.path),
        isTunnel: uri.scheme == 'https',
      ),
      code: code,
    );
  }

  static DshPairingEntry? _entryOf(String address) {
    final parsed = Uri.tryParse('http://$address');
    if (parsed == null || parsed.host.isEmpty || parsed.path.isNotEmpty || parsed.fragment.isNotEmpty) return null;
    if (parsed.userInfo.isNotEmpty) return null;
    if (!_isAddressHost(parsed.host)) return null;
    final tunnel = !_isLanHost(parsed.host);
    return DshPairingEntry(
      baseUri: Uri(scheme: tunnel ? 'https' : 'http', host: parsed.host, port: tunnel && !parsed.hasPort ? 443 : parsed.port),
      isTunnel: tunnel,
    );
  }

  /// A literal address, or a name that can only be a LAN name.
  static bool _isAddressHost(String host) => _isIp(host) || host == 'localhost' || host.contains('.');

  static bool _isLanHost(String host) => _isIp(host) || host == 'localhost' || host.endsWith('.local');

  static bool _isIp(String host) {
    if (host.contains(':')) return RegExp(r'^[0-9a-fA-F:]+$').hasMatch(host);
    final parts = host.split('.');
    if (parts.length != 4) return false;
    return parts.every((part) => part.isNotEmpty && int.tryParse(part) is int && int.parse(part) <= 255);
  }

  static String? _code(String raw) {
    final value = raw.trim().toUpperCase();
    if (value.length != codeLength) return null;
    for (final unit in value.codeUnits) {
      if (!codeAlphabet.codeUnits.contains(unit)) return null;
    }
    return value;
  }

  @override
  String toString() => 'DshPairingInput(${entry ?? 'no entry'}, ${code == null ? 'no code' : 'code'})';
}

/// What the pairing protocol concluded.
///
/// The three failures a person must be able to tell apart are [DshPairingCodeRejected]
/// (pair again), [DshPairingBanned] (wait the announced seconds) and
/// [DshPairingComputerFailed] (fix the PC). [DshPairingConnected] is the
/// success, [DshPairingNeedsCode] the "nothing wrong, just tell me the code"
/// answer, and [DshPairingRefused] the entry itself denying this phone.
sealed class DshPairingOutcome {
  const DshPairingOutcome();
}

/// The entry answered: either it needs no credential, or [session] holds the
/// ticket the exchange just minted.
final class DshPairingConnected extends DshPairingOutcome {
  const DshPairingConnected({required this.entry, this.session});

  final DshPairingEntry entry;

  /// `null` for an entry that is open (a LAN entry of a gateway with auth off
  /// or scoped to public only); otherwise the ticket in hand, whose
  /// [DshRemoteSession.expiresAt] is 30 days out. Keep it: it is what makes
  /// the next connection need no code.
  final DshRemoteSession? session;
}

/// The entry wants a credential and none usable was given: ask the person for
/// the 8-character code from the computer's screen.
final class DshPairingNeedsCode extends DshPairingOutcome {
  const DshPairingNeedsCode({required this.entry});

  final DshPairingEntry entry;
}

/// The credential was rejected: the code is stale or spent, or the stored
/// ticket is no longer accepted. Pair again from the computer's screen.
final class DshPairingCodeRejected extends DshPairingOutcome {
  const DshPairingCodeRejected({required this.message, this.ticketRejected = false});

  final String message;

  /// True when it was the stored 30-day ticket that stopped working, not a
  /// typed code: the person needs a whole new pairing, not a retyped digit.
  final bool ticketRejected;
}

/// The gateway refused the request itself (denied source, cross-site leg): the
/// entry is wrong for where this phone is, so a new code from the same entry
/// cannot help.
final class DshPairingRefused extends DshPairingOutcome {
  const DshPairingRefused({required this.statusCode, required this.message});

  final int statusCode;
  final String message;
}

/// The computer side could not serve the request: the gateway could not reach
/// `dsh web`, or that host refused the session the gateway presented. The
/// phone sees "unauthorized", but the fault and the fix are on the PC.
final class DshPairingComputerFailed extends DshPairingOutcome {
  const DshPairingComputerFailed({required this.statusCode, required this.message});

  final int statusCode;
  final String message;
}

/// Too many failed attempts: the gateway banned this client for
/// [remaining]. Do not retry before it lapses.
final class DshPairingBanned extends DshPairingOutcome {
  const DshPairingBanned({required this.remaining, required this.message});

  final Duration remaining;
  final String message;
}

/// Runs one pairing attempt against one entry: probe, exchange when needed,
/// confirm the ticket the exchange minted.
///
/// The gateway fixes the order. A navigation request to the entry root with no
/// cookie answers `200` when the entry is open for this phone (a LAN source of
/// a gateway that is not gated, or one scoped to public only) and `401` with
/// the login page when it wants a credential. Only a browser-navigation
/// exchange (`GET /?pair=1&auth=<code>`) is ever minted: a non-navigation
/// request is refused with `401` and no cookie. The exchange answers `302`
/// with `dsh_remote_session`, or `401` when the code does not match, or `429`
/// with `Retry-After` after five failures. Because the exchange is answered by
/// the gateway before anything reaches `dsh web`, a later `401` on the minted
/// ticket is the PC failing to mint its own session, not the code.
///
/// One instance remembers the ban the gateway announced, so a caller can show
/// a countdown instead of dialing a sleeping gateway again.
class DshPairingSession {
  DshPairingSession(this.entry, {DateTime Function()? now, this.timeout = const Duration(seconds: 10)})
    : _now = now ?? DateTime.now;

  final DshPairingEntry entry;
  final Duration timeout;

  final DateTime Function() _now;

  DateTime? _bannedUntil;
  String _bannedMessage = '';

  /// The ticket this attempt works with, once minted or handed in. Assign a
  /// stored one before [connect] and a paired entry needs no code until it
  /// lapses.
  DshRemoteSession? session;

  bool get isBanned {
    final until = _bannedUntil;
    return until != null && _now().isBefore(until);
  }

  /// Time left on the ban the gateway announced, or [Duration.zero].
  Duration get banRemaining {
    final until = _bannedUntil;
    if (until == null) return Duration.zero;
    final left = until.difference(_now());
    return left.isNegative ? Duration.zero : left;
  }

  /// Probes the entry, exchanges [code] when the entry wants one, and reports
  /// what happened. Throws [DshTransportException] when nothing answers at
  /// all: that is the network, not the pairing.
  Future<DshPairingOutcome> connect({String? code}) async {
    if (isBanned) return DshPairingBanned(remaining: banRemaining, message: _bannedMessage);

    // A lapsed ticket cannot work, and presenting it would only burn a
    // rate-limit slot. A live one is presented, which is what keeps a paired
    // entry paired for its whole 30 days.
    final stored = session;
    final usable = stored != null && !stored.isExpiredAt(_now()) ? stored : null;

    final probe = await _send(ticket: usable);
    if (_ban(probe) case final banned?) return banned;
    if (_open(probe)) return DshPairingConnected(entry: entry, session: usable);
    if (probe.statusCode != 401) return _refusal(probe);

    final wanted = code == null ? null : DshPairingInput.codeOf(code);
    if (wanted == null) return DshPairingNeedsCode(entry: entry);

    final exchanged = await _send(query: {'pair': '1', 'auth': wanted}, followRedirects: false);
    if (_ban(exchanged) case final banned?) return banned;
    if (exchanged.statusCode == 401) {
      return DshPairingCodeRejected(message: _staleCodeMessage, ticketRejected: usable != null);
    }
    if (exchanged.statusCode != 302 && exchanged.statusCode != 303) return _refusal(exchanged);

    final minted = _ticketOf(exchanged);
    if (minted == null) {
      throw const DshProtocolException('the pairing exchange redirected without a dsh_remote_session ticket');
    }
    session = minted;

    final check = await _send(ticket: minted);
    if (_ban(check) case final banned?) return banned;
    if (_open(check)) return DshPairingConnected(entry: entry, session: minted);
    // The gateway already accepted the code; a `401` here is the PC refusing
    // the session the gateway presented on its behalf.
    return _refusal(check, afterMint: true);
  }

  static const _staleCodeMessage = '配对码已失效或已被使用，请回到电脑上刷新配对码。';

  /// Whether this answer means "usable as-is": the Host served the entry.
  static bool _open(DshHttpResponse response) => response.statusCode == 200 || response.statusCode == 204;

  /// Reads the ban a `429` announces, remembers it on this session, and
  /// returns the outcome to report. Without `Retry-After` there is no number
  /// to report and no basis to invent one, so it is a refusal instead.
  DshPairingOutcome? _ban(DshHttpResponse response) {
    if (response.statusCode != 429) return null;
    final remaining = _retryAfterOf(response);
    if (remaining == null) {
      return const DshPairingRefused(statusCode: 429, message: '网关要求稍后再试，但没有给出等待秒数：请回电脑上重新取一次配对码。');
    }
    _bannedUntil = _now().add(remaining);
    _bannedMessage = '尝试次数过多，还需等待 ${remaining.inSeconds} 秒再配对。';
    return DshPairingBanned(remaining: remaining, message: _bannedMessage);
  }

  /// Everything that is neither "open", "needs a code", nor a mint result.
  /// [afterMint] is the case where the code was already accepted, so an
  /// unauthorized answer can only be the PC's own session failing.
  DshPairingOutcome _refusal(DshHttpResponse response, {bool afterMint = false}) {
    final status = response.statusCode;
    if (status == 401 && afterMint) {
      return const DshPairingComputerFailed(statusCode: 401, message: '电脑侧凭据铸造失败：请到电脑上确认 DSH 在运行、访问入口已启用。');
    }
    if (status == 502 || status == 504) {
      return DshPairingComputerFailed(statusCode: status, message: '网关连不上电脑上的 DSH，请确认它正在运行。');
    }
    if (status >= 500) {
      return DshPairingComputerFailed(statusCode: status, message: '电脑侧处理失败（$status），请到电脑上查看。');
    }
    return DshPairingRefused(statusCode: status, message: '入口拒绝了这次访问（$status）：请确认地址与网络后重新配对。');
  }

  Duration? _retryAfterOf(DshHttpResponse response) {
    final raw = response.headers['retry-after'];
    final seconds = raw == null ? null : int.tryParse(raw.trim());
    return seconds == null || seconds <= 0 ? null : Duration(seconds: seconds);
  }

  DshRemoteSession? _ticketOf(DshHttpResponse response) {
    for (final raw in response.setCookies) {
      final ticket = DshRemoteSession.fromSetCookie(raw, authority: entry.authority);
      if (ticket != null) return ticket;
    }
    return null;
  }

  /// One navigation-shaped request to the entry root. The connection applies
  /// its own `Host`/`Cookie`/`Origin` policy: a LAN entry sends no `Origin`,
  /// a tunnel entry sends its own.
  Future<DshHttpResponse> _send({
    Map<String, String>? query,
    DshRemoteSession? ticket,
    bool followRedirects = true,
  }) async {
    final connection = DshConnection(
      entry.baseUri,
      originHeader: entry.originHeader,
      remoteSession: ticket,
      connectTimeout: timeout,
      requestTimeout: timeout,
    );
    try {
      return await connection.getCapturing(
        '/',
        query: query,
        headers: {'Accept': 'text/html'},
        headerNames: const ['retry-after'],
        followRedirects: followRedirects,
        timeout: timeout,
      );
    } finally {
      connection.close(force: true);
    }
  }
}
