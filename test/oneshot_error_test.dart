import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firewatch/firewatch.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// ignore: subtype_of_sealed_class
/// A CollectionReference wrapper whose server `get()` fails a configurable
/// number of times before delegating to a real (fake) collection.
///
/// Cache-source gets (`Source.cache`) always throw — mirroring an empty
/// local cache — and are NOT counted against [failuresRemaining], since the
/// repo's cache-priming read is a separate concern from the one-shot fetch.
// ignore: must_be_immutable
class _FlakyCollectionRef implements CollectionReference<Map<String, dynamic>> {
  _FlakyCollectionRef(this.inner, {required this.failuresRemaining});

  final CollectionReference<Map<String, dynamic>> inner;
  int failuresRemaining;
  int serverGetCalls = 0;

  @override
  Future<QuerySnapshot<Map<String, dynamic>>> get([GetOptions? options]) {
    if (options?.source == Source.cache) {
      return Future.error(Exception('cache empty'));
    }
    serverGetCalls++;
    if (failuresRemaining != 0) {
      if (failuresRemaining > 0) failuresRemaining--;
      return Future.error(Exception('Simulated transient get error'));
    }
    return inner.get(options);
  }

  @override
  Query<Map<String, dynamic>> limit(int limit) => this;

  @override
  Stream<QuerySnapshot<Map<String, dynamic>>> snapshots({
    bool includeMetadataChanges = false,
    ListenSource? source,
  }) =>
      Stream.error(Exception('Simulated stream error'));

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

const _tick = Duration(milliseconds: 10);

void main() {
  late FakeFirebaseFirestore fs;

  setUp(() async {
    fs = FakeFirebaseFirestore();
    final col = fs.collection('users/u1/items');
    for (var i = 0; i < 3; i++) {
      await col.doc('d$i').set({'n': i});
    }
  });

  test(
      'one-shot fetch that fails within the retry budget recovers: '
      'value populated, no error, hasInitialized', () async {
    final flaky = _FlakyCollectionRef(
      fs.collection('users/u1/items'),
      failuresRemaining: 2,
    );

    final repo = FirestoreCollectionRepository<Item>(
      firestore: fs,
      fromJson: Item.fromJson,
      colRefBuilder: (f, uid) => flaky,
      authUid: ValueNotifier<String?>('u1'),
      subscribe: false,
      maxRetries: 3,
      retryDelay: const Duration(milliseconds: 5),
    );

    // 2 failures with 5ms/10ms backoff, then success.
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(repo.value.length, 3);
    expect(repo.lastError.value, isNull);
    expect(repo.hasError, isFalse);
    expect(repo.hasInitialized.value, isTrue);
    expect(repo.isLoading.value, isFalse);
    expect(flaky.serverGetCalls, 3); // 2 failures + 1 success
    // Server-confirmed snapshot: not from cache.
    expect(repo.isFromCache.value, isFalse);

    repo.dispose();
  });

  test(
      'one-shot fetch failing beyond the budget surfaces lastError and is '
      'distinguishable from a genuine empty result', () async {
    final errors = <Object>[];
    final flaky = _FlakyCollectionRef(
      fs.collection('users/u1/items'),
      failuresRemaining: -1, // always fail
    );

    final repo = FirestoreCollectionRepository<Item>(
      firestore: fs,
      fromJson: Item.fromJson,
      colRefBuilder: (f, uid) => flaky,
      authUid: ValueNotifier<String?>('u1'),
      subscribe: false,
      maxRetries: 2,
      retryDelay: const Duration(milliseconds: 5),
      onError: (e, st) => errors.add(e),
    );

    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(flaky.serverGetCalls, 3); // initial + 2 retries
    expect(errors.length, 3); // onError still fires per attempt
    expect(repo.value, isEmpty);
    expect(repo.hasInitialized.value, isTrue);
    expect(repo.isLoading.value, isFalse);
    // The whole point of the fix: failed != empty.
    expect(repo.lastError.value, isNotNull);
    expect(repo.hasError, isTrue);
    expect(repo.showEmpty, isFalse);

    repo.dispose();
  });

  test('genuinely empty one-shot result still reports showEmpty', () async {
    final repo = FirestoreCollectionRepository<Item>(
      firestore: fs,
      fromJson: Item.fromJson,
      colRefBuilder: (f, uid) => f.collection('users/$uid/nothing-here'),
      authUid: ValueNotifier<String?>('u1'),
      subscribe: false,
    );

    await Future<void>.delayed(_tick);

    expect(repo.value, isEmpty);
    expect(repo.hasError, isFalse);
    expect(repo.showEmpty, isTrue);

    repo.dispose();
  });

  test('a successful fetch (refresh) clears a prior error', () async {
    final flaky = _FlakyCollectionRef(
      fs.collection('users/u1/items'),
      failuresRemaining: 1,
    );

    final repo = FirestoreCollectionRepository<Item>(
      firestore: fs,
      fromJson: Item.fromJson,
      colRefBuilder: (f, uid) => flaky,
      authUid: ValueNotifier<String?>('u1'),
      subscribe: false,
      maxRetries: 0, // first failure is terminal
    );

    await Future<void>.delayed(_tick);
    expect(repo.hasError, isTrue);
    expect(repo.value, isEmpty);

    // Next fetch succeeds (flaky is out of failures).
    await repo.refresh();
    await Future<void>.delayed(_tick);

    expect(repo.lastError.value, isNull);
    expect(repo.hasError, isFalse);
    expect(repo.value.length, 3);
    expect(repo.hasInitialized.value, isTrue);

    repo.dispose();
  });

  test('epoch change mid-retry abandons the retry loop cleanly', () async {
    var useFlaky = true;
    final flaky = _FlakyCollectionRef(
      fs.collection('users/u1/items'),
      failuresRemaining: -1, // always fail
    );

    final repo = FirestoreCollectionRepository<Item>(
      firestore: fs,
      fromJson: Item.fromJson,
      colRefBuilder: (f, uid) =>
          useFlaky ? flaky : fs.collection('users/$uid/items'),
      authUid: ValueNotifier<String?>('u1'),
      subscribe: false,
      maxRetries: 10,
      retryDelay: const Duration(milliseconds: 50),
    );

    // Let the first failure land and the first backoff start.
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final callsAtSwap = flaky.serverGetCalls;
    expect(callsAtSwap, greaterThanOrEqualTo(1));

    // Swap to a working query mid-backoff (bumps the epoch).
    useFlaky = false;
    repo.setQuery((q) => q);
    await Future<void>.delayed(const Duration(milliseconds: 200));

    // The abandoned loop must not have kept hammering the old ref...
    expect(flaky.serverGetCalls, callsAtSwap);
    // ...and must not have smeared its error over the new query's clean state.
    expect(repo.lastError.value, isNull);
    expect(repo.hasError, isFalse);
    expect(repo.value.length, 3);
    expect(repo.hasInitialized.value, isTrue);
    expect(repo.isLoading.value, isFalse);

    repo.dispose();
  });

  test('dispose mid-retry does not throw or touch disposed notifiers',
      () async {
    final flaky = _FlakyCollectionRef(
      fs.collection('users/u1/items'),
      failuresRemaining: -1,
    );

    final repo = FirestoreCollectionRepository<Item>(
      firestore: fs,
      fromJson: Item.fromJson,
      colRefBuilder: (f, uid) => flaky,
      authUid: ValueNotifier<String?>('u1'),
      subscribe: false,
      maxRetries: 10,
      retryDelay: const Duration(milliseconds: 30),
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));
    repo.dispose(); // bumps the epoch; pending backoff must bail

    // If the abandoned retry touched a disposed notifier this would surface
    // as an async error and fail the test.
    await Future<void>.delayed(const Duration(milliseconds: 200));
  });

  test('stream path terminal failure also sets lastError', () async {
    final repo = FirestoreCollectionRepository<Item>(
      firestore: fs,
      fromJson: Item.fromJson,
      colRefBuilder: (f, uid) => _FlakyCollectionRef(
        fs.collection('users/$uid/items'),
        failuresRemaining: -1,
      ),
      authUid: ValueNotifier<String?>('u1'),
      subscribe: true,
      maxRetries: 0,
    );

    await Future<void>.delayed(_tick);

    expect(repo.hasError, isTrue);
    expect(repo.showEmpty, isFalse);
    expect(repo.hasInitialized.value, isTrue);
    expect(repo.isLoading.value, isFalse);

    repo.dispose();
  });
}
