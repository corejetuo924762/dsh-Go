// Paired host persistence: entry, name and ticket in the shared encrypted
// store under new keys only, and the same computer keyed one way whichever
// spelling its address is written in.

import 'package:dsh_app/remote/paired/paired_host_store.dart';
import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

const _ticket = 'v1.1750000000000.1752592000000.c2lnbmF0dXJl';

void main() {
  late MemorySecretStore secrets;
  late PairedHostStore store;

  setUp(() {
    secrets = MemorySecretStore();
    store = PairedHostStore(secrets);
  });

  DshPairingEntry entryOf(String link) => DshPairingInput.tryParse(link)!.entry!;

  test('saves, reads back and removes entry, name and ticket', () async {
    final entry = entryOf('http://192.168.1.5:3088/?auth=ABCD2345');
    final id = pairedHostId(entry.authority);
    final session = DshRemoteSession.tryParse(_ticket, authority: entry.authority)!;

    await store.save(PairedHostRecord(id: id, entry: entry, name: '书房'));
    await store.saveSession(id, session);

    final record = (await store.loadAll()).single;
    expect(record.id, id);
    expect(record.entry.baseUri.toString(), 'http://192.168.1.5:3088');
    expect(record.entry.isTunnel, isFalse);
    expect(record.name, '书房');
    expect((await store.loadSession(id))!.value, _ticket);

    await store.remove(id);
    expect(await store.loadAll(), isEmpty);
    expect(await store.loadSession(id), isNull);
    expect(secrets.values, isEmpty, reason: 'nothing left behind, index included');
  });

  test('every key is a new paired.* family, never an existing one', () async {
    final entry = entryOf('http://192.168.1.5:3088/?auth=ABCD2345');
    final id = pairedHostId(entry.authority);
    await store.save(PairedHostRecord(id: id, entry: entry, name: '书房'));
    await store.saveSession(id, DshRemoteSession.tryParse(_ticket, authority: entry.authority)!);

    expect(
      secrets.values.keys,
      everyElement(startsWith('paired.')),
      reason: 'SSH, forum and workshop keys share this store and stay untouched',
    );
  });

  test('one computer keyed one way whichever spelling its address takes', () async {
    for (final spelling in [
      'http://192.168.1.5:3088/?auth=ABCD2345',
      'http://192.168.1.5:3088',
      'HTTP://192.168.1.5:3088/',
      '192.168.1.5:3088 ABCD2345',
    ]) {
      final entry = entryOf(spelling);
      expect(entry.authority, '192.168.1.5:3088', reason: spelling);
      expect(entry.baseUri.toString(), 'http://192.168.1.5:3088', reason: spelling);
      expect(pairedHostId(entry.authority), pairedHostId('192.168.1.5:3088'), reason: spelling);
    }
    // A tunnel entry keeps its https leg and its own Origin.
    final tunnel = entryOf('https://unset-lineup.trycloudflare.com/?auth=ABCD2345');
    expect(tunnel.isTunnel, isTrue);
    expect(tunnel.originHeader, 'https://unset-lineup.trycloudflare.com');
  });

  test('a record restored from a sloppy old spelling loads canonical', () async {
    // As an earlier build might have written it: upper-case host and a slash.
    final id = pairedHostId('192.168.1.5:3088');
    secrets.values[PairedHostStore.indexKey] = '["$id"]';
    secrets.values[PairedHostStore.entryKey(id)] =
        '{"baseUri":"HTTP://192.168.1.5:3088/","isTunnel":false}';

    final record = (await store.loadAll()).single;
    expect(record.entry.baseUri.toString(), 'http://192.168.1.5:3088');
    expect(record.entry.authority, '192.168.1.5:3088');
  });

  test('an unreadable record is skipped without hiding the rest', () async {
    final good = entryOf('http://192.168.1.5:3088/?auth=ABCD2345');
    final goodId = pairedHostId(good.authority);
    await store.save(PairedHostRecord(id: goodId, entry: good, name: '书房'));
    secrets.values[PairedHostStore.indexKey] = '["broken","$goodId"]';
    secrets.values[PairedHostStore.entryKey('broken')] = 'not json';

    final records = await store.loadAll();
    expect(records.single.id, goodId);
  });
}
