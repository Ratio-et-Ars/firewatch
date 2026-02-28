import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firewatch/firewatch.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// ignore: subtype_of_sealed_class
/// A minimal CollectionReference that emits errors on [snapshots] and [get].
/// Used to test onError stream callbacks in the repository.
class _ErrorCollectionRef implements CollectionReference<Map<String, dynamic>> {
  @override
  Stream<QuerySnapshot<Map<String, dynamic>>> snapshots({
    bool includeMetadataChanges = false,
    ListenSource? source,
  }) =>
      Stream.error(Exception('Simulated stream error'));

  @override
  Future<QuerySnapshot<Map<String, dynamic>>> get([GetOptions? options]) =>
      Future.error(Exception('Simulated get error'));

  @override
  Query<Map<String, dynamic>> limit(int limit) => this;

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

class ItemWithParent implements JsonModel {
  @override
  final String id;
  final int n;
  final String? parentId;
  ItemWithParent({required this.id, required this.n, this.parentId});

  factory ItemWithParent.fromJson(Map<String, dynamic> m) => ItemWithParent(
    id: m['id'] as String,
    n: (m['n'] as num?)?.toInt() ?? 0,
    parentId: m['parentId'] as String?,
  );

  @override
  Map<String, dynamic> toJson() => {'n': n};
}

void main() {
  test('collection repo paginates with live window', () async {
    final fs = FakeFirebaseFirestore();
    final authUid = ValueNotifier<String?>(null);

    final repo = FirestoreCollectionRepository<Item>(
      firestore: fs,
      fromJson: Item.fromJson,
      colRefBuilder: (f, uid) => f.collection('users/$uid/items'),
      authUid: authUid,
      subscribe: true,
      pageSize: 3,
    );

    // Sign in
    authUid.value = 'u1';

    // Seed 5 docs
    final col = fs.collection('users/u1/items');
    for (var i = 0; i < 5; i++) {
      await col.add({'n': i});
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));

    // First page
    expect(repo.value.length, 3);
    expect(repo.hasMore.value, isTrue);

    // Grow window
    await repo.loadMore();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(repo.value.length, 5);
    expect(repo.hasMore.value, isFalse);
  });

  test(
    'dependency rebuild is latest-wins (no stale query/subscription)',
    () async {
      final fs = FakeFirebaseFirestore();
      final authUid = ValueNotifier<String?>(null);
      final dep = ValueNotifier<int>(0);

      final repo = FirestoreCollectionRepository<Item>(
        firestore: fs,
        fromJson: Item.fromJson,
        colRefBuilder: (f, uid) => f.collection('users/$uid/items'),
        authUid: authUid,
        dependencies: [dep],
        subscribe: true,
        pageSize: 50,
      );

      // Sign in
      authUid.value = 'u1';

      // Seed 5 docs (n=0..4)
      final col = fs.collection('users/u1/items');
      for (var i = 0; i < 5; i++) {
        await col.add({'n': i});
      }

      // Provide an explicit query mutator that reads dep.value at rebuild time.
      repo.setQuery(
        (base) => base.where('n', isGreaterThanOrEqualTo: dep.value),
      );

      // Let first attach settle.
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // Rapid dep changes: we want the *last* one to win.
      dep.value = 3; // should show [3,4]
      dep.value = 1; // should show [1,2,3,4]  <-- latest must win

      await Future<void>.delayed(const Duration(milliseconds: 25));

      final ns = repo.value.map((e) => e.n).toList()..sort();
      expect(ns, [1, 2, 3, 4]);
    },
  );

  test('dep change before auth is applied after auth arrives', () async {
    final fs = FakeFirebaseFirestore();
    final authUid = ValueNotifier<String?>(null);
    final dep = ValueNotifier<DateTime>(DateTime(2020, 1, 1));

    final repo = FirestoreCollectionRepository<Item>(
      firestore: fs,
      fromJson: Item.fromJson,
      colRefBuilder: (f, uid) => f.collection('users/$uid/items'),
      authUid: authUid,
      dependencies: [dep],
      subscribe: true,
      pageSize: 50,
      queryBuilder:
          (q) => q.where(
            'n',
            isGreaterThanOrEqualTo: dep.value.year,
          ), // silly but deterministic
    );

    // Change dep while signed out
    dep.value = DateTime(2022, 1, 1);

    // Sign in
    authUid.value = 'u1';

    final col = fs.collection('users/u1/items');
    for (var i = 0; i < 5; i++) {
      await col.add({'n': i + 2020}); // 2020..2024
    }

    await Future<void>.delayed(const Duration(milliseconds: 10));

    // Expect filter uses 2022 (dep changed before auth)
    final ns = repo.value.map((e) => e.n).toList()..sort();
    expect(ns, [2022, 2023, 2024]);

    repo.dispose();
  });

  test('collection repo CRUD commands work when authenticated', () async {
    final fs = FakeFirebaseFirestore();
    final authUid = ValueNotifier<String?>('u1');

    final repo = FirestoreCollectionRepository<Item>(
      firestore: fs,
      fromJson: Item.fromJson,
      colRefBuilder: (f, uid) => f.collection('users/$uid/items'),
      authUid: authUid,
      subscribe: true,
      pageSize: 50,
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));

    // Add a document
    final docId = await repo.add.runAsync({'n': 42});
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(docId, isNotNull);
    expect(repo.value.length, 1);
    expect(repo.value.first.n, 42);

    // Patch the document
    await repo.patch.runAsync((id: docId!, data: {'n': 99}));
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(repo.value.first.n, 99);

    // Delete the document
    await repo.delete.runAsync(docId);
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(repo.value, isEmpty);

    repo.dispose();
  });

  test('collection repo per-item notifiers reflect updates and deletions',
      () async {
    final fs = FakeFirebaseFirestore();
    final authUid = ValueNotifier<String?>('u1');

    final repo = FirestoreCollectionRepository<Item>(
      firestore: fs,
      fromJson: Item.fromJson,
      colRefBuilder: (f, uid) => f.collection('users/$uid/items'),
      authUid: authUid,
      subscribe: true,
      pageSize: 50,
    );

    final col = fs.collection('users/u1/items');
    final ref = await col.add({'n': 1});
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final notifier = repo.notifierFor(ref.id);
    expect(notifier.value?.n, 1);

    // Update the doc
    await ref.update({'n': 2});
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(notifier.value?.n, 2);

    // Delete the doc — notifier should be nulled
    await ref.delete();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(notifier.value, isNull);

    repo.dispose();
  });

  test('collection repo dispose removes listeners', () async {
    final fs = FakeFirebaseFirestore();
    final authUid = ValueNotifier<String?>('u1');

    final repo = FirestoreCollectionRepository<Item>(
      firestore: fs,
      fromJson: Item.fromJson,
      colRefBuilder: (f, uid) => f.collection('users/$uid/items'),
      authUid: authUid,
      subscribe: true,
      pageSize: 50,
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));

    repo.dispose();

    // Changing auth after dispose should not throw
    authUid.value = 'u2';
    await Future<void>.delayed(const Duration(milliseconds: 10));

    // Value should remain as-is
    expect(repo.value, isEmpty);
  });

  test('collection repo resets pagination on query change', () async {
    final fs = FakeFirebaseFirestore();
    final authUid = ValueNotifier<String?>('u1');

    final repo = FirestoreCollectionRepository<Item>(
      firestore: fs,
      fromJson: Item.fromJson,
      colRefBuilder: (f, uid) => f.collection('users/$uid/items'),
      authUid: authUid,
      subscribe: true,
      pageSize: 2,
    );

    // Seed 4 docs
    final col = fs.collection('users/u1/items');
    for (var i = 0; i < 4; i++) {
      await col.add({'n': i});
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(repo.value.length, 2); // first page
    expect(repo.hasMore.value, isTrue);

    // Load more to inflate the limit
    await repo.loadMore();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(repo.value.length, 4);

    // Change query — should reset pagination
    repo.setQuery((base) => base.where('n', isGreaterThan: 0));
    await Future<void>.delayed(const Duration(milliseconds: 10));

    // Should be back to first page (2 items), not 4
    expect(repo.value.length, 2);
    expect(repo.hasMore.value, isTrue);

    repo.dispose();
  });

  test('collection repo one-shot mode (subscribe: false)', () async {
    final fs = FakeFirebaseFirestore();
    final authUid = ValueNotifier<String?>('u1');

    final col = fs.collection('users/u1/items');
    for (var i = 0; i < 3; i++) {
      await col.add({'n': i});
    }

    final repo = FirestoreCollectionRepository<Item>(
      firestore: fs,
      fromJson: Item.fromJson,
      colRefBuilder: (f, uid) => f.collection('users/$uid/items'),
      authUid: authUid,
      subscribe: false,
      pageSize: 50,
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(repo.value.length, 3);
    expect(repo.isLoading.value, isFalse);
    expect(repo.hasInitialized.value, isTrue);

    repo.dispose();
  });

  test('collection repo one-shot with pagination and loadMore', () async {
    final fs = FakeFirebaseFirestore();
    final authUid = ValueNotifier<String?>('u1');

    final col = fs.collection('users/u1/items');
    for (var i = 0; i < 5; i++) {
      await col.add({'n': i});
    }

    final repo = FirestoreCollectionRepository<Item>(
      firestore: fs,
      fromJson: Item.fromJson,
      colRefBuilder: (f, uid) => f.collection('users/$uid/items'),
      authUid: authUid,
      subscribe: false,
      pageSize: 3,
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(repo.value.length, 3);
    expect(repo.hasMore.value, isTrue);

    // loadMore triggers _resizeWindow in one-shot mode
    await repo.loadMore();
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(repo.value.length, 5);
    expect(repo.hasMore.value, isFalse);

    repo.dispose();
  });

  test('collection repo set and update commands work', () async {
    final fs = FakeFirebaseFirestore();
    final authUid = ValueNotifier<String?>('u1');

    final repo = FirestoreCollectionRepository<Item>(
      firestore: fs,
      fromJson: Item.fromJson,
      colRefBuilder: (f, uid) => f.collection('users/$uid/items'),
      authUid: authUid,
      subscribe: true,
      pageSize: 50,
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));

    // Use set to create a doc with a known ID
    await repo.set.runAsync(Item(id: 'item1', n: 10));
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(repo.value.length, 1);
    expect(repo.value.first.n, 10);

    // Use update to change it
    await repo.update.runAsync(Item(id: 'item1', n: 20));
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(repo.value.first.n, 20);

    repo.dispose();
  });

  test('collection repo isInitializing, isRefreshing, showEmpty getters',
      () async {
    final fs = FakeFirebaseFirestore();
    final authUid = ValueNotifier<String?>('u1');

    final repo = FirestoreCollectionRepository<Item>(
      firestore: fs,
      fromJson: Item.fromJson,
      colRefBuilder: (f, uid) => f.collection('users/$uid/items'),
      authUid: authUid,
      subscribe: true,
      pageSize: 50,
    );

    // Before initialization completes
    expect(repo.isInitializing, isTrue);
    expect(repo.isRefreshing, isFalse);
    expect(repo.showEmpty, isFalse);

    await Future<void>.delayed(const Duration(milliseconds: 10));

    // After initialization with empty collection
    expect(repo.isInitializing, isFalse);
    expect(repo.isRefreshing, isFalse);
    expect(repo.showEmpty, isTrue);

    // Add a doc so it's no longer empty
    await fs.collection('users/u1/items').add({'n': 1});
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(repo.showEmpty, isFalse);

    repo.dispose();
  });

  test('collection repo refresh re-fetches data', () async {
    final fs = FakeFirebaseFirestore();
    final authUid = ValueNotifier<String?>('u1');

    final col = fs.collection('users/u1/items');
    await col.add({'n': 1});

    final repo = FirestoreCollectionRepository<Item>(
      firestore: fs,
      fromJson: Item.fromJson,
      colRefBuilder: (f, uid) => f.collection('users/$uid/items'),
      authUid: authUid,
      subscribe: true,
      pageSize: 50,
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(repo.value.length, 1);

    // Add another doc and refresh
    await col.add({'n': 2});
    await repo.refresh();
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(repo.value.length, 2);

    repo.dispose();
  });

  test('collection repo resetPages resets to first page', () async {
    final fs = FakeFirebaseFirestore();
    final authUid = ValueNotifier<String?>('u1');

    final col = fs.collection('users/u1/items');
    for (var i = 0; i < 5; i++) {
      await col.add({'n': i});
    }

    final repo = FirestoreCollectionRepository<Item>(
      firestore: fs,
      fromJson: Item.fromJson,
      colRefBuilder: (f, uid) => f.collection('users/$uid/items'),
      authUid: authUid,
      subscribe: true,
      pageSize: 2,
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(repo.value.length, 2);

    // Load more pages
    await repo.loadMore();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(repo.value.length, 4);

    // Reset pages
    await repo.resetPages();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(repo.value.length, 2);
    expect(repo.hasMore.value, isTrue);

    repo.dispose();
  });

  test('collection repo paginate: false returns all results', () async {
    final fs = FakeFirebaseFirestore();
    final authUid = ValueNotifier<String?>('u1');

    final col = fs.collection('users/u1/items');
    for (var i = 0; i < 10; i++) {
      await col.add({'n': i});
    }

    final repo = FirestoreCollectionRepository<Item>(
      firestore: fs,
      fromJson: Item.fromJson,
      colRefBuilder: (f, uid) => f.collection('users/$uid/items'),
      authUid: authUid,
      subscribe: true,
      pageSize: 3,
      paginate: false,
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));

    // All 10 docs returned despite pageSize: 3
    expect(repo.value.length, 10);

    repo.dispose();
  });

  test('collection repo works without authUid (public collection)', () async {
    final fs = FakeFirebaseFirestore();

    final col = fs.collection('publicItems');
    for (var i = 0; i < 3; i++) {
      await col.add({'n': i});
    }

    final repo = FirestoreCollectionRepository<Item>(
      firestore: fs,
      fromJson: Item.fromJson,
      colRefBuilder: (f, uid) => f.collection('publicItems'),
      // no authUid — public collection
      subscribe: true,
      pageSize: 50,
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(repo.value.length, 3);
    expect(repo.isLoading.value, isFalse);
    expect(repo.hasInitialized.value, isTrue);

    repo.dispose();
  });

  test('collection repo CRUD works without authUid', () async {
    final fs = FakeFirebaseFirestore();

    final repo = FirestoreCollectionRepository<Item>(
      firestore: fs,
      fromJson: Item.fromJson,
      colRefBuilder: (f, uid) => f.collection('publicItems'),
      // no authUid — public collection
      subscribe: true,
      pageSize: 50,
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));

    // Add
    final docId = await repo.add.runAsync({'n': 42});
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(docId, isNotNull);
    expect(repo.value.length, 1);
    expect(repo.value.first.n, 42);

    // Patch
    await repo.patch.runAsync((id: docId!, data: {'n': 99}));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(repo.value.first.n, 99);

    // Delete
    await repo.delete.runAsync(docId);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(repo.value, isEmpty);

    repo.dispose();
  });

  test('collection repo one-shot signed out returns empty', () async {
    final fs = FakeFirebaseFirestore();
    final authUid = ValueNotifier<String?>(null);

    final repo = FirestoreCollectionRepository<Item>(
      firestore: fs,
      fromJson: Item.fromJson,
      colRefBuilder: (f, uid) => f.collection('users/$uid/items'),
      authUid: authUid,
      subscribe: false,
      pageSize: 50,
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(repo.value, isEmpty);
    expect(repo.hasInitialized.value, isTrue);
    expect(repo.isLoading.value, isFalse);

    repo.dispose();
  });

  test('onError callback sets isLoading false on stream error (_swap)',
      () async {
    final fs = FakeFirebaseFirestore();

    final repo = FirestoreCollectionRepository<Item>(
      firestore: fs,
      fromJson: Item.fromJson,
      colRefBuilder: (f, uid) => _ErrorCollectionRef(),
      subscribe: true,
      pageSize: 50,
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(repo.isLoading.value, isFalse);
    expect(repo.hasInitialized.value, isTrue);

    repo.dispose();
  });

  test('onError callback sets isLoading false on stream error (_resizeWindow)',
      () async {
    final fs = FakeFirebaseFirestore();
    final authUid = ValueNotifier<String?>('u1');

    final col = fs.collection('users/u1/items');
    for (var i = 0; i < 3; i++) {
      await col.add({'n': i});
    }

    var useError = false;
    final repo = FirestoreCollectionRepository<Item>(
      firestore: fs,
      fromJson: Item.fromJson,
      colRefBuilder: (f, uid) =>
          useError ? _ErrorCollectionRef() : f.collection('users/$uid/items'),
      authUid: authUid,
      subscribe: true,
      pageSize: 2,
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(repo.value.length, 2);

    // Switch to error-producing ref, then loadMore triggers _resizeWindow
    useError = true;
    await repo.loadMore();
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(repo.isLoading.value, isFalse);

    repo.dispose();
  });

  test('parentId is injected from parent document reference', () async {
    final fs = FakeFirebaseFirestore();
    final authUid = ValueNotifier<String?>('u1');

    final col = fs.collection('users/u1/tasks');
    await col.doc('t1').set({'n': 1});
    await col.doc('t2').set({'n': 2});

    final repo = FirestoreCollectionRepository<ItemWithParent>(
      firestore: fs,
      fromJson: ItemWithParent.fromJson,
      colRefBuilder: (f, uid) => f.collection('users/$uid/tasks'),
      authUid: authUid,
      subscribe: true,
      pageSize: 50,
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(repo.value.length, 2);
    for (final item in repo.value) {
      expect(item.parentId, 'u1');
    }

    repo.dispose();
  });

  test('CRUD commands error when auth-gated and signed out', () async {
    final fs = FakeFirebaseFirestore();
    final authUid = ValueNotifier<String?>(null);

    final repo = FirestoreCollectionRepository<Item>(
      firestore: fs,
      fromJson: Item.fromJson,
      colRefBuilder: (f, uid) => f.collection('users/$uid/items'),
      authUid: authUid,
      subscribe: true,
      pageSize: 50,
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));

    // Register local error listeners so command_it routes errors locally.
    repo.add.errors.addListener(() {});
    repo.set.errors.addListener(() {});
    repo.update.errors.addListener(() {});
    repo.patch.errors.addListener(() {});
    repo.delete.errors.addListener(() {});

    repo.add.run({'n': 1});
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(repo.add.errors.value?.error, isA<StateError>());

    repo.set.run(Item(id: 'x', n: 1));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(repo.set.errors.value?.error, isA<StateError>());

    repo.update.run(Item(id: 'x', n: 1));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(repo.update.errors.value?.error, isA<StateError>());

    repo.patch.run((id: 'x', data: {'n': 1}));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(repo.patch.errors.value?.error, isA<StateError>());

    repo.delete.run('x');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(repo.delete.errors.value?.error, isA<StateError>());

    repo.dispose();
  });
}
