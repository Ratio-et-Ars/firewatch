import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:command_it/command_it.dart';
import 'package:flutter/foundation.dart';

import 'json_model.dart';

typedef ColRefBuilder = CollectionReference<Map<String, dynamic>> Function(
  FirebaseFirestore fs,
  String? uid,
);

/// Mutates a base collection query (e.g., add where/order/limit).
typedef QueryMutator = Query<Map<String, dynamic>> Function(
    Query<Map<String, dynamic>> base);

typedef Patch = ({String id, Map<String, Object?> data});

/// A Firestore collection repository designed for responsive UIs:
/// - Reacts to auth changes and extra dependencies
/// - Supports live queries (subscribe) or one-shot fetches
/// - Exposes pagination via a live "window" (limit that grows with `loadMore`)
/// - Keeps per-item notifiers in sync for efficient item detail widgets
class FirestoreCollectionRepository<T extends JsonModel>
    extends ValueNotifier<List<T>> {
  FirestoreCollectionRepository({
    required FirebaseFirestore firestore,
    required T Function(Map<String, dynamic>) fromJson,
    required ColRefBuilder colRefBuilder,
    QueryMutator? queryBuilder, // optional initial query
    AuthUidListenable? authUid, // optional auth listenable
    List<Listenable> dependencies = const [], // extra listenables to watch
    bool subscribe = true, // realtime vs one-shot
    int pageSize = 25, // default page size
  })  : _fs = firestore,
        _fromJson = fromJson,
        _colRefBuilder = colRefBuilder,
        _authUid = authUid,
        _subscribe = subscribe,
        _deps = List.unmodifiable(dependencies),
        _queryNotifier = ValueNotifier<QueryMutator?>(queryBuilder),
        _limit = ValueNotifier<int>(pageSize),
        _pageSize = pageSize,
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
  final ValueNotifier<int> _limit;
  final ValueNotifier<bool> hasMore = ValueNotifier<bool>(true);
  bool _resizing = false; // avoid duplicate resubscribes on rapid changes

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _sub;

  /// Per-item notifiers stay in sync with the current list.
  final Map<String, ValueNotifier<T?>> _itemNotifiers = {};

  /// Loading flags to help drive UI states.
  final ValueNotifier<bool> isLoading = ValueNotifier<bool>(true);
  final ValueNotifier<bool> hasInitialized = ValueNotifier<bool>(false);

  bool get isInitializing => !hasInitialized.value && isLoading.value;
  bool get isRefreshing => hasInitialized.value && isLoading.value;
  bool get showEmpty =>
      hasInitialized.value && !isLoading.value && value.isEmpty;

  String? get _currentUserUid => _authUid?.value;

  // ── public API ────────────────────────────────────────────────────────────

  /// Swap the active query; pass `null` to clear and use base collection.
  void setQuery(QueryMutator? qb) {
    if (identical(_queryNotifier.value, qb)) return;
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
  late final add = Command.createAsync<Map<String, dynamic>, String?>((
    Map<String, dynamic> data,
  ) async {
    final ref = await _colOrThrow().add(data);
    return ref.id;
  }, initialValue: null);

  late final set = Command.createAsyncNoResult<T>(
    (T model) => _colOrThrow()
        .doc(model.id)
        .set(model.toJson(), SetOptions(merge: true)),
  );

  late final patch = Command.createAsyncNoResult<Patch>(
    (Patch p) => _colOrThrow().doc(p.id).update(p.data),
  );

  late final update = Command.createAsyncNoResult<T>(
    (T model) => _colOrThrow().doc(model.id).update(model.toJson()),
  );

  late final delete = Command.createAsyncNoResult<String>(
    (String docId) => _colOrThrow().doc(docId).delete(),
  );

  // ── internals ─────────────────────────────────────────────────────────────
  void _triggerRebuild() => _swap(_currentUserUid, clearExisting: true);

  CollectionReference<Map<String, dynamic>> _colOrThrow() {
    final uid = _currentUserUid;
    if (uid == null) {
      throw StateError('No signed-in user; repository is detached.');
    }
    return _colRefBuilder(_fs, uid);
  }

  CollectionReference<Map<String, dynamic>> _colWith(String uid) =>
      _colRefBuilder(_fs, uid);

  Query<Map<String, dynamic>> _queryWith(String uid) {
    final base = _colWith(uid);
    final qb = _queryNotifier.value;
    final q = qb == null ? base : qb(base);
    return q.limit(_limit.value); // apply live window limit
  }

  Future<void> _resizeWindow() async {
    if (_resizing) return;
    final uid = _currentUserUid;
    if (uid == null) return;
    _resizing = true;
    isLoading.value = true;

    await _sub?.cancel();
    try {
      final q = _queryWith(uid);
      if (_subscribe) {
        _sub = q.snapshots().listen(
              (snap) => _handleSnap(snap, fromOneShot: false),
              onError: (_) => isLoading.value = false,
            );
      } else {
        await _fetchOneShot();
      }
    } finally {
      _resizing = false;
      // isLoading flips false in _handleSnap when data arrives.
    }
  }

  Future<void> _swap(String? uid, {bool clearExisting = true}) async {
    isLoading.value = true;
    hasInitialized.value = false;
    await _sub?.cancel();
    if (clearExisting) value = const [];

    if (uid == null) {
      hasInitialized.value = true;
      hasMore.value = false;
      isLoading.value = false;
      return;
    }

    hasMore.value = true;
    final q = _queryWith(uid);
    if (_subscribe) {
      _sub = q.snapshots().listen(
        _handleSnap,
        onError: (_) {
          hasInitialized.value = true;
          isLoading.value = false;
        },
      );
    } else {
      await _fetchOneShot();
    }
  }

  Future<void> _fetchOneShot() async {
    try {
      final uid = _currentUserUid;
      if (uid == null) {
        hasInitialized.value = true;
        return;
      }
      final snap = await _queryWith(uid).get();
      _handleSnap(snap, fromOneShot: true);
    } finally {
      isLoading.value = false;
    }
  }

  void _handleSnap(
    QuerySnapshot<Map<String, dynamic>> snap, {
    bool fromOneShot = false,
  }) {
    final list = <T>[];
    for (final doc in snap.docs) {
      final data = Map<String, dynamic>.from(doc.data())..['id'] = doc.id;
      final model = _fromJson(data);
      list.add(model);
      _itemNotifiers.putIfAbsent(doc.id, () => ValueNotifier<T?>(model)).value =
          model;
    }

    value = list;
    isLoading.value = false;
    hasInitialized.value = true;
    hasMore.value = snap.docs.length >= _limit.value;
  }

  // ── lifecycle ─────────────────────────────────────────────────────────────
  @override
  void dispose() {
    _limit.removeListener(_resizeWindow);
    _sub?.cancel();
    _authUid?.removeListener(_triggerRebuild);
    _queryNotifier.removeListener(_triggerRebuild);
    for (final d in _deps) {
      d.removeListener(_triggerRebuild);
    }
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
