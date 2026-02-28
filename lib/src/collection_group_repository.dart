import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:command_it/command_it.dart';
import 'package:flutter/foundation.dart';

import 'collection_repository.dart' show QueryMutator;
import 'json_model.dart';

/// A builder function that produces a Firestore [Query] for a collection group.
///
/// Parameters:
/// - [fs]: The active [FirebaseFirestore] instance.
/// - [uid]: The current user ID, or `null` if not authenticated.
///
/// Returns:
/// - A [Query] targeting the desired collection group, typically created via
///   `fs.collectionGroup('name')` with optional auth-scoped filters.
typedef QueryRefBuilder =
    Query<Map<String, dynamic>> Function(FirebaseFirestore fs, String? uid);

/// Represents a partial update to a Firestore document identified by path.
///
/// Fields:
/// - [path]: The full document path (e.g. `users/u1/tasks/t1`).
/// - [data]: A map of fields and values to update. Only the specified
///   fields will be modified; all others remain unchanged.
typedef GroupPatch = ({String path, Map<String, Object?> data});

/// A Firestore collection-group repository for responsive UIs:
/// - Queries across all collections with the same name via `collectionGroup()`
/// - Reacts to auth changes and extra dependencies
/// - Supports live queries (subscribe) or one-shot fetches
/// - Exposes pagination via a live "window" (limit that grows with `loadMore`)
/// - Keeps per-item notifiers keyed by full document path
///
/// Unlike [FirestoreCollectionRepository], this repo accepts a [Query] builder
/// instead of a [CollectionReference] builder. Because collection-group queries
/// return a `Query` (not a `CollectionReference`), `.add()` is unavailable.
/// Write commands use full document paths instead of document IDs.
///
/// Works with or without authentication. Omit [authUid] for public
/// collection groups that should query Firestore immediately without waiting
/// for a signed-in user.
class FirestoreCollectionGroupRepository<T extends JsonModel>
    extends ValueNotifier<List<T>> {
  /// Creates a new [FirestoreCollectionGroupRepository].
  ///
  /// Parameters:
  /// - [firestore]: The active [FirebaseFirestore] instance. Defaults to
  ///   [FirebaseFirestore.instance].
  /// - [fromJson]: Converts a raw Firestore document map into a model [T].
  /// - [queryRefBuilder]: Resolves the collection group query, often created
  ///   via `fs.collectionGroup('name')`.
  /// - [queryBuilder]: (Optional) Initial query mutator to apply filters,
  ///   ordering, or limits.
  /// - [authUid]: (Optional) A listenable source of the current user ID;
  ///   repository will rebuild automatically when this changes. Omit for
  ///   public collection groups that don't require authentication.
  /// - [dependencies]: (Optional) Extra [Listenable]s to watch; any change
  ///   triggers a query refresh.
  /// - [subscribe]: If true (default), repository stays in sync with
  ///   live Firestore updates. If false, fetches a one-shot snapshot only.
  /// - [pageSize]: Initial page size for paginated queries (default: 25).
  /// - [paginate]: If true (default), enables pagination via `loadMore()`.
  FirestoreCollectionGroupRepository({
    required T Function(Map<String, dynamic>) fromJson,
    required QueryRefBuilder queryRefBuilder,
    FirebaseFirestore? firestore,
    QueryMutator? queryBuilder,
    AuthUidListenable? authUid,
    List<Listenable> dependencies = const [],
    bool subscribe = true,
    int pageSize = 25,
    bool paginate = true,
  }) : _fs = firestore ?? FirebaseFirestore.instance,
       _fromJson = fromJson,
       _queryRefBuilder = queryRefBuilder,
       _authUid = authUid,
       _subscribe = subscribe,
       _deps = List.unmodifiable(dependencies),
       _queryNotifier = ValueNotifier<QueryMutator?>(queryBuilder),
       _limit = ValueNotifier<int>(pageSize),
       _pageSize = pageSize,
       _paginate = paginate,
       super(const []) {
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
  final QueryRefBuilder _queryRefBuilder;
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
  bool _resizing = false;

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _sub;

  /// Per-item notifiers keyed by full document path, kept in sync with the
  /// current list. Unlike the collection repo which keys by doc ID, this uses
  /// the full path to distinguish documents with the same ID under different
  /// parent collections.
  final Map<String, ValueNotifier<T?>> _itemNotifiers = {};

  /// Model cache for incremental snapshot processing, keyed by full document
  /// path.
  final Map<String, T> _modelCache = {};

  /// Whether the repository is currently fetching data from Firestore.
  ///
  /// `true` during initial load, auth transitions, pagination, and refreshes.
  final ValueNotifier<bool> isLoading = ValueNotifier<bool>(true);

  /// Whether the repository has completed its first query.
  ///
  /// `false` until the first snapshot (or cache prime) arrives.
  final ValueNotifier<bool> hasInitialized = ValueNotifier<bool>(false);

  /// `true` when the first query has not yet completed.
  bool get isInitializing => !hasInitialized.value && isLoading.value;

  /// `true` when a subsequent fetch is in progress after initial load.
  bool get isRefreshing => hasInitialized.value && isLoading.value;

  /// `true` when initialization is complete, loading is done, and the
  /// collection group is empty.
  bool get showEmpty =>
      hasInitialized.value && !isLoading.value && value.isEmpty;

  String? get _currentUserUid => _authUid?.value;

  /// Whether this repo requires authentication.
  bool get _isAuthGated => _authUid != null;

  // ── public API ────────────────────────────────────────────────────────────

  /// Swap the active query; pass `null` to clear and use base query.
  void setQuery(QueryMutator? qb) {
    _queryNotifier.value = qb;
  }

  /// Force a re-attach / refetch using current auth, deps, and query.
  Future<void> refresh() => _swap(_currentUserUid, clearExisting: true);

  /// Per-item notifier keyed by full document path (kept in sync from the
  /// collection group results).
  ValueNotifier<T?> notifierFor(String docPath) =>
      _itemNotifiers.putIfAbsent(docPath, () => ValueNotifier<T?>(null));

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

  // ── CRUD (by document path) ─────────────────────────────────────────────

  /// Creates or merges a document at a specific path.
  ///
  /// Input: A record with `path` (full document path) and `model` (a [T]).
  /// Behavior: Writes `model.toJson()` at the document path,
  /// merging with existing data if present.
  late final set = Command.createAsyncNoResult<({String path, T model})>(
    (r) {
      _guardAuth();
      return _fs.doc(r.path).set(r.model.toJson(), SetOptions(merge: true));
    },
  );

  /// Replaces all fields on an existing document.
  ///
  /// Input: A record with `path` (full document path) and `model` (a [T]).
  /// Behavior: Calls `.update()` with the entire serialized model.
  late final update = Command.createAsyncNoResult<({String path, T model})>(
    (r) {
      _guardAuth();
      return _fs.doc(r.path).update(r.model.toJson());
    },
  );

  /// Partially updates specific fields on an existing document.
  ///
  /// Input: A [GroupPatch] containing a `path` and `data` map.
  /// Behavior: Only the provided fields are updated.
  late final patch = Command.createAsyncNoResult<GroupPatch>(
    (r) {
      _guardAuth();
      return _fs.doc(r.path).update(r.data);
    },
  );

  /// Deletes a document by its full path.
  ///
  /// Input: A full document path string.
  late final delete = Command.createAsyncNoResult<String>(
    (path) {
      _guardAuth();
      return _fs.doc(path).delete();
    },
  );

  // ── internals ─────────────────────────────────────────────────────────────

  void _guardAuth() {
    if (_isAuthGated && _currentUserUid == null) {
      throw StateError('No signed-in user; repository is detached.');
    }
  }

  void _triggerRebuild() {
    _limit.value = _pageSize;
    _swap(_currentUserUid, clearExisting: true);
  }

  Query<Map<String, dynamic>> _queryWith(String? uid) {
    final base = _queryRefBuilder(_fs, uid);
    final qb = _queryNotifier.value;
    final q = qb == null ? base : qb(base);
    return _paginate ? q.limit(_limit.value) : q;
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

  int _epoch = 0;

  void _cancelSubAsync() {
    final old = _sub;
    _sub = null;
    if (old != null) {
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
      if (epoch != _epoch) return;
      if (cacheSnap.docs.isNotEmpty) {
        _handleSnap(cacheSnap, fromOneShot: false);
      }
    } catch (_) {
      if (epoch != _epoch) return;
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
    // Incremental: only re-parse changed documents, keyed by path.
    for (final change in snap.docChanges) {
      final doc = change.doc;
      final path = doc.reference.path;
      if (change.type == DocumentChangeType.removed) {
        _modelCache.remove(path);
      } else if (doc.data() != null) {
        final data = Map<String, dynamic>.from(doc.data()!)
          ..['id'] = doc.id
          ..['parentId'] = doc.reference.parent.parent?.id;
        _modelCache[path] = _fromJson(data);
      }
    }

    // Build list in snapshot order using cached models.
    final list = <T>[];
    final activePaths = <String>{};
    for (final doc in snap.docs) {
      final path = doc.reference.path;
      activePaths.add(path);
      final model = _modelCache[path];
      if (model != null) {
        list.add(model);
      } else {
        final data = Map<String, dynamic>.from(doc.data())
          ..['id'] = doc.id
          ..['parentId'] = doc.reference.parent.parent?.id;
        final m = _fromJson(data);
        _modelCache[path] = m;
        list.add(m);
      }
      _itemNotifiers
          .putIfAbsent(path, () => ValueNotifier<T?>(null))
          .value = _modelCache[path];
    }

    // Prune notifiers for documents no longer in the snapshot.
    _itemNotifiers.removeWhere((path, notifier) {
      if (!activePaths.contains(path)) {
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
    set.dispose();
    update.dispose();
    patch.dispose();
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
