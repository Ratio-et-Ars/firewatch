import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firewatch/firewatch.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class Foo implements JsonModel {
  @override
  final String id;
  final String name;
  Foo({required this.id, required this.name});

  factory Foo.fromJson(Map<String, dynamic> m) =>
      Foo(id: m['id'] as String, name: m['name'] as String? ?? '');

  @override
  Map<String, dynamic> toJson() => {'name': name};
}

void main() {
  test('doc repo attaches on auth and streams updates', () async {
    final fs = FakeFirebaseFirestore();
    final authUid = ValueNotifier<String?>(null);

    final repo = FirestoreDocRepository<Foo>(
      firestore: fs,
      fromJson: Foo.fromJson,
      docRefBuilder: (f, uid) => f.doc('foos/$uid'),
      authUid: authUid,
      subscribe: true,
    );

    // Initially signed out
    expect(repo.value, isNull);
    expect(repo.isLoading.value, isTrue);

    // Sign in
    authUid.value = 'u1';
    await fs.doc('foos/u1').set({'name': 'Alice'});

    // Allow stream to deliver
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(repo.value?.id, 'u1');
    expect(repo.value?.name, 'Alice');
    expect(repo.isLoading.value, isFalse);

    // Update doc, repo should reflect
    await fs.doc('foos/u1').update({'name': 'Alice B'});
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(repo.value?.name, 'Alice B');

    // Sign out clears state
    authUid.value = null;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(repo.value, isNull);
  });
}
