import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import 'json_model.dart';

/// Shared auth-reactive lifecycle primitives used by every Firewatch
/// repository (doc, collection, collection-group).
///
/// Centralizing these is deliberate: the epoch guard, the subscription
/// cancel semantics, and the auth-gating checks are exactly the pieces that
/// previously drifted between hand-maintained copies and caused bugs
/// (use-after-dispose, sign-out error loops). Keeping one implementation makes
/// that class of drift impossible.
///
/// This is an internal building block and is not exported from the package's
/// public API.
@internal
mixin AuthReactiveLifecycle {
  /// The auth UID source, or `null` for public/unauthenticated repos.
  AuthUidListenable? get authUidListenable;

  /// The current user UID (or `null` when signed out / public).
  String? get currentUserUid => authUidListenable?.value;

  /// Whether this repo requires authentication. True when an auth source was
  /// provided; false for public/unauthenticated repos.
  bool get isAuthGated => authUidListenable != null;

  /// Epoch counter used to discard stale async operations. Every swap/resize
  /// captures the current epoch and bails if it changes (a newer swap, or
  /// dispose, ran in the meantime).
  int epoch = 0;

  /// The active snapshot subscription, if any.
  StreamSubscription<Object?>? sub;

  /// Cancel the active subscription, awaiting the cancel. Used on sign-out so
  /// the native Firestore listener is fully torn down before the auth token is
  /// invalidated (otherwise the dying listener can fire `PERMISSION_DENIED`
  /// against the revoked token).
  Future<void> cancelSub() async {
    final old = sub;
    sub = null;
    if (old != null) {
      await old.cancel();
    }
  }

  /// Cancel the active subscription without blocking the hot path. Safe for
  /// auth/query/dependency changes where ordering with the native layer does
  /// not matter (the epoch guard discards any late events).
  void cancelSubAsync() {
    final old = sub;
    sub = null;
    if (old != null) {
      unawaited(old.cancel());
    }
  }
}

/// Shared base for the collection and collection-group repositories.
///
/// Both are auth-reactive, cache-first, live-window-paginated list repos over a
/// Firestore [Query]. They differ in only two behavioural details, exposed as
/// hooks:
/// - [queryBase] — how the base query is resolved for a UID (a
///   `CollectionReference` for the collection repo, a `collectionGroup` query
///   for the group repo).
/// - [keyOf] — the cache/notifier key for a document (the doc ID for the
///   collection repo; the full document path for the group repo, since a
///   collection group can contain same-ID docs under different parents).
///
/// Everything else — the epoch-guarded swap, cache priming, live window
/// resizing, one-shot fetch, incremental snapshot handling, per-item
/// notifiers, sign-out handling, retries, and disposal — lives here so it
/// cannot drift between the two repos.
///
/// This is an internal building block and is not exported from the package's
/// public API.
abstract class QueryListRepositoryBase<T extends JsonModel>
    extends ValueNotifier<List<T>> with AuthReactiveLifecycle {
  QueryListRepositoryBase({
    required T Function(Map<String, dynamic>) fromJson,
    FirebaseFirestore? firestore,
    AuthUidListenable? authUid,
    QueryMutator? queryBuilder,
    List<Listenable> dependencies = const [],
    bool subscribe = true,
    int pageSize = 25,
    bool paginate = true,
    FirewatchErrorHandler? onError,
    int maxRetries = 0,
    Duration retryDelay = const Duration(milliseconds: 500),
  })  : fs = firestore ?? FirebaseFirestore.instance,
        _fromJson = fromJson,
        _authUid = authUid,
        _subscribe = subscribe,
        _deps = List.unmodifiable(dependencies),
        _queryNotifier = ValueNotifier<QueryMutator?>(queryBuilder),
        _limit = ValueNotifier<int>(pageSize),
        _pageSize = pageSize,
        _paginate = paginate,
        _onError = onError,
        _maxRetries = maxRetries,
        _retryDelay = retryDelay,
        super(const []) {
    _authUid?.addListener(_triggerRebuild);
    for (final d in _deps) {
      d.addListener(_triggerRebuild);
    }
    _queryNotifier.addListener(_triggerRebuild);
    _limit.addListener(_resizeWindow);
  }

  // ── shared fields ─────────────────────────────────────────────────────────
  @protected
  final FirebaseFirestore fs;
  final AuthUidListenable? _authUid;
  final T Function(Map<String, dynamic>) _fromJson;
  final bool _subscribe;
  final FirewatchErrorHandler? _onError;
  final List<Listenable> _deps;
  final int _maxRetries;
  final Duration _retryDelay;
  int _retryCount = 0;

  final ValueNotifier<QueryMutator?> _queryNotifier;

  // pagination state
  final int _pageSize;
  final bool _paginate;
  final ValueNotifier<int> _limit;

  /// Whether there are more documents beyond the current page.
  final ValueNotifier<bool> hasMore = ValueNotifier<bool>(true);
  bool _resizing = false;
  bool _pendingResize = false; // a loadMore arrived mid-resize; re-run after

  /// Per-item notifiers kept in sync with the current list, keyed by [keyOf].
  final Map<String, ValueNotifier<T?>> _itemNotifiers = {};

  /// Model cache for incremental snapshot processing, keyed by [keyOf].
  final Map<String, T> _modelCache = {};

  /// Whether the repository is currently fetching data from Firestore.
  final ValueNotifier<bool> isLoading = ValueNotifier<bool>(true);

  /// Whether the repository has completed its first query.
  final ValueNotifier<bool> hasInitialized = ValueNotifier<bool>(false);

  /// `true` when the first query has not yet completed.
  bool get isInitializing => !hasInitialized.value && isLoading.value;

  /// `true` when a subsequent fetch is in progress after initial load.
  bool get isRefreshing => hasInitialized.value && isLoading.value;

  /// `true` when initialization is complete, loading is done, and the list is
  /// empty.
  bool get showEmpty =>
      hasInitialized.value && !isLoading.value && value.isEmpty;

  @override
  @internal
  AuthUidListenable? get authUidListenable => _authUid;

  // ── hooks for subclasses ──────────────────────────────────────────────────

  /// Resolves the base query (before [queryBuilder] and the live-window limit)
  /// for the given [uid].
  @protected
  Query<Map<String, dynamic>> queryBase(String? uid);

  /// The cache / per-item-notifier key for a document. The collection repo
  /// uses the doc ID; the group repo uses the full document path.
  @protected
  String keyOf(DocumentSnapshot<Map<String, dynamic>> doc);

  /// Runs the initial query. Subclasses call this at the end of their
  /// constructor (after their own fields are initialized).
  @protected
  void start() {
    _swap(currentUserUid, clearExisting: true);
  }

  /// Throws if the repo is auth-gated and there is no signed-in user.
  @protected
  void guardAuth() {
    if (isAuthGated && currentUserUid == null) {
      throw StateError('No signed-in user; repository is detached.');
    }
  }

  // ── public API ────────────────────────────────────────────────────────────

  /// Swap the active query; pass `null` to clear and use the base query.
  void setQuery(QueryMutator? qb) {
    _queryNotifier.value = qb; // listener triggers _swap
  }

  /// Force a re-attach / refetch using current auth, deps, and query.
  Future<void> refresh() => _swap(currentUserUid, clearExisting: true);

  /// Per-item notifier (kept in sync from the results), keyed by [keyOf].
  ValueNotifier<T?> notifierFor(String key) =>
      _itemNotifiers.putIfAbsent(key, () => ValueNotifier<T?>(null));

  /// Load the next page. In realtime mode this increases the live window.
  ///
  /// Safe to call while a previous resize is still settling: the growth is
  /// coalesced and applied once the in-flight resize completes, so a rapid
  /// second tap (or a `loadMore` during an auth/dependency settle) is never
  /// silently dropped.
  Future<void> loadMore() async {
    if (!hasMore.value) return;
    _limit.value = _limit.value + _pageSize;
  }

  /// Reset to the first page (useful when filters change).
  Future<void> resetPages() async {
    hasMore.value = true;
    _limit.value = _pageSize;
  }

  // ── internals ─────────────────────────────────────────────────────────────

  void _triggerRebuild() {
    _retryCount = 0; // fresh start on auth/dep/query change
    _limit.value = _pageSize; // reset pagination on query/dep/auth change
    _swap(currentUserUid, clearExisting: true);
  }

  Query<Map<String, dynamic>> _queryWith(String? uid) {
    final base = queryBase(uid);
    final qb = _queryNotifier.value;
    final q = qb == null ? base : qb(base);
    return _paginate ? q.limit(_limit.value) : q; // apply live window limit
  }

  Future<void> _resizeWindow() async {
    // A resize is already running; remember that the window grew again so we
    // re-run once it finishes (instead of dropping the request).
    if (_resizing) {
      _pendingResize = true;
      return;
    }
    final uid = currentUserUid;
    if (isAuthGated && uid == null) return;

    _resizing = true;
    final ep = ++epoch;

    isLoading.value = true;

    cancelSubAsync();
    _modelCache.clear();

    try {
      final q = _queryWith(uid);

      if (_subscribe) {
        sub = q.snapshots().listen(
          (snap) {
            if (ep != epoch) return;
            _handleSnap(snap);
          },
          onError: (Object error, StackTrace stackTrace) =>
              _onStreamError(error, stackTrace, ep, uid, retry: false),
        );
      } else {
        await _fetchOneShotEpoch(ep);
      }
    } finally {
      _resizing = false;
      if (_pendingResize) {
        _pendingResize = false;
        unawaited(_resizeWindow()); // apply the coalesced growth
      }
    }
  }

  Future<void> _swap(String? uid, {bool clearExisting = true}) async {
    final ep = ++epoch;
    _pendingResize = false; // a full reload supersedes any pending page growth

    isLoading.value = true;
    hasInitialized.value = false;

    if (isAuthGated && uid == null) {
      // Await cancel on sign-out so the native Firestore listener is fully
      // torn down before the auth token is invalidated.
      await cancelSub();
      _modelCache.clear();
      // After the await, the repo may have been disposed by a registry.
      if (ep != epoch) return;
      if (clearExisting) value = const [];
      hasInitialized.value = true;
      hasMore.value = false;
      isLoading.value = false;
      return;
    }

    // On the hot path (auth/query change), fire-and-forget is fine.
    cancelSubAsync();
    _modelCache.clear();

    if (clearExisting) value = const [];

    hasMore.value = true;

    final q = _queryWith(uid);

    // Prime from CACHE for instant UI, if available.
    try {
      final cacheSnap = await q.get(const GetOptions(source: Source.cache));
      if (ep != epoch) return; // stale
      if (cacheSnap.docs.isNotEmpty) {
        _handleSnap(cacheSnap);
      }
    } catch (_) {
      if (ep != epoch) return;
      // Cache might be empty on first run; ignore.
    }

    if (_subscribe) {
      sub = q.snapshots().listen(
        (snap) {
          if (ep != epoch) return;
          _handleSnap(snap);
        },
        onError: (Object error, StackTrace stackTrace) =>
            _onStreamError(error, stackTrace, ep, uid, retry: true),
      );
    } else {
      await _fetchOneShotEpoch(ep);
    }
  }

  /// Unified stream error handling for both [_swap] and [_resizeWindow].
  ///
  /// Always suppresses errors from a detached (signed-out) repo, then — when
  /// [retry] is enabled and a retry budget remains — re-attaches with backoff.
  void _onStreamError(
    Object error,
    StackTrace stackTrace,
    int ep,
    String? uid, {
    required bool retry,
  }) {
    if (ep != epoch) return;
    // Don't surface errors if the repo has been detached (auth-gated with null
    // UID — e.g. user signed out). The old listener can fire PERMISSION_DENIED
    // before its cancel reaches the native layer; the epoch may still match
    // because _triggerRebuild increments it and _swap returns early for null
    // UID, leaving the old listener alive briefly.
    if (isAuthGated && currentUserUid == null) {
      cancelSubAsync();
      isLoading.value = false;
      return;
    }

    _onError?.call(error, stackTrace);

    if (retry && _retryCount < _maxRetries) {
      _retryCount++;
      Future.delayed(_retryDelay * _retryCount, () {
        if (ep == epoch) {
          _swap(uid, clearExisting: false);
        }
      });
    } else {
      hasInitialized.value = true;
      isLoading.value = false;
    }
  }

  Future<void> _fetchOneShotEpoch(int ep) async {
    try {
      final uid = currentUserUid;
      if (isAuthGated && uid == null) {
        if (ep != epoch) return;
        hasInitialized.value = true;
        return;
      }

      final snap = await _queryWith(uid).get();
      if (ep != epoch) return;
      _handleSnap(snap);
    } catch (error, stackTrace) {
      if (ep != epoch) return;
      _onError?.call(error, stackTrace);
    } finally {
      if (ep == epoch) {
        isLoading.value = false;
        hasInitialized.value = true;
      }
    }
  }

  void _handleSnap(QuerySnapshot<Map<String, dynamic>> snap) {
    _retryCount = 0; // successful snapshot → reset retry counter
    // Incremental: only re-parse changed documents, keyed by keyOf.
    for (final change in snap.docChanges) {
      final doc = change.doc;
      final key = keyOf(doc);
      if (change.type == DocumentChangeType.removed) {
        _modelCache.remove(key);
      } else if (doc.data() != null) {
        final data = Map<String, dynamic>.from(doc.data()!)
          ..['id'] = doc.id
          ..['parentId'] = parentIdOf(doc.reference);
        _modelCache[key] = _fromJson(data);
      }
    }

    // Build list in snapshot order using cached models.
    final list = <T>[];
    final activeKeys = <String>{};
    for (final doc in snap.docs) {
      final key = keyOf(doc);
      activeKeys.add(key);
      final model = _modelCache[key];
      if (model != null) {
        list.add(model);
      } else {
        // Fallback: parse directly if not in cache.
        final data = Map<String, dynamic>.from(doc.data())
          ..['id'] = doc.id
          ..['parentId'] = parentIdOf(doc.reference);
        final m = _fromJson(data);
        _modelCache[key] = m;
        list.add(m);
      }
      _itemNotifiers.putIfAbsent(key, () => ValueNotifier<T?>(null)).value =
          _modelCache[key];
    }

    // Prune notifiers for documents no longer in the snapshot to prevent
    // unbounded growth of _itemNotifiers over long sessions.
    _itemNotifiers.removeWhere((key, notifier) {
      if (!activeKeys.contains(key)) {
        notifier.value = null;
        return true;
      }
      return false;
    });

    value = list;
    isLoading.value = false;
    hasInitialized.value = true;
    // Without pagination the live window doesn't apply, so there is never
    // "more" to load — the snapshot already holds the full result set.
    hasMore.value = _paginate && snap.docs.length >= _limit.value;
  }

  // ── lifecycle ─────────────────────────────────────────────────────────────

  /// Tears down the shared lifecycle. Subclasses override [dispose] to dispose
  /// their own Commands and then call `super.dispose()`.
  @override
  @mustCallSuper
  void dispose() {
    ++epoch; // prevent in-flight async ops from touching disposed notifiers
    _limit.removeListener(_resizeWindow);
    cancelSubAsync();
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
