import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firewatch/firewatch.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

// ignore: subtype_of_sealed_class
/// Models the real-device case the `initializeFromEmptyCache` option exists
/// for: the local cache holds nothing for this query (a brand-new query, e.g.
/// "today's entries" on the first open of a day), and the server is slow to
/// answer.
///
/// - `get(Source.cache)` resolves successfully with an empty snapshot (or
///   throws, when [cacheThrows] is set — the "no cache at all" case).
/// - `snapshots()` withholds every event until [releaseServer] is called, the
///   way Firestore withholds an empty from-cache first event for a query it
///   has never synced while it believes it is online. After release it
///   forwards the live server stream.
// ignore: must_be_immutable
class _SlowServerRef implements CollectionReference<Map<String, dynamic>> {
  _SlowServerRef({
    required this.server,
    required this.emptyCache,
    this.cacheThrows = false,
  });

  final CollectionReference<Map<String, dynamic>> server;
  final CollectionReference<Map<String, dynamic>> emptyCache;
  final bool cacheThrows;
  final Completer<void> _gate = Completer<void>();

  void releaseServer() => _gate.complete();

  @override
  Future<QuerySnapshot<Map<String, dynamic>>> get([GetOptions? options]) {
    if (options?.source == Source.cache) {
      if (cacheThrows) return Future.error(Exception('no cache'));
      return emptyCache.get();
    }
    return server.get(options);
  }

  @override
  Query<Map<String, dynamic>> limit(int limit) => this;

  @override
  Stream<QuerySnapshot<Map<String, dynamic>>> snapshots({
    bool includeMetadataChanges = false,
    ListenSource? source,
  }) => _gate.future.asStream().asyncExpand((_) => server.snapshots());

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class Item implements JsonModel {
  @override
  final String id;
  final int n;
  Item({required this.id, required this.n});

  factory Item.fromJson(Map<String, dynamic> m) =>
      Item(id: m['id'] as String, n: (m['n'] as num?)?.toInt() ?? 0);

  @override
  Map<String, dynamic> toJson() => {'n': n};
}

const _tick = Duration(milliseconds: 20);

void main() {
  late FakeFirebaseFirestore fs;

  setUp(() async {
    fs = FakeFirebaseFirestore();
    final col = fs.collection('users/u1/items');
    for (var i = 0; i < 2; i++) {
      await col.doc('d$i').set({'n': i});
    }
  });

  _SlowServerRef slowRef({
    bool cacheThrows = false,
    String path = 'users/u1/items',
  }) => _SlowServerRef(
    server: fs.collection(path),
    emptyCache: fs.collection('nothing-cached'),
    cacheThrows: cacheThrows,
  );

  FirestoreCollectionRepository<Item> repoOn(
    _SlowServerRef ref, {
    required bool initializeFromEmptyCache,
  }) => FirestoreCollectionRepository<Item>(
    firestore: fs,
    fromJson: Item.fromJson,
    colRefBuilder: (f, uid) => ref,
    authUid: ValueNotifier<String?>('u1'),
    initializeFromEmptyCache: initializeFromEmptyCache,
  );

  group('initializeFromEmptyCache: true', () {
    test('a successful empty cache read marks the repo initialized before the '
        'server answers, with isLoading still true', () async {
      final ref = slowRef();
      final repo = repoOn(ref, initializeFromEmptyCache: true);

      await Future<void>.delayed(_tick);

      expect(repo.value, isEmpty);
      expect(repo.hasInitialized.value, isTrue);
      expect(repo.isFromCache.value, isTrue);
      // Still waiting on the server: not "confirmed empty".
      expect(repo.isLoading.value, isTrue);
      expect(repo.isInitializing, isFalse);
      expect(repo.showEmpty, isFalse);

      repo.dispose();
    });

    test('the server answer then replaces the cached-empty state', () async {
      final ref = slowRef();
      final repo = repoOn(ref, initializeFromEmptyCache: true);
      await Future<void>.delayed(_tick);
      expect(repo.hasInitialized.value, isTrue);

      ref.releaseServer();
      await Future<void>.delayed(_tick);

      expect(repo.value.map((e) => e.id), ['d0', 'd1']);
      expect(repo.isLoading.value, isFalse);
      expect(repo.hasInitialized.value, isTrue);
      expect(repo.showEmpty, isFalse);

      repo.dispose();
    });

    test('a server-confirmed empty result settles showEmpty', () async {
      final ref = slowRef(path: 'users/u1/none');
      final repo = repoOn(ref, initializeFromEmptyCache: true);
      await Future<void>.delayed(_tick);
      expect(repo.showEmpty, isFalse); // cached-empty is not confirmed

      ref.releaseServer();
      await Future<void>.delayed(_tick);

      expect(repo.value, isEmpty);
      expect(repo.isLoading.value, isFalse);
      expect(repo.showEmpty, isTrue);

      repo.dispose();
    });

    test('a failed cache read does not mark the repo initialized', () async {
      final ref = slowRef(cacheThrows: true);
      final repo = repoOn(ref, initializeFromEmptyCache: true);

      await Future<void>.delayed(_tick);

      expect(repo.hasInitialized.value, isFalse);
      expect(repo.isInitializing, isTrue);

      repo.dispose();
    });

    test(
      'a dependency change re-initializes from the new empty cache',
      () async {
        final ref = slowRef();
        final day = ValueNotifier<int>(0);
        final repo = FirestoreCollectionRepository<Item>(
          firestore: fs,
          fromJson: Item.fromJson,
          colRefBuilder: (f, uid) => ref,
          authUid: ValueNotifier<String?>('u1'),
          dependencies: [day],
          initializeFromEmptyCache: true,
        );
        await Future<void>.delayed(_tick);
        expect(repo.hasInitialized.value, isTrue);

        final seen = <bool>[];
        repo.hasInitialized.addListener(
          () => seen.add(repo.hasInitialized.value),
        );
        day.value = 1;
        await Future<void>.delayed(_tick);

        // The hard swap resets, then the empty cache read restores it.
        expect(seen, [false, true]);
        expect(repo.isLoading.value, isTrue);

        repo.dispose();
      },
    );

    test('works on the collection-group repository too', () async {
      final ref = slowRef();
      final repo = FirestoreCollectionGroupRepository<Item>(
        firestore: fs,
        fromJson: Item.fromJson,
        queryRefBuilder: (f, uid) => ref,
        authUid: ValueNotifier<String?>('u1'),
        initializeFromEmptyCache: true,
      );

      await Future<void>.delayed(_tick);

      expect(repo.hasInitialized.value, isTrue);
      expect(repo.isLoading.value, isTrue);

      repo.dispose();
    });
  });

  group('initializeFromEmptyCache: false (default)', () {
    test('an empty cache read leaves hasInitialized false until the server '
        'answers', () async {
      final ref = slowRef();
      final repo = repoOn(ref, initializeFromEmptyCache: false);

      await Future<void>.delayed(_tick);

      expect(repo.hasInitialized.value, isFalse);
      expect(repo.isInitializing, isTrue);

      ref.releaseServer();
      await Future<void>.delayed(_tick);

      expect(repo.hasInitialized.value, isTrue);
      expect(repo.value.length, 2);

      repo.dispose();
    });
  });
}
