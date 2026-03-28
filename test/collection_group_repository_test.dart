import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firewatch/firewatch.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// ignore: subtype_of_sealed_class
/// A minimal Query that emits an error on [snapshots] and [get].
/// Used to test the onError stream callback in the repository.
class _ErrorQuery implements Query<Map<String, dynamic>> {
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

class Task implements JsonModel {
  @override
  final String id;
  final String title;
  Task({required this.id, required this.title});

  factory Task.fromJson(Map<String, dynamic> m) =>
      Task(id: m['id'] as String, title: (m['title'] as String?) ?? '');

  @override
  Map<String, dynamic> toJson() => {'title': title};
}

/// Helper to seed tasks across multiple parent paths.
Future<void> _seed(FakeFirebaseFirestore fs) async {
  await fs.doc('users/u1/tasks/t1').set({'title': 'Task 1'});
  await fs.doc('users/u2/tasks/t2').set({'title': 'Task 2'});
  await fs.doc('projects/p1/tasks/t3').set({'title': 'Task 3'});
}

class TaskWithParent implements JsonModel {
  @override
  final String id;
  final String title;
  final String? parentId;
  TaskWithParent({required this.id, required this.title, this.parentId});

  factory TaskWithParent.fromJson(Map<String, dynamic> m) => TaskWithParent(
    id: m['id'] as String,
    title: (m['title'] as String?) ?? '',
    parentId: m['parentId'] as String?,
  );

  @override
  Map<String, dynamic> toJson() => {'title': title};
}

void main() {
  test('returns documents from multiple parent paths', () async {
    final fs = FakeFirebaseFirestore();
    await _seed(fs);

    final repo = FirestoreCollectionGroupRepository<Task>(
      firestore: fs,
      fromJson: Task.fromJson,
      queryRefBuilder: (f, uid) => f.collectionGroup('tasks'),
      subscribe: true,
      pageSize: 50,
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(repo.value.length, 3);
    final titles = repo.value.map((t) => t.title).toList()..sort();
    expect(titles, ['Task 1', 'Task 2', 'Task 3']);

    repo.dispose();
  });

  test('auth-reactive: attaches on sign-in, detaches on sign-out', () async {
    final fs = FakeFirebaseFirestore();
    await _seed(fs);

    final authUid = ValueNotifier<String?>(null);

    final repo = FirestoreCollectionGroupRepository<Task>(
      firestore: fs,
      fromJson: Task.fromJson,
      queryRefBuilder: (f, uid) => f.collectionGroup('tasks'),
      authUid: authUid,
      subscribe: true,
      pageSize: 50,
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));

    // Signed out — empty
    expect(repo.value, isEmpty);

    // Sign in
    authUid.value = 'u1';
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(repo.value.length, 3);

    // Sign out
    authUid.value = null;
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(repo.value, isEmpty);

    repo.dispose();
  });

  test('pagination with live window (loadMore, hasMore)', () async {
    final fs = FakeFirebaseFirestore();
    await _seed(fs);

    final repo = FirestoreCollectionGroupRepository<Task>(
      firestore: fs,
      fromJson: Task.fromJson,
      queryRefBuilder: (f, uid) => f.collectionGroup('tasks'),
      subscribe: true,
      pageSize: 2,
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(repo.value.length, 2);
    expect(repo.hasMore.value, isTrue);

    await repo.loadMore();
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(repo.value.length, 3);
    expect(repo.hasMore.value, isFalse);

    repo.dispose();
  });

  test(
    'per-item notifiers keyed by path — same doc ID, different parents',
    () async {
      final fs = FakeFirebaseFirestore();
      // Two docs with the same doc ID 'shared' under different parents.
      await fs
          .doc('users/u1/tasks/shared')
          .set({'title': 'User task'});
      await fs
          .doc('projects/p1/tasks/shared')
          .set({'title': 'Project task'});

      final repo = FirestoreCollectionGroupRepository<Task>(
        firestore: fs,
        fromJson: Task.fromJson,
        queryRefBuilder: (f, uid) => f.collectionGroup('tasks'),
        subscribe: true,
        pageSize: 50,
      );

      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(repo.value.length, 2);

      final userNotifier = repo.notifierFor('users/u1/tasks/shared');
      final projectNotifier = repo.notifierFor('projects/p1/tasks/shared');

      expect(userNotifier.value?.title, 'User task');
      expect(projectNotifier.value?.title, 'Project task');

      // They are distinct notifier instances
      expect(identical(userNotifier, projectNotifier), isFalse);

      repo.dispose();
    },
  );

  test('notifiers update and prune on changes', () async {
    final fs = FakeFirebaseFirestore();
    await fs.doc('users/u1/tasks/t1').set({'title': 'Original'});

    final repo = FirestoreCollectionGroupRepository<Task>(
      firestore: fs,
      fromJson: Task.fromJson,
      queryRefBuilder: (f, uid) => f.collectionGroup('tasks'),
      subscribe: true,
      pageSize: 50,
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));

    final notifier = repo.notifierFor('users/u1/tasks/t1');
    expect(notifier.value?.title, 'Original');

    // Update the doc (refresh needed — fake_cloud_firestore doesn't
    // propagate live updates through collection group listeners)
    await fs.doc('users/u1/tasks/t1').update({'title': 'Updated'});
    await repo.refresh();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(notifier.value?.title, 'Updated');

    // Delete the doc — notifier should be nulled
    await fs.doc('users/u1/tasks/t1').delete();
    await repo.refresh();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(notifier.value, isNull);

    repo.dispose();
  });

  test('setQuery applies filter, resets pagination', () async {
    final fs = FakeFirebaseFirestore();
    await fs.doc('users/u1/tasks/t1').set({'title': 'Alpha'});
    await fs.doc('users/u2/tasks/t2').set({'title': 'Beta'});
    await fs.doc('projects/p1/tasks/t3').set({'title': 'Gamma'});

    final repo = FirestoreCollectionGroupRepository<Task>(
      firestore: fs,
      fromJson: Task.fromJson,
      queryRefBuilder: (f, uid) => f.collectionGroup('tasks'),
      subscribe: true,
      pageSize: 2,
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(repo.value.length, 2);

    // Load more to inflate limit
    await repo.loadMore();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(repo.value.length, 3);

    // Change query — should reset pagination
    repo.setQuery((base) => base.where('title', isEqualTo: 'Beta'));
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(repo.value.length, 1);
    expect(repo.value.first.title, 'Beta');

    repo.dispose();
  });

  test('one-shot mode (subscribe: false)', () async {
    final fs = FakeFirebaseFirestore();
    await _seed(fs);

    final repo = FirestoreCollectionGroupRepository<Task>(
      firestore: fs,
      fromJson: Task.fromJson,
      queryRefBuilder: (f, uid) => f.collectionGroup('tasks'),
      subscribe: false,
      pageSize: 50,
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(repo.value.length, 3);
    expect(repo.isLoading.value, isFalse);
    expect(repo.hasInitialized.value, isTrue);

    repo.dispose();
  });

  test('paginate: false returns all results', () async {
    final fs = FakeFirebaseFirestore();
    await _seed(fs);

    final repo = FirestoreCollectionGroupRepository<Task>(
      firestore: fs,
      fromJson: Task.fromJson,
      queryRefBuilder: (f, uid) => f.collectionGroup('tasks'),
      subscribe: true,
      pageSize: 1,
      paginate: false,
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));

    // All 3 docs returned despite pageSize: 1
    expect(repo.value.length, 3);

    repo.dispose();
  });

  test('state getters (isInitializing, isRefreshing, showEmpty)', () async {
    final fs = FakeFirebaseFirestore();

    final repo = FirestoreCollectionGroupRepository<Task>(
      firestore: fs,
      fromJson: Task.fromJson,
      queryRefBuilder: (f, uid) => f.collectionGroup('tasks'),
      subscribe: true,
      pageSize: 50,
    );

    // Before initialization completes
    expect(repo.isInitializing, isTrue);
    expect(repo.isRefreshing, isFalse);
    expect(repo.showEmpty, isFalse);

    await Future<void>.delayed(const Duration(milliseconds: 10));

    // After initialization with empty collection group
    expect(repo.isInitializing, isFalse);
    expect(repo.isRefreshing, isFalse);
    expect(repo.showEmpty, isTrue);

    // Add a doc so it's no longer empty (refresh needed — fake_cloud_firestore
    // doesn't propagate live updates through collection group listeners)
    await fs.doc('users/u1/tasks/t1').set({'title': 'Hello'});
    await repo.refresh();
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(repo.showEmpty, isFalse);

    repo.dispose();
  });

  test('works without authUid (public collection group)', () async {
    final fs = FakeFirebaseFirestore();
    await _seed(fs);

    final repo = FirestoreCollectionGroupRepository<Task>(
      firestore: fs,
      fromJson: Task.fromJson,
      queryRefBuilder: (f, uid) => f.collectionGroup('tasks'),
      // no authUid — public collection group
      subscribe: true,
      pageSize: 50,
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(repo.value.length, 3);
    expect(repo.isLoading.value, isFalse);
    expect(repo.hasInitialized.value, isTrue);

    repo.dispose();
  });

  test('dispose removes listeners cleanly', () async {
    final fs = FakeFirebaseFirestore();
    final authUid = ValueNotifier<String?>('u1');

    final repo = FirestoreCollectionGroupRepository<Task>(
      firestore: fs,
      fromJson: Task.fromJson,
      queryRefBuilder: (f, uid) => f.collectionGroup('tasks'),
      authUid: authUid,
      subscribe: true,
      pageSize: 50,
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));

    repo.dispose();

    // Changing auth after dispose should not throw
    authUid.value = 'u2';
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(repo.value, isEmpty);
  });

  test('refresh re-fetches data', () async {
    final fs = FakeFirebaseFirestore();
    await fs.doc('users/u1/tasks/t1').set({'title': 'Task 1'});

    final repo = FirestoreCollectionGroupRepository<Task>(
      firestore: fs,
      fromJson: Task.fromJson,
      queryRefBuilder: (f, uid) => f.collectionGroup('tasks'),
      subscribe: true,
      pageSize: 50,
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(repo.value.length, 1);

    // Add another doc and refresh
    await fs.doc('users/u2/tasks/t2').set({'title': 'Task 2'});
    await repo.refresh();
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(repo.value.length, 2);

    repo.dispose();
  });

  test('write commands (set, patch, update, delete) work by document path',
      () async {
    final fs = FakeFirebaseFirestore();

    final repo = FirestoreCollectionGroupRepository<Task>(
      firestore: fs,
      fromJson: Task.fromJson,
      queryRefBuilder: (f, uid) => f.collectionGroup('tasks'),
      subscribe: true,
      pageSize: 50,
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));

    // Set — create a doc at a specific path (refresh needed after each write
    // because fake_cloud_firestore doesn't propagate live updates through
    // collection group listeners)
    await repo.set.runAsync(
      (path: 'users/u1/tasks/t1', model: Task(id: 't1', title: 'Created')),
    );
    await repo.refresh();
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(repo.value.length, 1);
    expect(repo.value.first.title, 'Created');

    // Patch — partially update
    await repo.patch.runAsync(
      (path: 'users/u1/tasks/t1', data: {'title': 'Patched'}),
    );
    await repo.refresh();
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(repo.value.first.title, 'Patched');

    // Update — full replacement via model
    await repo.update.runAsync(
      (path: 'users/u1/tasks/t1', model: Task(id: 't1', title: 'Updated')),
    );
    await repo.refresh();
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(repo.value.first.title, 'Updated');

    // Delete — remove by path
    await repo.delete.runAsync('users/u1/tasks/t1');
    await repo.refresh();
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(repo.value, isEmpty);

    repo.dispose();
  });

  test('write commands error when auth-gated and signed out', () async {
    final fs = FakeFirebaseFirestore();
    final authUid = ValueNotifier<String?>(null);

    final repo = FirestoreCollectionGroupRepository<Task>(
      firestore: fs,
      fromJson: Task.fromJson,
      queryRefBuilder: (f, uid) => f.collectionGroup('tasks'),
      authUid: authUid,
      subscribe: true,
      pageSize: 50,
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));

    // Register local error listeners so command_it routes errors locally.
    repo.set.errors.addListener(() {});
    repo.update.errors.addListener(() {});
    repo.patch.errors.addListener(() {});
    repo.delete.errors.addListener(() {});

    // set
    repo.set.run(
      (path: 'users/u1/tasks/t1', model: Task(id: 't1', title: 'X')),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(repo.set.errors.value?.error, isA<StateError>());

    // update
    repo.update.run(
      (path: 'users/u1/tasks/t1', model: Task(id: 't1', title: 'X')),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(repo.update.errors.value?.error, isA<StateError>());

    // patch
    repo.patch.run(
      (path: 'users/u1/tasks/t1', data: {'title': 'X'}),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(repo.patch.errors.value?.error, isA<StateError>());

    // delete
    repo.delete.run('users/u1/tasks/t1');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(repo.delete.errors.value?.error, isA<StateError>());

    repo.dispose();
  });

  test('resetPages resets to first page', () async {
    final fs = FakeFirebaseFirestore();
    await _seed(fs);

    final repo = FirestoreCollectionGroupRepository<Task>(
      firestore: fs,
      fromJson: Task.fromJson,
      queryRefBuilder: (f, uid) => f.collectionGroup('tasks'),
      subscribe: true,
      pageSize: 2,
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(repo.value.length, 2);

    await repo.loadMore();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(repo.value.length, 3);

    await repo.resetPages();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(repo.value.length, 2);
    expect(repo.hasMore.value, isTrue);

    repo.dispose();
  });

  test('extra dependencies trigger rebuild', () async {
    final fs = FakeFirebaseFirestore();
    final dep = ValueNotifier<int>(0);

    await fs.doc('users/u1/tasks/t1').set({'title': 'A'});
    await fs.doc('users/u2/tasks/t2').set({'title': 'B'});

    final repo = FirestoreCollectionGroupRepository<Task>(
      firestore: fs,
      fromJson: Task.fromJson,
      queryRefBuilder: (f, uid) => f.collectionGroup('tasks'),
      dependencies: [dep],
      subscribe: true,
      pageSize: 50,
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(repo.value.length, 2);

    // Add a doc and change dep to trigger rebuild
    await fs.doc('projects/p1/tasks/t3').set({'title': 'C'});
    dep.value = 1;
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(repo.value.length, 3);

    repo.dispose();
  });

  test('one-shot mode signed out returns empty', () async {
    final fs = FakeFirebaseFirestore();
    final authUid = ValueNotifier<String?>(null);
    await _seed(fs);

    final repo = FirestoreCollectionGroupRepository<Task>(
      firestore: fs,
      fromJson: Task.fromJson,
      queryRefBuilder: (f, uid) => f.collectionGroup('tasks'),
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

  test('parentId is injected from parent document reference', () async {
    final fs = FakeFirebaseFirestore();
    await fs.doc('users/u1/tasks/t1').set({'title': 'User task'});
    await fs.doc('projects/p1/tasks/t2').set({'title': 'Project task'});

    final repo = FirestoreCollectionGroupRepository<TaskWithParent>(
      firestore: fs,
      fromJson: TaskWithParent.fromJson,
      queryRefBuilder: (f, uid) => f.collectionGroup('tasks'),
      subscribe: true,
      pageSize: 50,
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(repo.value.length, 2);

    final byId = {for (final t in repo.value) t.id: t};
    expect(byId['t1']?.parentId, 'u1');
    expect(byId['t2']?.parentId, 'p1');

    repo.dispose();
  });

  test('onError callback sets isLoading false on stream error (_swap)',
      () async {
    final fs = FakeFirebaseFirestore();

    final repo = FirestoreCollectionGroupRepository<Task>(
      firestore: fs,
      fromJson: Task.fromJson,
      queryRefBuilder: (f, uid) => _ErrorQuery(),
      subscribe: true,
      pageSize: 50,
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));

    // The stream errored; onError should have set isLoading to false
    // and hasInitialized to true.
    expect(repo.isLoading.value, isFalse);
    expect(repo.hasInitialized.value, isTrue);

    repo.dispose();
  });

  // ── direct write methods ────────────────────────────────────────────────

  test('patchDirect allows concurrent patches to different docs', () async {
    final fs = FakeFirebaseFirestore();
    await fs.doc('users/u1/tasks/t1').set({'title': 'A'});
    await fs.doc('users/u2/tasks/t2').set({'title': 'B'});

    final repo = FirestoreCollectionGroupRepository<Task>(
      firestore: fs,
      fromJson: Task.fromJson,
      queryRefBuilder: (f, uid) => f.collectionGroup('tasks'),
      subscribe: true,
      pageSize: 50,
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(repo.value.length, 2);

    // Fire both patches concurrently — both must succeed
    await Future.wait([
      repo.patchDirect((path: 'users/u1/tasks/t1', data: {'title': 'A2'})),
      repo.patchDirect((path: 'users/u2/tasks/t2', data: {'title': 'B2'})),
    ]);
    await repo.refresh();
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final titles = repo.value.map((t) => t.title).toList()..sort();
    expect(titles, ['A2', 'B2']);

    repo.dispose();
  });

  test('setDirect and updateDirect allow concurrent writes', () async {
    final fs = FakeFirebaseFirestore();

    final repo = FirestoreCollectionGroupRepository<Task>(
      firestore: fs,
      fromJson: Task.fromJson,
      queryRefBuilder: (f, uid) => f.collectionGroup('tasks'),
      subscribe: true,
      pageSize: 50,
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));

    // setDirect — concurrent creates
    await Future.wait([
      repo.setDirect(
        (path: 'users/u1/tasks/t1', model: Task(id: 't1', title: 'A')),
      ),
      repo.setDirect(
        (path: 'users/u2/tasks/t2', model: Task(id: 't2', title: 'B')),
      ),
    ]);
    await repo.refresh();
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(repo.value.length, 2);

    // updateDirect — concurrent full updates
    await Future.wait([
      repo.updateDirect(
        (path: 'users/u1/tasks/t1', model: Task(id: 't1', title: 'A2')),
      ),
      repo.updateDirect(
        (path: 'users/u2/tasks/t2', model: Task(id: 't2', title: 'B2')),
      ),
    ]);
    await repo.refresh();
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final titles = repo.value.map((t) => t.title).toList()..sort();
    expect(titles, ['A2', 'B2']);

    repo.dispose();
  });

  test('deleteDirect allows concurrent deletes', () async {
    final fs = FakeFirebaseFirestore();
    await fs.doc('users/u1/tasks/t1').set({'title': 'A'});
    await fs.doc('users/u2/tasks/t2').set({'title': 'B'});

    final repo = FirestoreCollectionGroupRepository<Task>(
      firestore: fs,
      fromJson: Task.fromJson,
      queryRefBuilder: (f, uid) => f.collectionGroup('tasks'),
      subscribe: true,
      pageSize: 50,
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(repo.value.length, 2);

    await Future.wait([
      repo.deleteDirect('users/u1/tasks/t1'),
      repo.deleteDirect('users/u2/tasks/t2'),
    ]);
    await repo.refresh();
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(repo.value, isEmpty);

    repo.dispose();
  });

  test('direct methods throw StateError when auth-gated and no user',
      () async {
    final fs = FakeFirebaseFirestore();
    final authUid = ValueNotifier<String?>(null);

    final repo = FirestoreCollectionGroupRepository<Task>(
      firestore: fs,
      fromJson: Task.fromJson,
      queryRefBuilder: (f, uid) => f.collectionGroup('tasks'),
      authUid: authUid,
      subscribe: true,
      pageSize: 50,
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(
      () => repo.setDirect(
        (path: 'users/u1/tasks/t1', model: Task(id: 't1', title: 'X')),
      ),
      throwsStateError,
    );
    expect(
      () => repo.patchDirect(
        (path: 'users/u1/tasks/t1', data: {'title': 'X'}),
      ),
      throwsStateError,
    );
    expect(
      () => repo.updateDirect(
        (path: 'users/u1/tasks/t1', model: Task(id: 't1', title: 'X')),
      ),
      throwsStateError,
    );
    expect(() => repo.deleteDirect('users/u1/tasks/t1'), throwsStateError);

    repo.dispose();
  });

  test('onError callback sets isLoading false on stream error (_resizeWindow)',
      () async {
    final fs = FakeFirebaseFirestore();
    await _seed(fs);

    var useError = false;
    final repo = FirestoreCollectionGroupRepository<Task>(
      firestore: fs,
      fromJson: Task.fromJson,
      queryRefBuilder: (f, uid) =>
          useError ? _ErrorQuery() : f.collectionGroup('tasks'),
      subscribe: true,
      pageSize: 2,
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(repo.value.length, 2);

    // Switch to error-producing query, then loadMore triggers _resizeWindow
    useError = true;
    await repo.loadMore();
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(repo.isLoading.value, isFalse);

    repo.dispose();
  });

  // ── onError callback ────────────────────────────────────────────────────

  test('onError callback receives stream error from _swap', () async {
    Object? receivedError;
    StackTrace? receivedStackTrace;

    final repo = FirestoreCollectionGroupRepository<Task>(
      firestore: FakeFirebaseFirestore(),
      fromJson: Task.fromJson,
      queryRefBuilder: (f, uid) => _ErrorQuery(),
      subscribe: true,
      pageSize: 50,
      onError: (error, stackTrace) {
        receivedError = error;
        receivedStackTrace = stackTrace;
      },
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(receivedError, isA<Exception>());
    expect(receivedStackTrace, isNotNull);
    expect(repo.isLoading.value, isFalse);
    expect(repo.hasInitialized.value, isTrue);

    repo.dispose();
  });

  test('onError callback receives stream error from _resizeWindow', () async {
    final fs = FakeFirebaseFirestore();
    await _seed(fs);

    Object? receivedError;
    var useError = false;
    final repo = FirestoreCollectionGroupRepository<Task>(
      firestore: fs,
      fromJson: Task.fromJson,
      queryRefBuilder: (f, uid) =>
          useError ? _ErrorQuery() : f.collectionGroup('tasks'),
      subscribe: true,
      pageSize: 2,
      onError: (error, stackTrace) {
        receivedError = error;
      },
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(repo.value.length, 2);
    expect(receivedError, isNull);

    // Switch to error-producing query, then loadMore triggers _resizeWindow
    useError = true;
    await repo.loadMore();
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(receivedError, isA<Exception>());
    expect(repo.isLoading.value, isFalse);

    repo.dispose();
  });

  test('onError callback receives one-shot fetch error', () async {
    Object? receivedError;
    StackTrace? receivedStackTrace;

    final repo = FirestoreCollectionGroupRepository<Task>(
      firestore: FakeFirebaseFirestore(),
      fromJson: Task.fromJson,
      queryRefBuilder: (f, uid) => _ErrorQuery(),
      subscribe: false,
      pageSize: 50,
      onError: (error, stackTrace) {
        receivedError = error;
        receivedStackTrace = stackTrace;
      },
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(receivedError, isA<Exception>());
    expect(receivedStackTrace, isNotNull);
    expect(repo.isLoading.value, isFalse);
    expect(repo.hasInitialized.value, isTrue);

    repo.dispose();
  });

  test('onError is not called when no error occurs', () async {
    final fs = FakeFirebaseFirestore();
    await _seed(fs);

    var errorCount = 0;

    final repo = FirestoreCollectionGroupRepository<Task>(
      firestore: fs,
      fromJson: Task.fromJson,
      queryRefBuilder: (f, uid) => f.collectionGroup('tasks'),
      subscribe: true,
      pageSize: 50,
      onError: (error, stackTrace) => errorCount++,
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(errorCount, 0);
    expect(repo.value.length, 3);

    repo.dispose();
  });
}
