import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:command_it/command_it.dart';
import 'package:flutter/foundation.dart';

import 'json_model.dart';
import 'query_list_repository_base.dart';
import 'write_ack_policy.dart';

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
///
/// The auth-reactive lifecycle (cache-first swap, epoch-guarded races, live
/// window resizing, retries, sign-out handling, disposal) lives in
/// [QueryListRepositoryBase], shared with
/// [FirestoreCollectionGroupRepository]. This repo adds collection-specific
/// writes (`add`, batch operations) and keys items by document ID.
class FirestoreCollectionRepository<T extends JsonModel>
    extends QueryListRepositoryBase<T> {
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
  /// - [writeAckPolicy]: How long writes wait for the Firestore **server ack**
  ///   before resolving optimistically. The default awaits the ack
  ///   indefinitely (legacy behavior); pass an [WriteAckPolicy.ackGrace] of
  ///   ~1–2s for offline-safe writes. See [WriteAckPolicy] for semantics.
  ///
  /// On construction, listeners are attached and the initial query is run
  /// immediately against the resolved collection for the current user.
  FirestoreCollectionRepository({
    required super.fromJson,
    required ColRefBuilder colRefBuilder,
    super.firestore,
    super.queryBuilder,
    super.authUid,
    super.dependencies,
    super.subscribe,
    super.pageSize,
    super.paginate,
    super.onError,
    super.maxRetries = 5, // retry on transient listener errors
    super.retryDelay,
    this.writeAckPolicy = const WriteAckPolicy(),
  }) : _colRefBuilder = colRefBuilder {
    start();
  }

  final ColRefBuilder _colRefBuilder;

  /// The server-ack policy applied to every write on this repository
  /// (Commands, `*Direct` writes, [create], and batch commits).
  ///
  /// Transactions are not covered — they require connectivity.
  final WriteAckPolicy writeAckPolicy;

  // ── base hooks ────────────────────────────────────────────────────────────
  @override
  Query<Map<String, dynamic>> queryBase(String? uid) =>
      _colRefBuilder(fs, uid);

  @override
  String keyOf(DocumentSnapshot<Map<String, dynamic>> doc) => doc.id;

  // ── CRUD (require signed-in user) ─────────────────────────────────────────
  //
  // Every write below runs under [writeAckPolicy] *inside* the Command
  // function. That placement is deliberate: with a graced policy the Command
  // completes within the grace even offline, so command_it's single-execution
  // guard recovers and a hung server ack can never brick the Command for the
  // session.

  /// Adds a new document to the collection.
  ///
  /// Input: A raw JSON map representing the document.
  /// Output: The generated document ID (or `null` on failure).
  /// Example: `add({'name': 'Alice'});`
  ///
  /// The document ID is minted locally (no server round-trip) and the write
  /// runs under [writeAckPolicy], so with a graced policy this resolves with
  /// the real ID even while offline. Prefer [create] in new code — it returns
  /// the ID directly without the Command wrapper.
  late final add = Command.createAsync<Map<String, dynamic>, String?>(
    (Map<String, dynamic> data) => create(data),
    initialValue: null,
  );

  /// Creates or replaces a document in the collection.
  ///
  /// Input: A model [T] with a valid `id`.
  /// Behavior: Writes `model.toJson()` at the document path,
  /// merging with existing data if present.
  /// Example: `set(User(id: 'u1', name: 'Alice'));`
  late final set = Command.createAsyncNoResult<T>(
    (T model) => writeAckPolicy.applyVoid(
      _colOrThrow().doc(model.id).set(model.toJson(), SetOptions(merge: true)),
    ),
  );

  /// Partially updates fields on an existing document.
  ///
  /// Input: A [Patch] containing a `doc.id` and `data` map.
  /// Behavior: Only the provided fields are updated; other fields are untouched.
  /// Example: `patch((id: 'u1', data: {'name': 'Bob'}));`
  late final patch = Command.createAsyncNoResult<Patch>(
    (Patch p) =>
        writeAckPolicy.applyVoid(_colOrThrow().doc(p.id).update(p.data)),
  );

  /// Fully updates an existing document.
  ///
  /// Input: A model [T] with a valid `id`.
  /// Behavior: Calls `.update()` with the entire serialized model,
  /// replacing all fields with `model.toJson()`.
  /// Example: `update(User(id: 'u1', name: 'Bob'));`
  late final update = Command.createAsyncNoResult<T>(
    (T model) => writeAckPolicy.applyVoid(
      _colOrThrow().doc(model.id).update(model.toJson()),
    ),
  );

  /// Deletes a document from the collection.
  ///
  /// Input: A document ID string.
  /// Behavior: Removes the document at that path.
  /// Example: `delete(model.id);`
  late final delete = Command.createAsyncNoResult<String>(
    (String docId) =>
        writeAckPolicy.applyVoid(_colOrThrow().doc(docId).delete()),
  );

  /// Creates a new document with a **locally minted** ID and returns that ID.
  ///
  /// The ID is generated client-side via `.doc()` (Firestore document IDs are
  /// always minted locally — there is no server round-trip for the ID), then
  /// the data is written with `set` under [writeAckPolicy].
  ///
  /// This is the offline-safe replacement for [add]/[addDirect]: with a graced
  /// policy the returned future resolves with the ID within the grace even
  /// while offline (the write is durably queued in Firestore's local mutation
  /// queue and syncs when connectivity returns). With the default policy it
  /// behaves like `add` — resolving only on server ack.
  ///
  /// Not a Command, so multiple calls can overlap safely.
  Future<String> create(Map<String, dynamic> data) async {
    final ref = _colOrThrow().doc();
    await writeAckPolicy.applyVoid(ref.set(data));
    return ref.id;
  }

  // ── direct writes (concurrent-safe, bypass Command guard) ────────────────

  /// Adds a document without the Command single-execution guard.
  ///
  /// Unlike [add], multiple calls can overlap safely.
  /// Returns the generated document ID.
  ///
  /// Alias of [create] — prefer [create] in new code.
  Future<String> addDirect(Map<String, dynamic> data) => create(data);

  /// Creates or merges a document without the Command single-execution guard.
  ///
  /// Unlike [set], multiple calls can overlap safely.
  Future<void> setDirect(T model) => writeAckPolicy.applyVoid(
        _colOrThrow().doc(model.id).set(model.toJson(), SetOptions(merge: true)),
      );

  /// Partially updates fields without the Command single-execution guard.
  ///
  /// Unlike [patch], multiple calls can overlap safely — use this when
  /// rapidly editing different documents in the same collection.
  Future<void> patchDirect(Patch p) =>
      writeAckPolicy.applyVoid(_colOrThrow().doc(p.id).update(p.data));

  /// Fully updates a document without the Command single-execution guard.
  ///
  /// Unlike [update], multiple calls can overlap safely.
  Future<void> updateDirect(T model) => writeAckPolicy.applyVoid(
        _colOrThrow().doc(model.id).update(model.toJson()),
      );

  /// Deletes a document without the Command single-execution guard.
  ///
  /// Unlike [delete], multiple calls can overlap safely.
  Future<void> deleteDirect(String docId) =>
      writeAckPolicy.applyVoid(_colOrThrow().doc(docId).delete());

  // ── batch operations ─────────────────────────────────────────────────────
  //
  // Atomicity is per chunk, not per call: a WriteBatch is capped at [batchLimit]
  // (500) operations, so a longer list commits as multiple sequential batches.
  // If a later chunk fails, earlier chunks are already committed — these are
  // NOT all-or-nothing across the 500-op boundary. Keep lists <= 500 if you
  // need true atomicity.

  /// The maximum number of operations per Firestore [WriteBatch].
  static const batchLimit = 500;

  /// Runs [populate] on chunks of [items] of size [batchLimit], committing
  /// each chunk as a single [WriteBatch].
  ///
  /// Note: batches are atomic per chunk only. Lists exceeding [batchLimit] are
  /// committed as multiple sequential batches, so a failure partway through
  /// leaves earlier chunks committed.
  ///
  /// Each chunk's `commit()` runs under [writeAckPolicy]: batches queue in
  /// Firestore's local mutation store while offline but their commit futures
  /// never complete, so an un-graced batch Command is just as brickable as a
  /// single write. With a graced policy each chunk resolves within the grace
  /// (so a multi-chunk call can take up to `chunks × grace` offline).
  Future<void> _runBatched<E>(
    List<E> items,
    void Function(WriteBatch batch, CollectionReference<Map<String, dynamic>> col, E item) populate,
  ) async {
    if (items.isEmpty) return;
    final col = _colOrThrow();
    for (var i = 0; i < items.length; i += batchLimit) {
      final end = i + batchLimit;
      final chunk = items.sublist(i, end < items.length ? end : items.length);
      final batch = fs.batch();
      for (final item in chunk) {
        populate(batch, col, item);
      }
      await writeAckPolicy.applyVoid(batch.commit());
    }
  }

  /// Adds multiple documents to the collection in a single batched write.
  ///
  /// Each entry in [items] is a raw JSON map. Document IDs are
  /// auto-generated by Firestore.
  ///
  /// This is a [Command], so it exposes `isRunning`, `errors`, and can be
  /// awaited via `runAsync`. Lists exceeding [batchLimit] (500) are
  /// automatically split into sequential batches.
  ///
  /// Example:
  /// ```dart
  /// repo.batchAdd.run([{'name': 'Alice'}, {'name': 'Bob'}]);
  /// // or await:
  /// await repo.batchAdd.runAsync([{'name': 'Alice'}, {'name': 'Bob'}]);
  /// ```
  late final batchAdd = Command.createAsyncNoResult<List<Map<String, dynamic>>>(
    (items) => _runBatched(items, (batch, col, data) => batch.set(col.doc(), data)),
  );

  /// Sets (create-or-merge) multiple documents in a single batched write.
  ///
  /// Each model's [JsonModel.id] determines the document path. Existing
  /// documents are merged via `SetOptions(merge: true)`, matching the
  /// behaviour of the single-item [set] command.
  ///
  /// This is a [Command], so it exposes `isRunning`, `errors`, and can be
  /// awaited via `runAsync`. Lists exceeding [batchLimit] (500) are
  /// automatically split into sequential batches.
  ///
  /// Example:
  /// ```dart
  /// await repo.batchSet.runAsync([user1, user2]);
  /// ```
  late final batchSet = Command.createAsyncNoResult<List<T>>(
    (models) => _runBatched(
      models,
      (batch, col, model) =>
          batch.set(col.doc(model.id), model.toJson(), SetOptions(merge: true)),
    ),
  );

  /// Partially updates multiple documents in a single batched write.
  ///
  /// Each [Patch] contains a document `id` and a `data` map of fields
  /// to update. Only the specified fields are modified; other fields are
  /// untouched. Matches the behaviour of the single-item [patch] command.
  ///
  /// This is a [Command], so it exposes `isRunning`, `errors`, and can be
  /// awaited via `runAsync`. Lists exceeding [batchLimit] (500) are
  /// automatically split into sequential batches.
  ///
  /// Example:
  /// ```dart
  /// await repo.batchPatch.runAsync([
  ///   (id: 'u1', data: {'name': 'Alice'}),
  ///   (id: 'u2', data: {'name': 'Bob'}),
  /// ]);
  /// ```
  late final batchPatch = Command.createAsyncNoResult<List<Patch>>(
    (patches) => _runBatched(patches, (batch, col, p) => batch.update(col.doc(p.id), p.data)),
  );

  /// Fully updates multiple existing documents in a single batched write.
  ///
  /// Each model's [JsonModel.id] determines the document path. The entire
  /// document is replaced with `model.toJson()`, matching the behaviour of
  /// the single-item [update] command.
  ///
  /// This is a [Command], so it exposes `isRunning`, `errors`, and can be
  /// awaited via `runAsync`. Lists exceeding [batchLimit] (500) are
  /// automatically split into sequential batches.
  ///
  /// Example:
  /// ```dart
  /// await repo.batchUpdate.runAsync([updatedUser1, updatedUser2]);
  /// ```
  late final batchUpdate = Command.createAsyncNoResult<List<T>>(
    (models) => _runBatched(
      models,
      (batch, col, model) => batch.update(col.doc(model.id), model.toJson()),
    ),
  );

  /// Deletes multiple documents from the collection in a single batched write.
  ///
  /// This is a [Command], so it exposes `isRunning`, `errors`, and can be
  /// awaited via `runAsync`. Lists exceeding [batchLimit] (500) are
  /// automatically split into sequential batches.
  ///
  /// Example:
  /// ```dart
  /// repo.batchDelete.run(['id1', 'id2', 'id3']);
  /// // or await:
  /// await repo.batchDelete.runAsync(['id1', 'id2', 'id3']);
  /// ```
  late final batchDelete = Command.createAsyncNoResult<List<String>>(
    (docIds) => _runBatched(docIds, (batch, col, id) => batch.delete(col.doc(id))),
  );

  // ── write helpers ─────────────────────────────────────────────────────────
  CollectionReference<Map<String, dynamic>> _colOrThrow() {
    guardAuth();
    return _colRefBuilder(fs, currentUserUid);
  }

  // ── lifecycle ─────────────────────────────────────────────────────────────
  @override
  void dispose() {
    add.dispose();
    set.dispose();
    patch.dispose();
    update.dispose();
    delete.dispose();
    batchAdd.dispose();
    batchSet.dispose();
    batchPatch.dispose();
    batchUpdate.dispose();
    batchDelete.dispose();
    super.dispose();
  }
}
