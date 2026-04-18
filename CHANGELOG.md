# Changelog

## 1.9.0

### Added
- **Partial upsert on `FirestoreDocRepository`** (#19).
  - New Command `setFields(Map<String, dynamic>)` — like `patch`, but uses
    `set(..., SetOptions(merge: true))` so the document is created if it
    doesn't exist. Use this for opt-in flows, default-setting writes, or
    any partial write where the doc may not have been initialized yet.
  - Existing `patch` keeps its `update()` semantics (throws `not-found`
    on missing doc) for callers that rely on that.
- **Direct writes on `FirestoreDocRepository`**, mirroring the existing
  `FirestoreCollectionRepository` Direct API:
  - `writeDirect(T)` — `set(merge: true)` with full model
  - `updateDirect(T)` — full-model update (throws if missing)
  - `patchDirect(Map)` — partial update (throws if missing)
  - `setFieldsDirect(Map)` — partial upsert (create if missing)
  - `deleteDirect()` — delete
  - Use these when you need to fire rapid, overlapping writes that would
    otherwise be rejected by the Command single-execution guard.

## 1.8.1

### Fixed
- **Sign-out race with snapshot retry loop** (#17): On sign-out, the
  subscription cancel was fire-and-forget, so the native Firestore listener
  could fire `PERMISSION_DENIED` errors before the Dart-side cancel reached
  the native layer. Combined with the retry mechanism from 1.8.0, this
  created an error loop. The null-UID path in `_swap()` now awaits the
  subscription cancel, and `onError` suppresses retries when the repo is
  auth-detached.

## 1.8.0

### Added
- **Automatic retry on snapshot listener errors.** When a Firestore snapshot
  listener dies (e.g. `PERMISSION_DENIED` because a parent document hasn't
  been committed server-side yet), the repository now retries with linear
  backoff instead of leaving the listener permanently dead.
- New `FirestoreCollectionRepository` constructor parameters:
  - `maxRetries` (default: 5) — number of retry attempts before giving up.
  - `retryDelay` (default: 500 ms) — base delay, multiplied by attempt number
    (500 ms, 1 s, 1.5 s, 2 s, 2.5 s).
- Retry counter resets on successful snapshot or on auth/dependency/query
  change. After `maxRetries` exhausted, the repo settles into
  `hasInitialized = true` / `isLoading = false` (previous behavior).

### Fixed
- Race condition where subcollection repos activated before their parent
  document was server-confirmed during first-time anonymous sign-in. The
  snapshot listener would hit `PERMISSION_DENIED` and die permanently —
  writes went through to Firestore but the UI never updated.

## 1.7.1

### Changed
- Updated README with documentation for direct write methods, error handling
  table, and `onError` callback usage example.
- Added one-shot `_resizeWindow` coverage tests for both collection repository
  types.

## 1.7.0

### Added
- **`onError` callback** on all three repository constructors
  (`FirestoreDocRepository`, `FirestoreCollectionRepository`,
  `FirestoreCollectionGroupRepository`). Called with the error and stack
  trace when a Firestore snapshot listener or one-shot fetch fails.
  Optional and non-breaking — when omitted, existing behavior is unchanged.
- **`FirewatchErrorHandler`** typedef exported from `firewatch.dart` for
  typing the callback: `void Function(Object error, StackTrace stackTrace)`.

## 1.6.0

### Added
- **Direct write methods** on `FirestoreCollectionRepository`:
  `addDirect`, `setDirect`, `patchDirect`, `updateDirect`, `deleteDirect`.
  These bypass the `Command` single-execution guard, allowing concurrent
  writes to different documents in the same collection. Use them when
  rapidly editing multiple items (e.g. toggling checkboxes in a list)
  where the Command-based methods would silently drop overlapping calls.
- **Direct write methods** on `FirestoreCollectionGroupRepository`:
  `setDirect`, `patchDirect`, `updateDirect`, `deleteDirect`.
  Same concurrent-safe semantics for collection group repositories.
- Existing Command-based CRUD (`patch`, `set`, `update`, `delete`, `add`)
  remains unchanged for use cases that benefit from `isRunning`/`errors`
  observability.

## 1.5.2

### Fixed
- **In-flight async ops update disposed notifier** (#15):
  `FirestoreCollectionRepository.dispose()` did not increment the epoch
  counter, so pending cache primes, snapshot callbacks, or one-shot fetches
  could write to already-disposed `ValueNotifier`s (causing Flutter assertion
  errors). Now mirrors `FirestoreDocRepository.dispose()` by bumping `_epoch`
  first.

## 1.5.1

### Fixed
- **`ready` returns stale null after `authUid` change** (#13):
  `_readyCompleter` was never reset, so `ready` cached its first result
  forever. Now `hasInitialized` resets to `false` and a fresh `Completer`
  is created on every auth transition, so callers re-await fresh data.

## 1.5.0

### Added
- **Batch CRUD operations** on `FirestoreCollectionRepository`:
  `batchAdd`, `batchSet`, `batchPatch`, `batchUpdate`, `batchDelete`.
  All are `Command` instances (not plain Futures), so consumers can watch
  `isRunning`, listen to `errors`, and use the full Command lifecycle —
  consistent with single-item CRUD commands.
- Automatically chunks operations at the Firestore 500-operation batch limit.
- Auth-gated: batch commands route a `StateError` through `.errors` when
  the UID is null, matching single-item command behavior.

## 1.4.0

### Added
- **`hasInitialized`** (`ValueNotifier<bool>`) on `FirestoreDocRepository` —
  flips to `true` after the first successful load (from cache or server) and
  never reverts. Mirrors the existing property on `FirestoreCollectionRepository`.
- **`ready`** (`Future<T?>`) on `FirestoreDocRepository` — completes with the
  first loaded value (which may be `null` if the document doesn't exist). Useful
  for one-time `await` in services that need data before proceeding.

### Fixed
- `dispose()` now increments the epoch counter to prevent in-flight async
  operations from writing to a disposed notifier.

## 1.3.1

### Fixed
- **Web compatibility**: `parentId` injection no longer crashes on web.
  `cloud_firestore_web` throws an Expando error when calling `.parent` on a
  top-level `CollectionReference` (where the parent is `null`). The new
  `parentIdOf()` helper wraps the call in a try-catch, returning `null` for
  top-level collections.

## 1.3.0

### Added
- `parentId` is now automatically injected into the data map before calling
  `fromJson` across all three repository types. Models can opt-in by declaring
  a `parentId` field in their `fromJson` factory — no changes to `JsonModel`
  required. Particularly useful for collection group queries where documents
  with the same ID can live under different parents.

## 1.2.0

### Added
- `FirestoreCollectionGroupRepository<T>` — reactive queries across all
  subcollections with the same name via Firestore `collectionGroup()`. Supports
  live pagination, per-item notifiers keyed by full document path, and
  path-based CRUD (`set`, `update`, `patch`, `delete`).
- `QueryRefBuilder` typedef and `GroupPatch` record type for collection group
  write operations
- Updated README with collection group examples

### Fixed
- `FirestoreDocRepository` stream subscription now has an `onError` handler.
  Previously a stream error (permission denied, network failure) would leave
  `isLoading` stuck at `true` forever.

## 1.1.0

### Added
- Repositories now work without `authUid` for public/unauthenticated
  collections (e.g. `static/config`). Omitting `authUid` queries Firestore
  immediately instead of waiting for a signed-in user.
- Updated doc comments with public-collection usage examples

## 1.0.0

- Stable release — no API changes, just documentation polish
- Added doc comments to all public members across both repository types

## 0.3.0

### Improved
- Collection repo now primes UI from Firestore local cache before starting the
  live subscription, giving instant data on revisits
- Incremental snapshot processing via `docChanges` — only re-parses
  added/modified/removed documents instead of deserializing the full list on
  every snapshot event
- Per-item notifiers are now pruned (removed from the map) when documents leave
  the snapshot, preventing unbounded memory growth over long sessions

## 0.2.0

### Breaking
- Bumps `command_it` from ^8.0.0 to ^9.0.0
- Requires Dart >=3.8.0 and Flutter >=3.32.0
- `write` command on `FirestoreDocRepository` no longer accepts an unreachable
  `merge` parameter (always merges)

### Fixed
- Race condition in `FirestoreDocRepository._swap` on rapid auth changes
  (added epoch guard)
- `_resizing` flag in `FirestoreCollectionRepository` could get permanently
  stuck, breaking `loadMore()`
- Deleted documents now correctly clear `value` to `null` in
  `FirestoreDocRepository`
- Pagination limit now resets on query/dependency changes
- Per-item notifiers are nulled out when documents leave the snapshot
- All `Command` objects are now properly disposed

### Improved
- Bumps `cloud_firestore` to ^6.0.0, `flutter_lints` to ^6.0.0
- Fixes CI docs workflow (uses stable Flutter channel, gh-pages v4)
- Test coverage increased from 4 to 26 tests (94% line coverage)

## 0.1.4

- Adds `paginate` option to `FirestoreCollectRepository` to enable pagination 
of collection queries

## 0.1.3

- Improves example and README

## 0.1.2

- Formatting issue

## 0.1.1

- Adds better documentation, examples, and updates licence

## 0.1.0

- Initial release: single-doc and collection repositories
- Live-cache prime, metadata-churn squash
- Live-window pagination, per-item notifiers
- Simple CRUD commands
