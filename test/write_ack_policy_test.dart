import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firewatch/firewatch.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

// ─── fakes ──────────────────────────────────────────────────────────────────
//
// fake_cloud_firestore acks every write instantly, so it cannot simulate the
// offline case this feature exists for: a write whose future NEVER completes
// (Firestore only completes write futures on the server ack). These minimal
// fakes return a shared Completer's future from every write so tests control
// exactly when (or whether) the "server" acks.

// ignore: subtype_of_sealed_class
class _HungDocRef implements DocumentReference<Map<String, dynamic>> {
  _HungDocRef(this.id, this._backend);

  @override
  final String id;
  final _HungBackend _backend;

  @override
  Future<void> set(Map<String, dynamic> data, [SetOptions? options]) {
    _backend.log.add('set:$id');
    return _backend.ack.future;
  }

  @override
  Future<void> update(Map<Object, Object?> data) {
    _backend.log.add('update:$id');
    return _backend.ack.future;
  }

  @override
  Future<void> delete() {
    _backend.log.add('delete:$id');
    return _backend.ack.future;
  }

  @override
  Future<DocumentSnapshot<Map<String, dynamic>>> get([GetOptions? options]) =>
      Future.error(Exception('offline: no server snapshot'));

  @override
  Stream<DocumentSnapshot<Map<String, dynamic>>> snapshots({
    bool includeMetadataChanges = false,
    ListenSource? source,
  }) => const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// Shared "server" state: one ack completer + a call log.
class _HungBackend {
  /// Complete to ack all issued writes; completeError to fail them.
  final Completer<void> ack = Completer<void>();

  /// One entry per write issued, e.g. `set:doc1`, `update:doc2`.
  final List<String> log = [];

  /// Monotonic counter for locally-minted doc IDs, shared across the
  /// collection-ref instances the builder hands out.
  int autoId = 0;
}

// ignore: subtype_of_sealed_class
class _HungCollectionRef implements CollectionReference<Map<String, dynamic>> {
  _HungCollectionRef(this.backend);

  final _HungBackend backend;

  @override
  DocumentReference<Map<String, dynamic>> doc([String? path]) =>
      _HungDocRef(path ?? 'local-${backend.autoId++}', backend);

  @override
  Future<DocumentReference<Map<String, dynamic>>> add(
    Map<String, dynamic> data,
  ) async {
    final ref = doc();
    await ref.set(data);
    return ref;
  }

  @override
  Query<Map<String, dynamic>> limit(int limit) => this;

  @override
  Future<QuerySnapshot<Map<String, dynamic>>> get([GetOptions? options]) =>
      Future.error(Exception('offline: no server snapshot'));

  @override
  Stream<QuerySnapshot<Map<String, dynamic>>> snapshots({
    bool includeMetadataChanges = false,
    ListenSource? source,
  }) => const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

// ignore: subtype_of_sealed_class
class _HungBatch implements WriteBatch {
  _HungBatch(this._backend);

  final _HungBackend _backend;

  @override
  void set<T>(DocumentReference<T> document, T data, [SetOptions? options]) {}

  @override
  void update<T>(DocumentReference<T> document, T data) {}

  @override
  void delete(DocumentReference<Object?> document) {}

  @override
  Future<void> commit() {
    _backend.log.add('commit');
    return _backend.ack.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _HungBatchFirestore implements FirebaseFirestore {
  _HungBatchFirestore(this.backend);

  final _HungBackend backend;

  @override
  WriteBatch batch() => _HungBatch(backend);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
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

const _grace = Duration(milliseconds: 50);
const _wellPastGrace = Duration(milliseconds: 250);

/// True once [future] has settled (successfully or with an error).
Future<bool> _settledWithin(Future<void> future, Duration window) async {
  var settled = false;
  unawaited(
    future.then((_) => settled = true, onError: (_) => settled = true),
  );
  await Future<void>.delayed(window);
  return settled;
}

void main() {
  group('WriteAckPolicy (unit)', () {
    test('null ackGrace returns the write future unchanged', () async {
      const policy = WriteAckPolicy();
      expect(policy.isGraced, isFalse);

      // Success passes through.
      expect(await policy.apply(Future.value(42), onTimeout: () => -1), 42);

      // Errors pass through.
      await expectLater(
        policy.applyVoid(Future.error(Exception('boom'))),
        throwsException,
      );

      // A never-completing write stays never-completing (legacy behavior).
      final hung = Completer<void>();
      expect(
        await _settledWithin(policy.applyVoid(hung.future), _wellPastGrace),
        isFalse,
      );
    });

    test('graced write resolves optimistically at the grace boundary',
        () async {
      const policy = WriteAckPolicy(ackGrace: _grace);
      expect(policy.isGraced, isTrue);

      final hung = Completer<void>();
      final sw = Stopwatch()..start();
      await policy.applyVoid(hung.future); // resolves — does not hang
      sw.stop();

      // Resolved at (not meaningfully before) the grace boundary.
      expect(sw.elapsed, greaterThanOrEqualTo(_grace));
    });

    test('error arriving BEFORE the grace still throws', () async {
      const policy = WriteAckPolicy(ackGrace: _wellPastGrace);
      final write = Completer<void>();
      final applied = policy.applyVoid(write.future);
      write.completeError(Exception('permission-denied'));
      await expectLater(applied, throwsException);
    });

    test(
        'error arriving AFTER the grace is swallowed when no handler is given '
        '(the future already resolved optimistically)', () async {
      const policy = WriteAckPolicy(ackGrace: _grace);
      final write = Completer<void>();

      await policy.applyVoid(write.future); // optimistic resolve at grace

      // Late server rejection: must not become an unhandled async error
      // (an unhandled zone error would fail this test).
      write.completeError(Exception('late rejection'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });

    test(
        'error arriving AFTER the grace is routed to onPostGraceError exactly '
        'once; returned future stays resolved; no unhandled zone error',
        () async {
      const policy = WriteAckPolicy(ackGrace: _grace);
      final write = Completer<void>();
      final reported = <Object>[];
      final stacks = <StackTrace>[];

      // Resolves optimistically at the grace — the late error must never
      // affect this future.
      await policy.applyVoid(
        write.future,
        onPostGraceError: (error, stackTrace) {
          reported.add(error);
          stacks.add(stackTrace);
        },
      );
      expect(reported, isEmpty); // nothing reported yet — write still pending

      final rejection = Exception('rules rejection after grace');
      write.completeError(rejection);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(reported, [rejection]); // exactly once, the original error
      expect(stacks, hasLength(1));
      // An unhandled zone error here would fail the test — none occurs.
    });

    test('error arriving BEFORE the grace throws and is NOT routed to '
        'onPostGraceError', () async {
      const policy = WriteAckPolicy(ackGrace: _wellPastGrace);
      final write = Completer<void>();
      final reported = <Object>[];

      final applied = policy.applyVoid(
        write.future,
        onPostGraceError: (error, stackTrace) => reported.add(error),
      );
      write.completeError(Exception('permission-denied'));
      await expectLater(applied, throwsException);

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(reported, isEmpty); // pre-grace errors throw, never double-report
    });

    test('null ackGrace never invokes onPostGraceError (errors propagate)',
        () async {
      const policy = WriteAckPolicy();
      final reported = <Object>[];

      await expectLater(
        policy.applyVoid(
          Future.error(Exception('boom')),
          onPostGraceError: (error, stackTrace) => reported.add(error),
        ),
        throwsException,
      );
      expect(reported, isEmpty);
    });

    test('post-grace ACK (success) does not invoke onPostGraceError', () async {
      const policy = WriteAckPolicy(ackGrace: _grace);
      final write = Completer<void>();
      final reported = <Object>[];

      await policy.applyVoid(
        write.future,
        onPostGraceError: (error, stackTrace) => reported.add(error),
      );
      write.complete(); // late ack, not an error
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(reported, isEmpty);
    });

    test('ack arriving before the grace resolves immediately', () async {
      const policy = WriteAckPolicy(ackGrace: Duration(seconds: 5));
      final write = Completer<void>()..complete();
      final sw = Stopwatch()..start();
      await policy.applyVoid(write.future);
      sw.stop();
      expect(sw.elapsed, lessThan(const Duration(seconds: 1)));
    });

    test('value equality, hashCode, toString', () {
      expect(
        const WriteAckPolicy(ackGrace: _grace),
        const WriteAckPolicy(ackGrace: _grace),
      );
      expect(const WriteAckPolicy(), isNot(const WriteAckPolicy(ackGrace: _grace)));
      expect(
        const WriteAckPolicy(ackGrace: _grace).hashCode,
        const WriteAckPolicy(ackGrace: _grace).hashCode,
      );
      expect(
        const WriteAckPolicy(ackGrace: _grace).toString(),
        contains('ackGrace'),
      );
    });
  });

  group('FirestoreCollectionRepository + WriteAckPolicy', () {
    FirestoreCollectionRepository<Item> buildRepo(
      _HungBackend backend, {
      WriteAckPolicy policy = const WriteAckPolicy(),
      FirebaseFirestore? firestore,
      FirewatchErrorHandler? onError,
    }) =>
        FirestoreCollectionRepository<Item>(
          firestore: firestore ?? FakeFirebaseFirestore(),
          fromJson: Item.fromJson,
          colRefBuilder: (fs, uid) => _HungCollectionRef(backend),
          maxRetries: 0,
          writeAckPolicy: policy,
          onError: onError,
        );

    test(
        'default policy preserves legacy behavior: offline write hangs and the '
        'Command silently drops the next invocation', () async {
      final backend = _HungBackend();
      final repo = buildRepo(backend);

      final first = repo.set.runAsync(Item(id: 'd1', n: 1));
      expect(await _settledWithin(first, _wellPastGrace), isFalse);

      // Second invocation is silently dropped — THIS is the session-bricking
      // bug the graced policy exists to fix.
      repo.set.run(Item(id: 'd2', n: 2));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(backend.log, ['set:d1']);

      backend.ack.complete(); // let the hung future settle before teardown
      await first;
      repo.dispose();
    });

    test('graced set Command resolves within the grace while offline',
        () async {
      final backend = _HungBackend();
      final repo =
          buildRepo(backend, policy: const WriteAckPolicy(ackGrace: _grace));

      final sw = Stopwatch()..start();
      await repo.set.runAsync(Item(id: 'd1', n: 1));
      sw.stop();

      expect(backend.log, ['set:d1']);
      expect(sw.elapsed, lessThan(_wellPastGrace));
      repo.dispose();
    });

    test(
        'BRICKING REGRESSION: Command is usable again after a graced timeout — '
        'second invocation executes against the still-hung backend', () async {
      final backend = _HungBackend();
      final repo =
          buildRepo(backend, policy: const WriteAckPolicy(ackGrace: _grace));

      await repo.patch.runAsync((id: 'd1', data: {'n': 1}));
      expect(repo.patch.isRunning.value, isFalse);

      // Backend still hung (never acked); the Command must run again anyway.
      await repo.patch.runAsync((id: 'd2', data: {'n': 2}));

      expect(backend.log, ['update:d1', 'update:d2']);
      repo.dispose();
    });

    test('create() returns a locally-minted ID within the grace while offline',
        () async {
      final backend = _HungBackend();
      final repo =
          buildRepo(backend, policy: const WriteAckPolicy(ackGrace: _grace));

      final sw = Stopwatch()..start();
      final id = await repo.create({'n': 7});
      sw.stop();

      expect(id, isNotEmpty);
      expect(backend.log, ['set:$id']); // data written at the minted doc
      expect(sw.elapsed, lessThan(_wellPastGrace));

      // Concurrent-safe and mint-unique: a second create gets a new ID.
      final id2 = await repo.create({'n': 8});
      expect(id2, isNot(id));
      repo.dispose();
    });

    test('add Command resolves with the minted ID under a grace offline',
        () async {
      final backend = _HungBackend();
      final repo =
          buildRepo(backend, policy: const WriteAckPolicy(ackGrace: _grace));

      final id = await repo.add.runAsync({'n': 3});
      expect(id, isNotNull);
      expect(backend.log, ['set:$id']);

      // And the add Command is reusable (not bricked).
      final id2 = await repo.add.runAsync({'n': 4});
      expect(id2, isNot(id));
      repo.dispose();
    });

    test('create() works end-to-end online (fake_cloud_firestore)', () async {
      final fs = FakeFirebaseFirestore();
      final repo = FirestoreCollectionRepository<Item>(
        firestore: fs,
        fromJson: Item.fromJson,
        colRefBuilder: (f, uid) => f.collection('items'),
      );

      final id = await repo.create({'n': 5});
      final snap = await fs.collection('items').doc(id).get();
      expect(snap.exists, isTrue);
      expect(snap.data()!['n'], 5);
      repo.dispose();
    });

    test('graced Direct writes resolve while offline', () async {
      final backend = _HungBackend();
      final repo =
          buildRepo(backend, policy: const WriteAckPolicy(ackGrace: _grace));

      await repo.setDirect(Item(id: 'a', n: 1));
      await repo.updateDirect(Item(id: 'b', n: 2));
      await repo.patchDirect((id: 'c', data: {'n': 3}));
      await repo.deleteDirect('d');
      final id = await repo.addDirect({'n': 4});

      expect(backend.log,
          ['set:a', 'update:b', 'update:c', 'delete:d', 'set:$id']);
      repo.dispose();
    });

    test('Direct write error BEFORE the grace still throws', () async {
      final backend = _HungBackend();
      final repo = buildRepo(backend,
          policy: const WriteAckPolicy(ackGrace: _wellPastGrace));

      final write = repo.setDirect(Item(id: 'a', n: 1));
      backend.ack.completeError(
          FirebaseException(plugin: 'firestore', code: 'permission-denied'));
      await expectLater(write, throwsA(isA<FirebaseException>()));
      repo.dispose();
    });

    test(
        "post-grace write error is routed to the repo's onError handler "
        'exactly once (late rules rejection stays observable)', () async {
      final backend = _HungBackend();
      final reported = <Object>[];
      final repo = buildRepo(
        backend,
        policy: const WriteAckPolicy(ackGrace: _grace),
        onError: (error, stackTrace) => reported.add(error),
      );

      await repo.setDirect(Item(id: 'a', n: 1)); // optimistic resolve
      expect(reported, isEmpty);

      final rejection = FirebaseException(
          plugin: 'firestore', code: 'permission-denied');
      backend.ack.completeError(rejection);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(reported, [rejection]);
      repo.dispose();
    });

    test('graced batch commit resolves while offline (batch Command reusable)',
        () async {
      final backend = _HungBackend();
      final repo = buildRepo(
        backend,
        policy: const WriteAckPolicy(ackGrace: _grace),
        firestore: _HungBatchFirestore(backend),
      );

      await repo.batchSet.runAsync([Item(id: 'a', n: 1), Item(id: 'b', n: 2)]);
      expect(backend.log, ['commit']);
      expect(repo.batchSet.isRunning.value, isFalse);

      // Not bricked: a second batch against the still-hung backend runs.
      await repo.batchSet.runAsync([Item(id: 'c', n: 3)]);
      expect(backend.log, ['commit', 'commit']);
      repo.dispose();
    });

    test('default-policy batch commit hangs offline (legacy behavior)',
        () async {
      final backend = _HungBackend();
      final repo = buildRepo(backend, firestore: _HungBatchFirestore(backend));

      final commit = repo.batchDelete.runAsync(['a']);
      expect(await _settledWithin(commit, _wellPastGrace), isFalse);

      backend.ack.complete();
      await commit;
      repo.dispose();
    });
  });

  group('FirestoreDocRepository + WriteAckPolicy', () {
    FirestoreDocRepository<Item> buildRepo(
      _HungBackend backend, {
      WriteAckPolicy policy = const WriteAckPolicy(),
      FirewatchErrorHandler? onError,
    }) =>
        FirestoreDocRepository<Item>(
          firestore: FakeFirebaseFirestore(),
          fromJson: Item.fromJson,
          docRefBuilder: (fs, uid) => _HungDocRef('the-doc', backend),
          writeAckPolicy: policy,
          onError: onError,
        );

    test('default policy: offline write hangs (legacy behavior)', () async {
      final backend = _HungBackend();
      final repo = buildRepo(backend);

      final write = repo.write.runAsync(Item(id: 'the-doc', n: 1));
      expect(await _settledWithin(write, _wellPastGrace), isFalse);

      backend.ack.complete();
      await write;
      repo.dispose();
    });

    test(
        'BRICKING REGRESSION: graced write Command recovers after timeout and '
        'runs again against the still-hung backend', () async {
      final backend = _HungBackend();
      final repo =
          buildRepo(backend, policy: const WriteAckPolicy(ackGrace: _grace));

      await repo.write.runAsync(Item(id: 'the-doc', n: 1));
      expect(repo.write.isRunning.value, isFalse);
      await repo.write.runAsync(Item(id: 'the-doc', n: 2));

      expect(backend.log, ['set:the-doc', 'set:the-doc']);
      repo.dispose();
    });

    test(
        "post-grace write error is routed to the doc repo's onError handler",
        () async {
      final backend = _HungBackend();
      final reported = <Object>[];
      final repo = buildRepo(
        backend,
        policy: const WriteAckPolicy(ackGrace: _grace),
        onError: (error, stackTrace) => reported.add(error),
      );

      await repo.write.runAsync(Item(id: 'the-doc', n: 1));
      expect(reported, isEmpty);

      final rejection = FirebaseException(
          plugin: 'firestore', code: 'permission-denied');
      backend.ack.completeError(rejection);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(reported, [rejection]);
      repo.dispose();
    });

    test('all graced doc write Commands + Direct writes resolve offline',
        () async {
      final backend = _HungBackend();
      final repo =
          buildRepo(backend, policy: const WriteAckPolicy(ackGrace: _grace));

      await repo.update.runAsync(Item(id: 'the-doc', n: 1));
      await repo.patch.runAsync({'n': 2});
      await repo.setFields.runAsync({'n': 3});
      await repo.delete.runAsync();
      await repo.writeDirect(Item(id: 'the-doc', n: 4));
      await repo.updateDirect(Item(id: 'the-doc', n: 5));
      await repo.patchDirect({'n': 6});
      await repo.setFieldsDirect({'n': 7});
      await repo.deleteDirect();

      expect(backend.log, [
        'update:the-doc', // update cmd
        'update:the-doc', // patch cmd
        'set:the-doc', // setFields cmd
        'delete:the-doc', // delete cmd
        'set:the-doc', // writeDirect
        'update:the-doc', // updateDirect
        'update:the-doc', // patchDirect
        'set:the-doc', // setFieldsDirect
        'delete:the-doc', // deleteDirect
      ]);
      repo.dispose();
    });
  });

  group('FirestoreCollectionGroupRepository + WriteAckPolicy', () {
    test(
        'BRICKING REGRESSION: graced group set Command recovers after timeout',
        () async {
      final backend = _HungBackend();
      final fs = FakeFirebaseFirestore();
      final authUid = ValueNotifier<String?>('u1');

      final repo = _HungDocGroupRepo(
        backend: backend,
        firestore: fs,
        authUid: authUid,
      );

      await repo.patch.runAsync((path: 'users/u1/tasks/t1', data: {'n': 1}));
      expect(repo.patch.isRunning.value, isFalse);
      await repo.patch.runAsync((path: 'users/u1/tasks/t2', data: {'n': 2}));

      expect(backend.log, ['update:t1', 'update:t2']);
      repo.dispose();
    });
  });
}

/// Group repo whose doc-path writes hit the hung backend. The group repo
/// resolves write targets via `fs.doc(path)`, so we intercept at the
/// FirebaseFirestore level.
class _HungDocGroupRepo extends FirestoreCollectionGroupRepository<Item> {
  _HungDocGroupRepo({
    required _HungBackend backend,
    required FirebaseFirestore firestore,
    required ValueNotifier<String?> authUid,
  }) : super(
          firestore: _HungDocFirestore(backend, firestore),
          fromJson: Item.fromJson,
          queryRefBuilder: (fs, uid) => _HungCollectionRef(backend),
          authUid: authUid,
          writeAckPolicy: const WriteAckPolicy(ackGrace: _grace),
        );
}

class _HungDocFirestore implements FirebaseFirestore {
  _HungDocFirestore(this._backend, this._inner);

  final _HungBackend _backend;
  final FirebaseFirestore _inner;

  @override
  DocumentReference<Map<String, dynamic>> doc(String documentPath) =>
      _HungDocRef(documentPath.split('/').last, _backend);

  @override
  WriteBatch batch() => _inner.batch();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
