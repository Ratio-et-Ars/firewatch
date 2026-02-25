# Changelog

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
