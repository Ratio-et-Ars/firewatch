import 'package:command_it/command_it.dart';
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

    // Initially signed out — nothing to load.
    expect(repo.value, isNull);
    expect(repo.isLoading.value, isFalse);

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

    repo.dispose();
  });

  test('doc repo clears value when document is deleted', () async {
    final fs = FakeFirebaseFirestore();
    final authUid = ValueNotifier<String?>('u1');

    await fs.doc('foos/u1').set({'name': 'Alice'});

    final repo = FirestoreDocRepository<Foo>(
      firestore: fs,
      fromJson: Foo.fromJson,
      docRefBuilder: (f, uid) => f.doc('foos/$uid'),
      authUid: authUid,
      subscribe: true,
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(repo.value?.name, 'Alice');

    // Delete the document
    await fs.doc('foos/u1').delete();
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(repo.value, isNull);
    expect(repo.isLoading.value, isFalse);

    repo.dispose();
  });

  test('doc repo write command works when authenticated', () async {
    final fs = FakeFirebaseFirestore();
    final authUid = ValueNotifier<String?>('u1');

    final repo = FirestoreDocRepository<Foo>(
      firestore: fs,
      fromJson: Foo.fromJson,
      docRefBuilder: (f, uid) => f.doc('foos/$uid'),
      authUid: authUid,
      subscribe: true,
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));

    // Write a document
    await repo.write.runAsync(Foo(id: 'u1', name: 'Bob'));
    await Future<void>.delayed(const Duration(milliseconds: 10));

    // Verify it was written to Firestore
    final snap = await fs.doc('foos/u1').get();
    expect(snap.data()?['name'], 'Bob');

    // Verify repo picked up the change via stream
    expect(repo.value?.name, 'Bob');

    repo.dispose();
  });

  test('doc repo patch command works when authenticated', () async {
    final fs = FakeFirebaseFirestore();
    final authUid = ValueNotifier<String?>('u1');

    await fs.doc('foos/u1').set({'name': 'Alice'});

    final repo = FirestoreDocRepository<Foo>(
      firestore: fs,
      fromJson: Foo.fromJson,
      docRefBuilder: (f, uid) => f.doc('foos/$uid'),
      authUid: authUid,
      subscribe: true,
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(repo.value?.name, 'Alice');

    // Patch the document
    await repo.patch.runAsync({'name': 'Alice B'});
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(repo.value?.name, 'Alice B');

    repo.dispose();
  });

  test('doc repo CRUD throws when not authenticated', () async {
    final fs = FakeFirebaseFirestore();
    final authUid = ValueNotifier<String?>(null);

    final repo = FirestoreDocRepository<Foo>(
      firestore: fs,
      fromJson: Foo.fromJson,
      docRefBuilder: (f, uid) => f.doc('foos/$uid'),
      authUid: authUid,
      subscribe: true,
    );

    // Commands use _docOrThrow internally which throws StateError
    // when not authenticated. Verify the write command propagates errors.
    Object? caughtError;
    Command.globalExceptionHandler = (error, _) {
      caughtError = error.error;
    };

    repo.write.run(Foo(id: 'x', name: 'fail'));
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(caughtError, isA<StateError>());

    Command.globalExceptionHandler = null;
    repo.dispose();
  });

  test('doc repo dispose removes auth listener', () async {
    final fs = FakeFirebaseFirestore();
    final authUid = ValueNotifier<String?>(null);

    final repo = FirestoreDocRepository<Foo>(
      firestore: fs,
      fromJson: Foo.fromJson,
      docRefBuilder: (f, uid) => f.doc('foos/$uid'),
      authUid: authUid,
      subscribe: true,
    );

    repo.dispose();

    // Changing auth after dispose should not throw
    authUid.value = 'u1';
    await Future<void>.delayed(const Duration(milliseconds: 10));

    // Value should remain null since repo is disposed
    expect(repo.value, isNull);
  });

  test('doc repo handles rapid auth changes without stale data', () async {
    final fs = FakeFirebaseFirestore();
    final authUid = ValueNotifier<String?>(null);

    await fs.doc('foos/u1').set({'name': 'User1'});
    await fs.doc('foos/u2').set({'name': 'User2'});

    final repo = FirestoreDocRepository<Foo>(
      firestore: fs,
      fromJson: Foo.fromJson,
      docRefBuilder: (f, uid) => f.doc('foos/$uid'),
      authUid: authUid,
      subscribe: true,
    );

    // Rapid auth changes — only last should win
    authUid.value = 'u1';
    authUid.value = 'u2';

    await Future<void>.delayed(const Duration(milliseconds: 25));

    expect(repo.value?.name, 'User2');

    repo.dispose();
  });
}
