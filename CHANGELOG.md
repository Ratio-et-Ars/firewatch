# Changelog

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
