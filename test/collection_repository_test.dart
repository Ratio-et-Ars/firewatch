import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firewatch/firewatch.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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
  });
}
