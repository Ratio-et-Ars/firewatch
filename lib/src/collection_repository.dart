import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:command_it/command_it.dart';
import 'package:flutter/foundation.dart';

import 'json_model.dart';

/// A builder function that produces a typed Firestore collection reference.
///
/// Parameters:
/// - [fs]: The active [FirebaseFirestore] instance.
/// - [uid]: The current user ID, or `null` if not authenticated.
///
/// Returns:
/// - A [CollectionReference] targeting the desired collection,
///   typically scoped by the given [uid] when applicable.
///
/// Used by repositories to dynamically resolve the correct collection path
/// (e.g. `users/{uid}/entries`).
typedef ColRefBuilder =
    CollectionReference<Map<String, dynamic>> Function(
      FirebaseFirestore fs,
      String? uid,
    );

/// Mutates a base collection query (e.g., add where/order/limit).
typedef QueryMutator =
    Query<Map<String, dynamic>> Function(Query<Map<String, dynamic>> base);

/// Represents a partial update to a Firestore document.
///
/// Fields:
/// - [id]: The ID of the target document.
/// - [data]: A map of fields and values to update. Only the specified
///   fields will be modified; all others remain unchanged.
///
/// Example:
/// ```dart
/// final p = (id: 'u1', data: {'name': 'Alice', 'age': 30});
/// patch.execute(p);
/// ```
///
/// Useful for applying small, targeted updates without rewriting
/// the entire document.
typedef Patch = ({String id, Map<String, Object?> data});

/// A Firestore collection repository designed for responsive UIs:
/// - Reacts to auth changes and extra dependencies
/// - Supports live queries (subscribe) or one-shot fetches
/// - Exposes pagination via a live "window" (limit that grows with `loadMore`)
/// - Keeps per-item notifiers in sync for efficient item detail widgets
///
/// Works with or without authentication. Omit [authUid] for public
/// collections that should query Firestore immediately without waiting
/// for a signed-in user.
class FirestoreCollectionRepository<T extends JsonModel>
    extends ValueNotifier<List<T>> {
  /// Creates a new [FirestoreCollectionRepository].
  ///
  /// Parameters:
  /// - [firestore]: The active [FirebaseFirestore] instance. Defaults to
  ///   [FirebaseFirestore.instance]
  /// - [fromJson]: Converts a raw Firestore document map into a model [T].
  /// - [colRefBuilder]: Resolves the collection reference, often scoped by user ID.
  /// - [queryBuilder]: (Optional) Initial query mutator to apply filters,
  ///   ordering, or limits to the collection.
  /// - [authUid]: (Optional) A listenable source of the current user ID;
  ///   repository will rebuild automatically when this changes. Omit for
  ///   public collections that don't require authentication — the repo will
  ///   query immediately with `uid = null` passed to [colRefBuilder].
  /// - [dependencies]: (Optional) Extra [Listenable]s to watch; any change
  ///   triggers a query refresh.
  /// - [subscribe]: If true (default), repository stays in sync with
  ///   live Firestore updates. If false, fetches a one-shot snapshot only.
  /// - [pageSize]: Initial page size for paginated queries (default: 25).
  /// - [paginate]: If true (default), enables pagination via `loadMore()`.
  ///
  /// On construction, listeners are attached and the initial query is run
  /// immediately against the resolved collection for the current user.
  FirestoreCollectionRepository({
    required T Function(Map<String, dynamic>) fromJson,
    required ColRefBuilder colRefBuilder,
    FirebaseFirestore? firestore,
    QueryMutator? queryBuilder, // optional initial query
    AuthUidListenable? authUid, // omit for public/unauthenticated collections
    List<Listenable> dependencies = const [], // extra listenables to watch
    bool subscribe = true, // realtime vs one-shot
    int pageSize = 25, // default page size
    bool paginate = true,
  }) : _fs = firestore ?? FirebaseFirestore.instance,
       _fromJson = fromJson,
       _colRefBuilder = colRefBuilder,
       _authUid = authUid,
       _subscribe = subscribe,
       _deps = List.unmodifiable(dependencies),
       _queryNotifier = ValueNotifier<QueryMutator?>(queryBuilder),
       _limit = ValueNotifier<int>(pageSize),
       _pageSize = pageSize,
       _paginate = paginate,
       super(const []) {
    // Wire listeners (auth + deps + query + limit)
    _authUid?.addListener(_triggerRebuild);
    for (final d in _deps) {
      d.addListener(_triggerRebuild);
    }
    _queryNotifier.addListener(_triggerRebuild);
    _limit.addListener(_resizeWindow);

    _swap(_currentUserUid, clearExisting: true);
  }

  // ── fields ────────────────────────────────────────────────────────────────
  final FirebaseFirestore _fs;
  final AuthUidListenable? _authUid;
  final T Function(Map<String, dynamic>) _fromJson;
  final ColRefBuilder _colRefBuilder;
  final bool _subscribe;
  final List<Listenable> _deps;

  final ValueNotifier<QueryMutator?> _queryNotifier;

  // pagination state
  final int _pageSize;
  final bool _paginate;
  final ValueNotifier<int> _limit;
  /// Whether there are more documents beyond the current page.
  ///
  /// `true` when the last snapshot returned at least [pageSize] documents,
  /// indicating another page may be available via [loadMore].
  final ValueNotifier<bool> hasMore = ValueNotifier<bool>(true);
  bool _resizing = false; // avoid duplicate resubscribes on rapid changes

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _sub;

  /// Per-item notifiers stay in sync with the current list.
  final Map<String, ValueNotifier<T?>> _itemNotifiers = {};

  /// Model cache for incremental snapshot processing; avoids re-parsing
  /// unchanged documents on each snapshot event.
  final Map<String, T> _modelCache = {};

  /// Whether the repository is currently fetching data from Firestore.
  ///
  /// `true` during initial load, auth transitions, pagination, and refreshes.
  /// Use this to drive spinners or progress indicators in the UI.
  final ValueNotifier<bool> isLoading = ValueNotifier<bool>(true);

  /// Whether the repository has completed its first query.
  ///
  /// `false` until the first snapshot (or cache prime) arrives. Once `true`,
  /// it remains `true` until the next [refresh] or auth change resets it.
  final ValueNotifier<bool> hasInitialized = ValueNotifier<bool>(false);

  /// `true` when the first query has not yet completed.
  ///
  /// Useful for showing a full-screen skeleton or placeholder on first load.
  bool get isInitializing => !hasInitialized.value && isLoading.value;

  /// `true` when a subsequent fetch is in progress after initial load.
  ///
  /// Useful for showing a subtle refresh indicator over existing data.
  bool get isRefreshing => hasInitialized.value && isLoading.value;

  /// `true` when initialization is complete, loading is done, and the
  /// collection is empty.
  ///
  /// Useful for showing an empty-state illustration or message.
  bool get showEmpty =>
      hasInitialized.value && !isLoading.value && value.isEmpty;

  String? get _currentUserUid => _authUid?.value;

  /// Whether this repo requires authentication. True when [authUid] was
  /// provided; false for public/unauthenticated collections.
  bool get _isAuthGated => _authUid != null;

  // ── public API ────────────────────────────────────────────────────────────

  /// Swap the active query; pass `null` to clear and use base collection.
  void setQuery(QueryMutator? qb) {
    _queryNotifier.value = qb; // listener triggers _swap
  }

  /// Force a re-attach / refetch using current auth, deps, and query.
  Future<void> refresh() => _swap(_currentUserUid, clearExisting: true);

  /// Per-item notifier (kept in sync from the collection results).
  ValueNotifier<T?> notifierFor(String docId) =>
      _itemNotifiers.putIfAbsent(docId, () => ValueNotifier<T?>(null));

  /// Load the next page. In realtime mode this increases the live window.
  Future<void> loadMore() async {
    if (!hasMore.value || _resizing) return;
    _limit.value = _limit.value + _pageSize;
  }

  /// Reset to the first page (useful when filters change).
  Future<void> resetPages() async {
    hasMore.value = true;
    _limit.value = _pageSize;
  }

  // ── CRUD (require signed-in user) ─────────────────────────────────────────
  /// Adds a new document to the collection.
  ///
  /// Input: A raw JSON map representing the document.
  /// Output: The generated document ID (or `null` on failure).
  /// Example: `add({'name': 'Alice'});`
  late final add = Command.createAsync<Map<String, dynamic>, String?>((
    Map<String, dynamic> data,
  ) async {
    final ref = await _colOrThrow().add(data);
    return ref.id;
  }, initialValue: null);

  /// Creates or replaces a document in the collection.
  ///
  /// Input: A model [T] with a valid `id`.
  /// Behavior: Writes `model.toJson()` at the document path,
  /// merging with existing data if present.
  /// Example: `set(User(id: 'u1', name: 'Alice'));`
  late final set = Command.createAsyncNoResult<T>(
    (T model) => _colOrThrow()
        .doc(model.id)
        .set(model.toJson(), SetOptions(merge: true)),
  );

  /// Partially updates fields on an existing document.
  ///
  /// Input: A [Patch] containing a `doc.id` and `data` map.
  /// Behavior: Only the provided fields are updated; other fields are untouched.
  /// Example: `patch((id: 'u1', data: {'name': 'Bob'}));`
  late final patch = Command.createAsyncNoResult<Patch>(
    (Patch p) => _colOrThrow().doc(p.id).update(p.data),
  );

  /// Fully updates an existing document.
  ///
  /// Input: A model [T] with a valid `id`.
  /// Behavior: Calls `.update()` with the entire serialized model,
  /// replacing all fields with `model.toJson()`.
  /// Example: `update(User(id: 'u1', name: 'Bob'));`
  late final update = Command.createAsyncNoResult<T>(
    (T model) => _colOrThrow().doc(model.id).update(model.toJson()),
  );

  /// Deletes a document from the collection.
  ///
  /// Input: A document ID string.
  /// Behavior: Removes the document at that path.
  /// Example: `delete(model.id);`
  late final delete = Command.createAsyncNoResult<String>(
    (String docId) => _colOrThrow().doc(docId).delete(),
  );

  // ── batch operations ─────────────────────────────────────────────────────

  /// The maximum number of operations per Firestore [WriteBatch].
  static const batchLimit = 500;

  /// Runs [populate] on chunks of [items] of size [batchLimit], committing
  /// each chunk as a single [WriteBatch].
  Future<void> _runBatched<E>(
    List<E> items,
    void Function(WriteBatch batch, CollectionReference<Map<String, dynamic>> col, E item) populate,
  ) async {
    if (items.isEmpty) return;
    final col = _colOrThrow();
    for (var i = 0; i < items.length; i += batchLimit) {
      final end = i + batchLimit;
      final chunk = items.sublist(i, end < items.length ? end : items.length);
      final batch = _fs.batch();
      for (final item in chunk) {
        populate(batch, col, item);
      }
      await batch.commit();
    }
  }

  /// Adds multiple documents to the collection in batched writes.
  ///
  /// Each entry in [items] is a raw JSON map. Document IDs are
  /// auto-generated by Firestore. Unlike the [add] command, this method
  /// is not subject to the `isRunning` guard that prevents concurrent calls.
  ///
  /// Lists exceeding [batchLimit] (500) are automatically split into
  /// sequential batches.
  ///
  /// Example:
  /// ```dart
  /// await repo.batchAdd([{'name': 'Alice'}, {'name': 'Bob'}]);
  /// ```
  Future<void> batchAdd(List<Map<String, dynamic>> items) =>
      _runBatched(items, (batch, col, data) => batch.set(col.doc(), data));

  /// Sets (create-or-merge) multiple documents in batched writes.
  ///
  /// Each model's [JsonModel.id] determines the document path. Existing
  /// documents are merged via `SetOptions(merge: true)`, matching the
  /// behaviour of the single-item [set] command.
  ///
  /// Lists exceeding [batchLimit] (500) are automatically split into
  /// sequential batches.
  ///
  /// Example:
  /// ```dart
  /// await repo.batchSet([user1, user2]);
  /// ```
  Future<void> batchSet(List<T> models) => _runBatched(
    models,
    (batch, col, model) =>
        batch.set(col.doc(model.id), model.toJson(), SetOptions(merge: true)),
  );

  /// Partially updates multiple documents in batched writes.
  ///
  /// Each [Patch] contains a document `id` and a `data` map of fields
  /// to update. Only the specified fields are modified; other fields are
  /// untouched. Matches the behaviour of the single-item [patch] command.
  ///
  /// Lists exceeding [batchLimit] (500) are automatically split into
  /// sequential batches.
  ///
  /// Example:
  /// ```dart
  /// await repo.batchPatch([
  ///   (id: 'u1', data: {'name': 'Alice'}),
  ///   (id: 'u2', data: {'name': 'Bob'}),
  /// ]);
  /// ```
  Future<void> batchPatch(List<Patch> patches) =>
      _runBatched(patches, (batch, col, p) => batch.update(col.doc(p.id), p.data));

  /// Fully updates multiple existing documents in batched writes.
  ///
  /// Each model's [JsonModel.id] determines the document path. The entire
  /// document is replaced with `model.toJson()`, matching the behaviour of
  /// the single-item [update] command.
  ///
  /// Lists exceeding [batchLimit] (500) are automatically split into
  /// sequential batches.
  ///
  /// Example:
  /// ```dart
  /// await repo.batchUpdate([updatedUser1, updatedUser2]);
  /// ```
  Future<void> batchUpdate(List<T> models) => _runBatched(
    models,
    (batch, col, model) => batch.update(col.doc(model.id), model.toJson()),
  );

  /// Deletes multiple documents from the collection in batched writes.
  ///
  /// Unlike the [delete] command, this method is not subject to the
  /// `isRunning` guard that prevents concurrent calls, making it safe to
  /// delete many documents at once.
  ///
  /// Lists exceeding [batchLimit] (500) are automatically split into
  /// sequential batches.
  ///
  /// Example:
  /// ```dart
  /// await repo.batchDelete(['id1', 'id2', 'id3']);
  /// ```
  Future<void> batchDelete(List<String> docIds) =>
      _runBatched(docIds, (batch, col, id) => batch.delete(col.doc(id)));

  // ── internals ─────────────────────────────────────────────────────────────
  void _triggerRebuild() {
    _limit.value = _pageSize; // reset pagination on query/dep/auth change
    _swap(_currentUserUid, clearExisting: true);
  }

  CollectionReference<Map<String, dynamic>> _colOrThrow() {
    final uid = _currentUserUid;
    if (_isAuthGated && uid == null) {
      throw StateError('No signed-in user; repository is detached.');
    }
    return _colRefBuilder(_fs, uid);
  }

  CollectionReference<Map<String, dynamic>> _colWith(String? uid) =>
      _colRefBuilder(_fs, uid);

  Query<Map<String, dynamic>> _queryWith(String? uid) {
    final base = _colWith(uid);
    final qb = _queryNotifier.value;
    final q = qb == null ? base : qb(base);
    return _paginate ? q.limit(_limit.value) : q; // apply live window limit
  }

  Future<void> _resizeWindow() async {
    if (_resizing) return;
    final uid = _currentUserUid;
    if (_isAuthGated && uid == null) return;

    _resizing = true;
    final epoch = ++_epoch;

    isLoading.value = true;

    _cancelSubAsync();
    _modelCache.clear();

    try {
      final q = _queryWith(uid);

      if (_subscribe) {
        _sub = q.snapshots().listen(
          (snap) {
            if (epoch != _epoch) return;
            _handleSnap(snap, fromOneShot: false);
          },
          onError: (_) {
            if (epoch != _epoch) return;
            isLoading.value = false;
          },
        );
      } else {
        await _fetchOneShotEpoch(epoch);
      }
    } finally {
      _resizing = false;
    }
  }

  // Add this field near the other state:
  int _epoch = 0;

  // Utility: cancel without ever blocking a swap
  void _cancelSubAsync() {
    final old = _sub;
    _sub = null;
    if (old != null) {
      // Fire-and-forget; do not await on the hot path.
      unawaited(old.cancel());
    }
  }

  Future<void> _swap(String? uid, {bool clearExisting = true}) async {
    final epoch = ++_epoch;

    isLoading.value = true;
    hasInitialized.value = false;

    _cancelSubAsync();
    _modelCache.clear();

    if (clearExisting) value = const [];

    if (_isAuthGated && uid == null) {
      hasInitialized.value = true;
      hasMore.value = false;
      isLoading.value = false;
      return;
    }

    hasMore.value = true;

    final q = _queryWith(uid);

    // Prime from CACHE for instant UI, if available.
    try {
      final cacheSnap = await q.get(const GetOptions(source: Source.cache));
      if (epoch != _epoch) return; // stale
      if (cacheSnap.docs.isNotEmpty) {
        _handleSnap(cacheSnap, fromOneShot: false);
      }
    } catch (_) {
      if (epoch != _epoch) return;
      // Cache might be empty on first run; ignore.
    }

    if (_subscribe) {
      _sub = q.snapshots().listen(
        (snap) {
          if (epoch != _epoch) return;
          _handleSnap(snap, fromOneShot: false);
        },
        onError: (_) {
          if (epoch != _epoch) return;
          hasInitialized.value = true;
          isLoading.value = false;
        },
      );
    } else {
      await _fetchOneShotEpoch(epoch);
    }
  }

  Future<void> _fetchOneShotEpoch(int epoch) async {
    try {
      final uid = _currentUserUid;
      if (_isAuthGated && uid == null) {
        if (epoch != _epoch) return;
        hasInitialized.value = true;
        return;
      }

      final snap = await _queryWith(uid).get();
      if (epoch != _epoch) return;
      _handleSnap(snap, fromOneShot: true);
    } finally {
      if (epoch == _epoch) {
        isLoading.value = false;
        hasInitialized.value = true;
      }
    }
  }

  void _handleSnap(
    QuerySnapshot<Map<String, dynamic>> snap, {
    bool fromOneShot = false,
  }) {
    // Incremental: only re-parse changed documents.
    for (final change in snap.docChanges) {
      final doc = change.doc;
      if (change.type == DocumentChangeType.removed) {
        _modelCache.remove(doc.id);
      } else if (doc.data() != null) {
        final data = Map<String, dynamic>.from(doc.data()!)
          ..['id'] = doc.id
          ..['parentId'] = parentIdOf(doc.reference);
        _modelCache[doc.id] = _fromJson(data);
      }
    }

    // Build list in snapshot order using cached models.
    final list = <T>[];
    final activeIds = <String>{};
    for (final doc in snap.docs) {
      activeIds.add(doc.id);
      final model = _modelCache[doc.id];
      if (model != null) {
        list.add(model);
      } else {
        // Fallback: parse directly if not in cache.
        final data = Map<String, dynamic>.from(doc.data())
          ..['id'] = doc.id
          ..['parentId'] = parentIdOf(doc.reference);
        final m = _fromJson(data);
        _modelCache[doc.id] = m;
        list.add(m);
      }
      _itemNotifiers.putIfAbsent(doc.id, () => ValueNotifier<T?>(null)).value =
          _modelCache[doc.id];
    }

    // Prune notifiers for documents no longer in the snapshot to prevent
    // unbounded growth of _itemNotifiers over long sessions.
    _itemNotifiers.removeWhere((id, notifier) {
      if (!activeIds.contains(id)) {
        notifier.value = null;
        return true;
      }
      return false;
    });

    value = list;
    isLoading.value = false;
    hasInitialized.value = true;
    hasMore.value = snap.docs.length >= _limit.value;
  }

  // ── lifecycle ─────────────────────────────────────────────────────────────
  @override
  void dispose() {
    _limit.removeListener(_resizeWindow);
    _cancelSubAsync();
    _authUid?.removeListener(_triggerRebuild);
    _queryNotifier.removeListener(_triggerRebuild);
    for (final d in _deps) {
      d.removeListener(_triggerRebuild);
    }
    add.dispose();
    set.dispose();
    patch.dispose();
    update.dispose();
    delete.dispose();
    _queryNotifier.dispose();
    isLoading.dispose();
    hasInitialized.dispose();
    for (final n in _itemNotifiers.values) {
      n.dispose();
    }
    _limit.dispose();
    hasMore.dispose();
    super.dispose();
  }
}
