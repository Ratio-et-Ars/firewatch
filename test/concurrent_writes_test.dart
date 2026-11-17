import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:command_it/command_it.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firewatch/firewatch.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

// ─── fakes ──────────────────────────────────────────────────────────────────
//
// A Firestore whose writes behave like the real SDK's: each write lands in the
// local cache at once (listeners and reads see it), but its future completes
// only when the "server" acknowledges it. Offline, that is never.
// [_Server.ackAll] / [_Server.rejectNext] play the server.

class _Server {
  /// One entry per write issued, in call order, e.g. `set:a`, `commit`.
  final List<String> log = [];

  /// Ack futures not yet settled, oldest first.
  final List<Completer<void>> pending = [];

  /// Errors to fail the next writes with (consumed in order on ack).
  final List<Object> rejections = [];

  Future<void> queue(Future<void> local, String entry) {
    log.add(entry);
    unawaited(local);
    final ack = Completer<void>();
    pending.add(ack);
    return ack.future;
  }

  /// Acks every pending write (failing the first ones with [rejections]).
  void ackAll() {
    final now = List.of(pending);
    pending.clear();
    for (final c in now) {
      if (rejections.isNotEmpty) {
        c.completeError(rejections.removeAt(0));
      } else {
        c.complete();
      }
    }
  }

  /// Acks only the oldest pending write.
  void ackOldest() => pending.removeAt(0).complete();
}

class _OfflineFirestore extends Fake implements FirebaseFirestore {
  _OfflineFirestore(this.server);

  final _Server server;
  final FakeFirebaseFirestore local = FakeFirebaseFirestore();

  @override
  CollectionReference<Map<String, dynamic>> collection(String path) =>
      _OfflineCollection(local.collection(path), server);

  @override
  Query<Map<String, dynamic>> collectionGroup(String collectionPath) =>
      local.collectionGroup(collectionPath);

  @override
  DocumentReference<Map<String, dynamic>> doc(String path) =>
      _OfflineDoc(local.doc(path), server);

  @override
  WriteBatch batch() => _OfflineBatch(local.batch(), server);

  Future<Map<String, Map<String, dynamic>>> docs(String path) async {
    final snap = await local.collection(path).get();
    return {for (final d in snap.docs) d.id: d.data()};
  }
}

DocumentReference<T> _unwrap<T>(DocumentReference<T> ref) => ref is _OfflineDoc
    ? (ref as _OfflineDoc)._inner as DocumentReference<T>
    : ref;

class _OfflineBatch extends Fake implements WriteBatch {
  _OfflineBatch(this._inner, this._server);

  final WriteBatch _inner;
  final _Server _server;

  @override
  void delete(DocumentReference<Object?> document) =>
      _inner.delete(_unwrap(document));

  @override
  void set<T>(DocumentReference<T> document, T data, [SetOptions? options]) =>
      _inner.set(_unwrap(document), data, options);

  @override
  void update<T>(DocumentReference<T> document, T data) =>
      _inner.update(_unwrap(document), data);

  @override
  Future<void> commit() => _server.queue(_inner.commit(), 'commit');
}

// ignore: subtype_of_sealed_class
class _OfflineCollection extends Fake
    implements CollectionReference<Map<String, dynamic>> {
  _OfflineCollection(this._inner, this._server);

  final CollectionReference<Map<String, dynamic>> _inner;
  final _Server _server;

  @override
  String get id => _inner.id;

  @override
  String get path => _inner.path;

  @override
  DocumentReference<Map<String, dynamic>> doc([String? path]) =>
      _OfflineDoc(_inner.doc(path), _server);

  @override
  Query<Map<String, dynamic>> limit(int limit) => _inner.limit(limit);

  @override
  Future<QuerySnapshot<Map<String, dynamic>>> get([GetOptions? options]) =>
      _inner.get(options);

  @override
  Stream<QuerySnapshot<Map<String, dynamic>>> snapshots({
    bool includeMetadataChanges = false,
    ListenSource source = ListenSource.defaultSource,
  }) => _inner.snapshots(includeMetadataChanges: includeMetadataChanges);
}

// ignore: subtype_of_sealed_class
class _OfflineDoc extends Fake
    implements DocumentReference<Map<String, dynamic>> {
  _OfflineDoc(this._inner, this._server);

  final DocumentReference<Map<String, dynamic>> _inner;
  final _Server _server;

  @override
  String get id => _inner.id;

  @override
  String get path => _inner.path;

  @override
  Future<DocumentSnapshot<Map<String, dynamic>>> get([GetOptions? options]) =>
      _inner.get(options);

  @override
  Stream<DocumentSnapshot<Map<String, dynamic>>> snapshots({
    bool includeMetadataChanges = false,
    ListenSource source = ListenSource.defaultSource,
  }) => _inner.snapshots(includeMetadataChanges: includeMetadataChanges);

  @override
  Future<void> set(Map<String, dynamic> data, [SetOptions? options]) =>
      _server.queue(_inner.set(data, options), 'set:$id');

  @override
  Future<void> update(Map<Object, Object?> data) =>
      _server.queue(_inner.update(data), 'update:$id');

  @override
  Future<void> delete() => _server.queue(_inner.delete(), 'delete:$id');
}

class Item implements JsonModel {
  Item({required this.id, required this.n});

  @override
  final String id;
  final int n;

  factory Item.fromJson(Map<String, dynamic> m) =>
      Item(id: m['id'] as String, n: (m['n'] as num?)?.toInt() ?? 0);

  @override
  Map<String, dynamic> toJson() => {'n': n};
}

/// Lets queued writes, Command bookkeeping and fake listeners run.
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 20));

/// True once [future] has settled (successfully or with an error).
Future<bool> _settledWithin(Future<void> future, Duration window) async {
  var settled = false;
  unawaited(future.then((_) => settled = true, onError: (_) => settled = true));
  await Future<void>.delayed(window);
  return settled;
}

void main() {
  late _Server server;
  late _OfflineFirestore fs;

  setUp(() {
    server = _Server();
    fs = _OfflineFirestore(server);
  });

  FirestoreCollectionRepository<Item> collectionRepo({
    WriteAckPolicy policy = const WriteAckPolicy(),
  }) => FirestoreCollectionRepository<Item>(
    firestore: fs,
    fromJson: Item.fromJson,
    colRefBuilder: (fs, uid) => fs.collection('items'),
    maxRetries: 0,
    writeAckPolicy: policy,
  );

  Future<void> seed(List<String> ids) async {
    for (final id in ids) {
      await fs.local.collection('items').doc(id).set({'n': 0});
    }
  }

  group('FirestoreCollectionRepository: offline, writes never ack', () {
    test(
      'set x3 in a row: all three reach Firestore and the local cache',
      () async {
        final repo = collectionRepo();
        repo.set(Item(id: 'milk', n: 1));
        repo.set(Item(id: 'eggs', n: 2));
        repo.set(Item(id: 'bread', n: 3));
        await _settle();

        expect(server.log, ['set:milk', 'set:eggs', 'set:bread']);
        expect(
          (await fs.docs('items')).keys,
          unorderedEquals(['milk', 'eggs', 'bread']),
        );
        expect(
          repo.value.map((i) => i.id),
          unorderedEquals(['milk', 'eggs', 'bread']),
        );
        expect(
          repo.set.isRunning.value,
          isTrue,
          reason: 'writes are still waiting for the server',
        );

        server.ackAll();
        await _settle();
        expect(repo.set.isRunning.value, isFalse);
        repo.dispose();
      },
    );

    test(
      'set calls separated in time all land (first one never acks)',
      () async {
        final repo = collectionRepo();
        repo.set(Item(id: 'milk', n: 1));
        await _settle();
        repo.set(Item(id: 'eggs', n: 2));
        await _settle();
        repo.set.run(Item(id: 'bread', n: 3));
        await _settle();

        expect(server.log, ['set:milk', 'set:eggs', 'set:bread']);
        expect((await fs.docs('items')).length, 3);
        server.ackAll();
        await _settle();
        repo.dispose();
      },
    );

    test('patch x3 all land', () async {
      await seed(['a', 'b', 'c']);
      final repo = collectionRepo();
      repo.patch((id: 'a', data: {'n': 1}));
      repo.patch((id: 'b', data: {'n': 2}));
      repo.patch((id: 'c', data: {'n': 3}));
      await _settle();

      expect(server.log, ['update:a', 'update:b', 'update:c']);
      expect(await fs.docs('items'), {
        'a': {'n': 1},
        'b': {'n': 2},
        'c': {'n': 3},
      });
      server.ackAll();
      await _settle();
      repo.dispose();
    });

    test('update x3 all land', () async {
      await seed(['a', 'b', 'c']);
      final repo = collectionRepo();
      repo.update(Item(id: 'a', n: 1));
      repo.update(Item(id: 'b', n: 2));
      repo.update(Item(id: 'c', n: 3));
      await _settle();

      expect(server.log, ['update:a', 'update:b', 'update:c']);
      expect((await fs.docs('items'))['c'], {'n': 3});
      server.ackAll();
      await _settle();
      repo.dispose();
    });

    test('delete x3 all land', () async {
      await seed(['a', 'b', 'c', 'keep']);
      final repo = collectionRepo();
      repo.delete('a');
      repo.delete('b');
      repo.delete('c');
      await _settle();

      expect(server.log, ['delete:a', 'delete:b', 'delete:c']);
      expect((await fs.docs('items')).keys, ['keep']);
      server.ackAll();
      await _settle();
      repo.dispose();
    });

    test(
      'add x3 all land, and each runAsync resolves with its own id',
      () async {
        final repo = collectionRepo();
        final f1 = repo.add.runAsync({'n': 1});
        final f2 = repo.add.runAsync({'n': 2});
        repo.add({'n': 3});
        await _settle();

        expect(server.log, hasLength(3));
        final local = await fs.docs('items');
        expect(local.values.map((d) => d['n']), unorderedEquals([1, 2, 3]));

        server.ackAll();
        final id1 = await f1;
        final id2 = await f2;
        expect(local[id1], {'n': 1});
        expect(local[id2], {'n': 2});
        await _settle();
        expect(repo.add.isRunning.value, isFalse);
        repo.dispose();
      },
    );

    test('every batch Command accepts back-to-back calls', () async {
      await seed(['p1', 'p2', 'u1', 'u2', 'd1', 'd2']);
      final repo = collectionRepo();
      repo.batchAdd([
        {'n': 10},
      ]);
      repo.batchAdd([
        {'n': 11},
      ]);
      repo.batchSet([Item(id: 's1', n: 1)]);
      repo.batchSet([Item(id: 's2', n: 2)]);
      repo.batchPatch([
        (id: 'p1', data: {'n': 5}),
      ]);
      repo.batchPatch([
        (id: 'p2', data: {'n': 6}),
      ]);
      repo.batchUpdate([Item(id: 'u1', n: 7)]);
      repo.batchUpdate([Item(id: 'u2', n: 8)]);
      repo.batchDelete(['d1']);
      repo.batchDelete(['d2']);
      await _settle();

      expect(server.log, List.filled(10, 'commit'));
      final local = await fs.docs('items');
      expect(local.containsKey('d1') || local.containsKey('d2'), isFalse);
      expect(local['s1'], {'n': 1});
      expect(local['s2'], {'n': 2});
      expect(local['p1'], {'n': 5});
      expect(local['p2'], {'n': 6});
      expect(local['u1'], {'n': 7});
      expect(local['u2'], {'n': 8});
      expect(
        local.values.where((d) => d['n'] == 10 || d['n'] == 11),
        hasLength(2),
      );
      server.ackAll();
      await _settle();
      repo.dispose();
    });

    test(
      'a batch over the 500-op chunk limit sends every chunk offline',
      () async {
        final repo = collectionRepo();
        final items = [for (var i = 0; i < 501; i++) Item(id: 'x$i', n: i)];
        repo.batchSet(items);
        repo.batchDelete(['x500']);
        await _settle();

        // Both chunks of the first call go out before the second call's batch,
        // so the delete of x500 is ordered after its set.
        expect(server.log, ['commit', 'commit', 'commit']);
        final local = await fs.docs('items');
        expect(local, hasLength(500));
        expect(local.containsKey('x500'), isFalse);
        server.ackAll();
        await _settle();
        repo.dispose();
      },
    );

    test('writes to the same document keep their call order', () async {
      final repo = collectionRepo();
      repo.set(Item(id: 'a', n: 1));
      repo.patch((id: 'a', data: {'n': 2}));
      repo.set(Item(id: 'a', n: 3));
      repo.patch((id: 'a', data: {'n': 4}));
      await _settle();

      expect(server.log, ['set:a', 'update:a', 'set:a', 'update:a']);
      expect((await fs.docs('items'))['a'], {'n': 4});
      server.ackAll();
      await _settle();
      repo.dispose();
    });

    test(
      'graced policy: writes inside the grace window are not dropped',
      () async {
        final repo = collectionRepo(
          policy: const WriteAckPolicy(ackGrace: Duration(milliseconds: 50)),
        );
        repo.set(Item(id: 'a', n: 1));
        repo.set(Item(id: 'b', n: 2));
        repo.set(Item(id: 'c', n: 3));
        await Future<void>.delayed(const Duration(milliseconds: 200));

        expect(server.log, ['set:a', 'set:b', 'set:c']);
        expect(repo.set.isRunning.value, isFalse);
        repo.dispose();
      },
    );

    test('disposing with writes still pending is clean', () async {
      final seen = <Object?>[];
      final previous = Command.globalExceptionHandler;
      Command.globalExceptionHandler = (e, _) => seen.add(e.error);
      addTearDown(() => Command.globalExceptionHandler = previous);

      final repo = collectionRepo();
      repo.set(Item(id: 'a', n: 1));
      repo.set(Item(id: 'b', n: 2));
      await _settle();
      repo.dispose();
      final late1 = Exception('late rejection 1');
      server.rejections.addAll([late1, Exception('late rejection 2')]);
      server.ackAll();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(server.log, ['set:a', 'set:b']);
      // The execution already running reports its error the way a plain
      // command_it Command does after dispose; the queued one is not
      // reported, and neither escapes as an unhandled error.
      expect(seen, [late1]);
    });
  });

  group('after dispose', () {
    test('write Commands send nothing, and runAsync still completes', () async {
      final repo = collectionRepo();
      repo.dispose();
      repo.set(Item(id: 'a', n: 1));
      expect(await repo.add.runAsync({'n': 1}), isNull);
      await _settle();
      expect(server.log, isEmpty);
    });
  });

  group('FirestoreCollectionRepository: online, slow ack', () {
    test(
      'a second call during the first ack round-trip is not dropped',
      () async {
        final repo = collectionRepo();
        final first = repo.set.runAsync(Item(id: 'a', n: 1));
        await _settle();
        final second = repo.set.runAsync(Item(id: 'b', n: 2));
        await _settle();

        expect(server.log, ['set:a', 'set:b']);
        expect(repo.set.isRunning.value, isTrue);

        server.ackOldest();
        await first;
        expect(
          await _settledWithin(second, const Duration(milliseconds: 30)),
          isFalse,
          reason: 'runAsync waits for its own write, not the first one',
        );
        expect(
          repo.set.isRunning.value,
          isTrue,
          reason: 'a write is still pending',
        );

        server.ackOldest();
        await second;
        await _settle();
        expect(repo.set.isRunning.value, isFalse);
        repo.dispose();
      },
    );

    test(
      'each failed write reports its own error; the others still land',
      () async {
        final repo = collectionRepo();
        final errors = <Object?>[];
        final params = <Object?>[];
        repo.set.errors.listen((e, _) {
          if (e != null) {
            errors.add(e.error);
            params.add(e.paramData?.id);
          }
        });
        final denied = FirebaseException(
          plugin: 'cloud_firestore',
          code: 'permission-denied',
        );
        final denied2 = FirebaseException(
          plugin: 'cloud_firestore',
          code: 'not-found',
        );
        server.rejections.addAll([denied, denied2]);

        repo.set(Item(id: 'a', n: 1));
        repo.set(Item(id: 'b', n: 2));
        repo.set(Item(id: 'c', n: 3));
        await _settle();
        server.ackAll();
        await _settle();

        expect(server.log, ['set:a', 'set:b', 'set:c']);
        expect(errors, [denied, denied2]);
        expect(params, ['a', 'b']);
        expect(repo.set.isRunning.value, isFalse);
        repo.dispose();
      },
    );

    test('runAsync throws its own write error, not a neighbour\'s', () async {
      final repo = collectionRepo();
      repo.set.errors.listen((_, _) {}); // a local handler
      final denied = FirebaseException(
        plugin: 'cloud_firestore',
        code: 'permission-denied',
      );
      server.rejections.add(denied);

      final first = repo.set.runAsync(Item(id: 'a', n: 1));
      final second = repo.set.runAsync(Item(id: 'b', n: 2));
      server.ackAll();

      await expectLater(first, throwsA(denied));
      await expectLater(second, completes);
      repo.dispose();
    });

    test(
      'errors reach Command.globalExceptionHandler for every failed write',
      () async {
        final seen = <Object>[];
        final previous = Command.globalExceptionHandler;
        Command.globalExceptionHandler = (e, _) => seen.add(e.error);
        addTearDown(() => Command.globalExceptionHandler = previous);

        final repo = collectionRepo();
        final e1 = Exception('one');
        final e2 = Exception('two');
        server.rejections.addAll([e1, e2]);
        repo.delete('a');
        repo.delete('b');
        await _settle();
        server.ackAll();
        await _settle();

        expect(seen, [e1, e2]);
        repo.dispose();
      },
    );

    test('a write that throws while being built is reported and does not '
        'block the writes after it', () async {
      final auth = ValueNotifier<String?>(null);
      final repo = FirestoreCollectionRepository<Item>(
        firestore: fs,
        fromJson: Item.fromJson,
        colRefBuilder: (fs, uid) => fs.collection('items'),
        authUid: auth,
        maxRetries: 0,
      );
      final errors = <Object>[];
      repo.set.errors.listen((e, _) {
        if (e != null) errors.add(e.error);
      });

      repo.set(Item(id: 'a', n: 1)); // signed out: throws StateError
      auth.value = 'u1';
      repo.set(Item(id: 'b', n: 2));
      await _settle();

      expect(errors.single, isA<StateError>());
      expect(server.log, ['set:b']);
      server.ackAll();
      await _settle();
      expect(repo.set.isRunning.value, isFalse);
      repo.dispose();
    });
  });

  group('FirestoreDocRepository: offline, writes never ack', () {
    FirestoreDocRepository<Item> docRepo() => FirestoreDocRepository<Item>(
      firestore: fs,
      fromJson: Item.fromJson,
      docRefBuilder: (fs, uid) => fs.doc('settings/me'),
    );

    Future<Map<String, dynamic>?> stored() async =>
        (await fs.local.doc('settings/me').get()).data();

    test('write x3 all land, last one wins', () async {
      final repo = docRepo();
      repo.write(Item(id: 'me', n: 1));
      repo.write(Item(id: 'me', n: 2));
      repo.write(Item(id: 'me', n: 3));
      await _settle();

      expect(server.log, ['set:me', 'set:me', 'set:me']);
      expect(await stored(), {'n': 3});
      expect(repo.value?.n, 3);
      server.ackAll();
      await _settle();
      repo.dispose();
    });

    test('update, patch, setFields x2 each, in call order', () async {
      await fs.local.doc('settings/me').set({'n': 0});
      final repo = docRepo();
      repo.update(Item(id: 'me', n: 1));
      repo.update(Item(id: 'me', n: 2));
      repo.patch({'n': 3});
      repo.patch({'m': 4});
      repo.setFields({'k': 5});
      repo.setFields({'n': 6});
      await _settle();

      expect(server.log, [
        'update:me',
        'update:me',
        'update:me',
        'update:me',
        'set:me',
        'set:me',
      ]);
      expect(await stored(), {'n': 6, 'm': 4, 'k': 5});
      server.ackAll();
      await _settle();
      repo.dispose();
    });

    test('delete (no-param Command) x2 then write all land', () async {
      await fs.local.doc('settings/me').set({'n': 0});
      final repo = docRepo();
      repo.delete();
      repo.delete();
      repo.write(Item(id: 'me', n: 9));
      repo.delete();
      await _settle();

      expect(server.log, ['delete:me', 'delete:me', 'set:me', 'delete:me']);
      expect(await stored(), isNull);
      expect(repo.delete.isRunning.value, isTrue);
      server.ackAll();
      await _settle();
      expect(repo.delete.isRunning.value, isFalse);
      repo.dispose();
    });
  });

  group('FirestoreCollectionGroupRepository: offline, writes never ack', () {
    test('set, update, patch, delete x2 each all land', () async {
      await fs.local.doc('users/u1/tasks/t9').set({'n': 0});
      final repo = FirestoreCollectionGroupRepository<Item>(
        firestore: fs,
        fromJson: Item.fromJson,
        queryRefBuilder: (fs, uid) => fs.collectionGroup('tasks'),
      );
      repo.set((path: 'users/u1/tasks/t1', model: Item(id: 't1', n: 1)));
      repo.set((path: 'users/u1/tasks/t2', model: Item(id: 't2', n: 2)));
      repo.update((path: 'users/u1/tasks/t1', model: Item(id: 't1', n: 3)));
      repo.update((path: 'users/u1/tasks/t2', model: Item(id: 't2', n: 4)));
      repo.patch((path: 'users/u1/tasks/t1', data: {'n': 5}));
      repo.patch((path: 'users/u1/tasks/t2', data: {'n': 6}));
      repo.delete('users/u1/tasks/t9');
      repo.delete('users/u1/tasks/t1');
      await _settle();

      expect(server.log, [
        'set:t1',
        'set:t2',
        'update:t1',
        'update:t2',
        'update:t1',
        'update:t2',
        'delete:t9',
        'delete:t1',
      ]);
      expect(await fs.docs('users/u1/tasks'), {
        't2': {'n': 6},
      });
      server.ackAll();
      await _settle();
      repo.dispose();
    });
  });
}
