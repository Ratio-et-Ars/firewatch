import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firewatch/firewatch.dart';
import 'package:flutter/foundation.dart';
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
}
