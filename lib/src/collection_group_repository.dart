import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:command_it/command_it.dart';
import 'package:flutter/foundation.dart';

import 'json_model.dart';
import 'query_list_repository_base.dart';

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
///
/// **⚠️ Security:** a collection-group query reads documents with the given
/// name across **every** parent/tenant. This repo passes the current `uid` to
/// [queryRefBuilder] but does **not** add any owner filter for you. Scope the
/// query yourself — e.g. `fs.collectionGroup('tasks').where('ownerId',
/// isEqualTo: uid)` — and back it with a matching collection-group security
/// rule. An unfiltered builder will read other users' documents.
///
/// The auth-reactive lifecycle (cache-first swap, epoch-guarded races, live
/// window resizing, sign-out handling, disposal) lives in
/// [QueryListRepositoryBase], shared with [FirestoreCollectionRepository].
/// This repo keys items by full document path so same-ID documents under
/// different parents don't collide.
class FirestoreCollectionGroupRepository<T extends JsonModel>
    extends QueryListRepositoryBase<T> {
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
    required super.fromJson,
    required QueryRefBuilder queryRefBuilder,
    super.firestore,
    super.queryBuilder,
    super.authUid,
    super.dependencies,
    super.subscribe,
    super.pageSize,
    super.paginate,
    super.onError,
  }) : _queryRefBuilder = queryRefBuilder {
    start();
  }

  final QueryRefBuilder _queryRefBuilder;

  // ── base hooks ────────────────────────────────────────────────────────────
  @override
  Query<Map<String, dynamic>> queryBase(String? uid) =>
      _queryRefBuilder(fs, uid);

  /// Collection groups can contain same-ID documents under different parents,
  /// so the full document path is the cache/notifier key.
  @override
  String keyOf(DocumentSnapshot<Map<String, dynamic>> doc) =>
      doc.reference.path;

  // ── CRUD (by document path) ─────────────────────────────────────────────

  /// Creates or merges a document at a specific path.
  ///
  /// Input: A record with `path` (full document path) and `model` (a [T]).
  /// Behavior: Writes `model.toJson()` at the document path,
  /// merging with existing data if present.
  late final set = Command.createAsyncNoResult<({String path, T model})>(
    (r) {
      guardAuth();
      return fs.doc(r.path).set(r.model.toJson(), SetOptions(merge: true));
    },
  );

  /// Replaces all fields on an existing document.
  ///
  /// Input: A record with `path` (full document path) and `model` (a [T]).
  /// Behavior: Calls `.update()` with the entire serialized model.
  late final update = Command.createAsyncNoResult<({String path, T model})>(
    (r) {
      guardAuth();
      return fs.doc(r.path).update(r.model.toJson());
    },
  );

  /// Partially updates specific fields on an existing document.
  ///
  /// Input: A [GroupPatch] containing a `path` and `data` map.
  /// Behavior: Only the provided fields are updated.
  late final patch = Command.createAsyncNoResult<GroupPatch>(
    (r) {
      guardAuth();
      return fs.doc(r.path).update(r.data);
    },
  );

  /// Deletes a document by its full path.
  ///
  /// Input: A full document path string.
  late final delete = Command.createAsyncNoResult<String>(
    (path) {
      guardAuth();
      return fs.doc(path).delete();
    },
  );

  // ── direct writes (concurrent-safe, bypass Command guard) ────────────────

  /// Creates or merges a document without the Command single-execution guard.
  ///
  /// Unlike [set], multiple calls can overlap safely.
  Future<void> setDirect(({String path, T model}) input) {
    guardAuth();
    return fs
        .doc(input.path)
        .set(input.model.toJson(), SetOptions(merge: true));
  }

  /// Partially updates fields without the Command single-execution guard.
  ///
  /// Unlike [patch], multiple calls can overlap safely — use this when
  /// rapidly editing different documents in the same collection group.
  Future<void> patchDirect(GroupPatch p) {
    guardAuth();
    return fs.doc(p.path).update(p.data);
  }

  /// Fully updates a document without the Command single-execution guard.
  ///
  /// Unlike [update], multiple calls can overlap safely.
  Future<void> updateDirect(({String path, T model}) input) {
    guardAuth();
    return fs.doc(input.path).update(input.model.toJson());
  }

  /// Deletes a document without the Command single-execution guard.
  ///
  /// Unlike [delete], multiple calls can overlap safely.
  Future<void> deleteDirect(String path) {
    guardAuth();
    return fs.doc(path).delete();
  }

  // ── lifecycle ─────────────────────────────────────────────────────────────
  @override
  void dispose() {
    set.dispose();
    update.dispose();
    patch.dispose();
    delete.dispose();
    super.dispose();
  }
}
