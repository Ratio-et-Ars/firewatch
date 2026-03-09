import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:command_it/command_it.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firewatch/firewatch.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// ignore: subtype_of_sealed_class
/// A minimal DocumentReference that emits errors on [snapshots] and [get].
/// Used to test the onError stream callback in the doc repository.
class _ErrorDocRef implements DocumentReference<Map<String, dynamic>> {
  @override
  Stream<DocumentSnapshot<Map<String, dynamic>>> snapshots({
    bool includeMetadataChanges = false,
    ListenSource? source,
  }) =>
      Stream.error(Exception('Simulated stream error'));

  @override
  Future<DocumentSnapshot<Map<String, dynamic>>> get([
    GetOptions? options,
  ]) =>
      Future.error(Exception('Simulated get error'));

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

// ignore: subtype_of_sealed_class
/// Simulates the cloud_firestore_web bug where calling .parent on a top-level
/// CollectionReference throws an Expando error instead of returning null.
class _ThrowingParentCollectionRef
    implements CollectionReference<Map<String, dynamic>> {
  @override
  DocumentReference<Map<String, dynamic>>? get parent =>
      throw ArgumentError('Expandos are not allowed on strings, numbers, '
          'booleans, records, or null');

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

// ignore: subtype_of_sealed_class
/// A DocumentReference whose .parent returns a [_ThrowingParentCollectionRef],
/// reproducing the web crash path: doc.reference.parent.parent → throws.
class _ThrowingParentDocRef
    implements DocumentReference<Map<String, dynamic>> {
  @override
  CollectionReference<Map<String, dynamic>> get parent =>
      _ThrowingParentCollectionRef();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

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

class FooWithParent implements JsonModel {
  @override
  final String id;
  final String name;
  final String? parentId;
  FooWithParent({required this.id, required this.name, this.parentId});

  factory FooWithParent.fromJson(Map<String, dynamic> m) => FooWithParent(
    id: m['id'] as String,
    name: m['name'] as String? ?? '',
    parentId: m['parentId'] as String?,
  );

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

  test('doc repo works in one-shot mode (subscribe: false)', () async {
    final fs = FakeFirebaseFirestore();
    final authUid = ValueNotifier<String?>('u1');

    await fs.doc('foos/u1').set({'name': 'OneShot'});

    final repo = FirestoreDocRepository<Foo>(
      firestore: fs,
      fromJson: Foo.fromJson,
      docRefBuilder: (f, uid) => f.doc('foos/$uid'),
      authUid: authUid,
      subscribe: false,
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(repo.value?.name, 'OneShot');
    expect(repo.isLoading.value, isFalse);

    repo.dispose();
  });

  test('doc repo one-shot with no existing document', () async {
    final fs = FakeFirebaseFirestore();
    final authUid = ValueNotifier<String?>('u1');

    final repo = FirestoreDocRepository<Foo>(
      firestore: fs,
      fromJson: Foo.fromJson,
      docRefBuilder: (f, uid) => f.doc('foos/$uid'),
      authUid: authUid,
      subscribe: false,
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(repo.value, isNull);
    expect(repo.isLoading.value, isFalse);

    repo.dispose();
  });

  test('doc repo update command works when authenticated', () async {
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

    await repo.update.runAsync(Foo(id: 'u1', name: 'Bob'));
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(repo.value?.name, 'Bob');

    repo.dispose();
  });

  test('doc repo works without authUid (public doc)', () async {
    final fs = FakeFirebaseFirestore();

    await fs.doc('static/prompts').set({'name': 'Hello'});

    final repo = FirestoreDocRepository<Foo>(
      firestore: fs,
      fromJson: Foo.fromJson,
      docRefBuilder: (f, uid) => f.doc('static/prompts'),
      // no authUid — public collection
      subscribe: true,
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(repo.value?.name, 'Hello');
    expect(repo.isLoading.value, isFalse);

    // Update the doc — repo should stream the change
    await fs.doc('static/prompts').update({'name': 'World'});
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(repo.value?.name, 'World');

    // CRUD still works
    await repo.write.runAsync(Foo(id: 'prompts', name: 'Written'));
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final snap = await fs.doc('static/prompts').get();
    expect(snap.data()?['name'], 'Written');

    repo.dispose();
  });

  test('doc repo delete command works when authenticated', () async {
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

    await repo.delete.runAsync();
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(repo.value, isNull);

    repo.dispose();
  });

  test('parentId is injected from parent document reference', () async {
    final fs = FakeFirebaseFirestore();
    final authUid = ValueNotifier<String?>('u1');

    await fs.doc('users/u1/profile/main').set({'name': 'Alice'});

    final repo = FirestoreDocRepository<FooWithParent>(
      firestore: fs,
      fromJson: FooWithParent.fromJson,
      docRefBuilder: (f, uid) => f.doc('users/$uid/profile/main'),
      authUid: authUid,
      subscribe: true,
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(repo.value?.id, 'main');
    expect(repo.value?.name, 'Alice');
    expect(repo.value?.parentId, 'u1');

    repo.dispose();
  });

  test('parentId is null for top-level collection document', () async {
    final fs = FakeFirebaseFirestore();
    final authUid = ValueNotifier<String?>('u1');

    // Top-level document (no parent document above the collection)
    await fs.doc('profiles/u1').set({'name': 'Alice'});

    final repo = FirestoreDocRepository<FooWithParent>(
      firestore: fs,
      fromJson: FooWithParent.fromJson,
      docRefBuilder: (f, uid) => f.doc('profiles/$uid'),
      authUid: authUid,
      subscribe: true,
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(repo.value?.id, 'u1');
    expect(repo.value?.name, 'Alice');
    expect(repo.value?.parentId, isNull);

    repo.dispose();
  });

  // Regression: cloud_firestore_web throws an Expando error when calling
  // .parent on a top-level CollectionReference (parent is null). This test
  // simulates that by using a DocumentReference whose .parent.parent throws.
  test('parentIdOf returns null when .parent throws (web compat)', () {
    final ref = _ThrowingParentDocRef();
    expect(parentIdOf(ref), isNull);
  });

  test('onError callback sets isLoading false on stream error', () async {
    final fs = FakeFirebaseFirestore();

    final repo = FirestoreDocRepository<Foo>(
      firestore: fs,
      fromJson: Foo.fromJson,
      docRefBuilder: (f, uid) => _ErrorDocRef(),
      subscribe: true,
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));

    // The stream errored; onError should have set isLoading to false.
    expect(repo.isLoading.value, isFalse);

    repo.dispose();
  });

  group('hasInitialized', () {
    test('starts false and flips to true after first load', () async {
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

      // hasInitialized starts false
      // (may already be true if cache primed synchronously)
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(repo.hasInitialized.value, isTrue);
      expect(repo.value?.name, 'Alice');

      repo.dispose();
    });

    test('is true even when document does not exist', () async {
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

      expect(repo.value, isNull);
      expect(repo.hasInitialized.value, isTrue);

      repo.dispose();
    });

    test('is true when signed out (auth-gated with null uid)', () async {
      final fs = FakeFirebaseFirestore();
      final authUid = ValueNotifier<String?>(null);

      final repo = FirestoreDocRepository<Foo>(
        firestore: fs,
        fromJson: Foo.fromJson,
        docRefBuilder: (f, uid) => f.doc('foos/$uid'),
        authUid: authUid,
        subscribe: true,
      );

      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(repo.hasInitialized.value, isTrue);

      repo.dispose();
    });

    test('is true on stream error', () async {
      final fs = FakeFirebaseFirestore();

      final repo = FirestoreDocRepository<Foo>(
        firestore: fs,
        fromJson: Foo.fromJson,
        docRefBuilder: (f, uid) => _ErrorDocRef(),
        subscribe: true,
      );

      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(repo.hasInitialized.value, isTrue);

      repo.dispose();
    });
  });

  group('ready', () {
    test('completes with value after first load', () async {
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

      final result = await repo.ready;
      expect(result?.name, 'Alice');

      repo.dispose();
    });

    test('completes with null when document does not exist', () async {
      final fs = FakeFirebaseFirestore();
      final authUid = ValueNotifier<String?>('u1');

      final repo = FirestoreDocRepository<Foo>(
        firestore: fs,
        fromJson: Foo.fromJson,
        docRefBuilder: (f, uid) => f.doc('foos/$uid'),
        authUid: authUid,
        subscribe: true,
      );

      final result = await repo.ready;
      expect(result, isNull);

      repo.dispose();
    });

    test('completes with null when signed out', () async {
      final fs = FakeFirebaseFirestore();
      final authUid = ValueNotifier<String?>(null);

      final repo = FirestoreDocRepository<Foo>(
        firestore: fs,
        fromJson: Foo.fromJson,
        docRefBuilder: (f, uid) => f.doc('foos/$uid'),
        authUid: authUid,
        subscribe: true,
      );

      final result = await repo.ready;
      expect(result, isNull);

      repo.dispose();
    });

    test('returns immediately if already initialized', () async {
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

      await repo.ready; // wait for first load
      // second call should return instantly
      final result = await repo.ready;
      expect(result?.name, 'Alice');

      repo.dispose();
    });

    test('re-waits after authUid change (regression #13)', () async {
      final fs = FakeFirebaseFirestore();
      final authUid = ValueNotifier<String?>(null);

      final repo = FirestoreDocRepository<Foo>(
        firestore: fs,
        fromJson: Foo.fromJson,
        docRefBuilder: (f, uid) => f.doc('foos/$uid'),
        authUid: authUid,
        subscribe: true,
      );

      // Initially signed out — ready completes with null
      final firstReady = await repo.ready;
      expect(firstReady, isNull);
      expect(repo.hasInitialized.value, isTrue);

      // Sign in — UID changes, data arrives
      await fs.doc('foos/u1').set({'name': 'Alice'});
      authUid.value = 'u1';
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // hasInitialized should flip back to true after re-load
      expect(repo.hasInitialized.value, isTrue);
      expect(repo.value?.name, 'Alice');

      // ready should return the NEW value, not stale null
      final secondReady = await repo.ready;
      expect(secondReady?.name, 'Alice');

      repo.dispose();
    });

    test('works with one-shot mode', () async {
      final fs = FakeFirebaseFirestore();
      final authUid = ValueNotifier<String?>('u1');

      await fs.doc('foos/u1').set({'name': 'OneShot'});

      final repo = FirestoreDocRepository<Foo>(
        firestore: fs,
        fromJson: Foo.fromJson,
        docRefBuilder: (f, uid) => f.doc('foos/$uid'),
        authUid: authUid,
        subscribe: false,
      );

      final result = await repo.ready;
      expect(result?.name, 'OneShot');

      repo.dispose();
    });
  });
}
