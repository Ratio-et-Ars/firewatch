# firewatch

Lightweight Firestore repositories for Flutter.

- 🔁 **Auth-reactive**: attach/detach on UID changes via any `ValueListenable<String?>`
- ⚡ **Instant UI**: primes from local cache; then streams live updates
- 🪶 **Small surface area**: single-doc, collection, and collection-group repos
- 📜 **Live window pagination**: grow with `loadMore()`, reset via `resetPages()`
- 🧩 **No auth lock-in**: bring your own auth listenable

## Install

```yaml
dependencies:
  firewatch:
```

## Quick start

Firewatch repositories are built to work seamlessly with [`watch_it`](https://pub.dev/packages/watch_it).
Here’s the minimal flow: **Model → Repository → UI**.

---

### 1. Define your model

Firestore-backed models must implement `JsonModel` so Firewatch can inject the
document ID.

```dart
class UserProfile implements JsonModel {
  @override
  final String id;
  final String name;

  UserProfile({required this.id, required this.name});

  factory UserProfile.fromJson(Map<String, dynamic> json) => UserProfile(
        id: json['id'] as String,
        name: json['name'] as String? ?? 'Anonymous',
      );

  @override
  Map<String, dynamic> toJson() => {'name': name};
}
```

---

### 2. Create your repositories

Repositories bind models to Firestore. Provide `authUid`
(a `ValueListenable<String?>`) so Firewatch knows which document/collection to
read.

```dart
final authUid = ValueNotifier<String?>(null); // wire this to your auth layer

class UserProfileRepository extends FirestoreDocRepository<UserProfile> {
  UserProfileRepository()
      : super(
          fromJson: UserProfile.fromJson,
          docRefBuilder: (fs, uid) => fs.doc('users/$uid'),
          authUid: authUid,
        );
}

class FriendsRepository extends FirestoreCollectionRepository<UserProfile> {
  FriendsRepository()
      : super(
          fromJson: UserProfile.fromJson,
          colRefBuilder: (fs, uid) => fs.collection('users/$uid/friends'),
          authUid: authUid,
        );
}

/// Query across ALL "friends" subcollections regardless of parent.
class AllFriendsRepository
    extends FirestoreCollectionGroupRepository<UserProfile> {
  AllFriendsRepository()
      : super(
          fromJson: UserProfile.fromJson,
          // ⚠️ Scope by owner — see the security note below.
          queryRefBuilder: (fs, uid) =>
              fs.collectionGroup('friends').where('ownerId', isEqualTo: uid),
          authUid: authUid,
        );
}
```

> **⚠️ Security: always scope collection-group queries by owner.**
> A `collectionGroup('friends')` query reads **every** `friends` subcollection
> across **all** parents/tenants. Firewatch passes you the current `uid` but
> does **not** add any filter for you — an unfiltered builder like
> `(fs, uid) => fs.collectionGroup('friends')` will read other users'
> documents (subject only to your Firestore security rules). Add a
> `.where('ownerId', isEqualTo: uid)` (or equivalent) **and** back it with a
> matching collection-group security rule.

---

### 3. Consume in the UI with `watch_it`

Because repositories are `ValueNotifier`s, you can watch them directly in your widgets.

```dart
class ProfileCard extends StatelessWidget {
  const ProfileCard({super.key});

  @override
  Widget build(BuildContext context) {
    final profile = watchIt<UserProfileRepository>().value;
    final friends = watchIt<FriendsRepository>().value;

    if (profile == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return Card(
      child: ListTile(
        title: Text('User: ${profile.name}'),
        subtitle: Text('Friends: ${friends.length}'),
      ),
    );
  }
}
```

---

👉 For a **full runnable demo** (with auth wiring and fake Firestore), check
out the [example/](example/) app in this repo.

## Parent ID injection

All repositories automatically inject `parentId` into the data map before
calling `fromJson`. This is the document ID of the **parent** document in the
Firestore path hierarchy. Models can opt-in by declaring a `parentId` field —
no changes to `JsonModel` required.

This is especially useful for **collection group queries**, where two documents
can share the same `id` but live under different parents
(`users/u1/tasks/t1` vs `projects/p1/tasks/t1`).

```dart
class Task implements JsonModel {
  @override
  final String id;
  final String title;
  final String? parentId; // opt-in — injected automatically

  Task({required this.id, required this.title, this.parentId});

  factory Task.fromJson(Map<String, dynamic> json) => Task(
        id: json['id'] as String,
        title: json['title'] as String? ?? '',
        parentId: json['parentId'] as String?,
      );

  @override
  Map<String, dynamic> toJson() => {'title': title};
}
```

For a document at `users/u1/tasks/t1`, `parentId` will be `'u1'`.
For a top-level document like `users/u1`, `parentId` will be `null`.

## Bring your own Auth

Firewatch accepts any ValueListenable<String?> that yields the current user UID.
Update it on sign-in/out and the repos will re-attach.

```dart
authUid.value = 'abc123'; // sign in
authUid.value = null; // sign out
```

## Write API

All repos expose [`command_it`](https://pub.dev/packages/command_it) async
commands with observable `isRunning`/`errors` state:

```dart
profileRepo.write(UserProfile(id: 'abc123', displayName: 'Marty'));
profileRepo.patch({'bio': 'Hello'});

friendsRepo.add({'displayName': 'Alice'});
friendsRepo.delete(id!);

// Collection-group writes use full document paths (no .add()):
allFriendsRepo.set((path: 'users/abc123/friends/f1', model: friend));
allFriendsRepo.patch((path: 'users/abc123/friends/f1', data: {'name': 'Bob'}));
allFriendsRepo.delete('users/abc123/friends/f1');
```

### Direct writes (concurrent-safe)

Commands are single-execution — a second call while the first is in-flight is
silently dropped. When you need to rapidly write to **different documents** in
the same collection (e.g. toggling checkboxes), use the `*Direct` methods:

```dart
// These return Futures and can overlap safely:
await friendsRepo.patchDirect((id: 'f1', data: {'checked': true}));
await friendsRepo.patchDirect((id: 'f2', data: {'checked': false}));

// Also available: addDirect, setDirect, updateDirect, deleteDirect
```

### Batch writes

Collection repos expose `batchAdd` / `batchSet` / `batchPatch` / `batchUpdate` /
`batchDelete` Commands that commit via Firestore `WriteBatch`.

> **Atomicity is per chunk, not per call.** A single `WriteBatch` is limited to
> 500 operations, so a list longer than 500 is committed as **multiple
> sequential batches**. Each batch is atomic on its own, but if a later chunk
> fails, earlier chunks are already committed — the call is **not** all-or-
> nothing across the 500-op boundary. Keep batches ≤ 500 items if you need true
> atomicity.

## Caching & freshness

Repositories are **cache-first**: they prime `value` from the local Firestore
cache for instant UI, then attach the live listener (or one-shot fetch) for
authoritative server data.

> One consequence: after a cache hit, `isLoading` flips to `false` and `value`
> shows the cached document **before** the server confirms it. If the
> subsequent server read fails (e.g. a permission change), the stale cached
> value remains on screen and the error surfaces via `onError` — it is **not**
> reverted. If you display sensitive data, treat an `onError` after a cache hit
> as "the shown value may be stale/unauthorized" and react accordingly.

## Error handling

All repositories accept an optional `onError` callback for subscription and
fetch errors:

```dart
final repo = FirestoreCollectionRepository<Item>(
  // ...
  onError: (error, stackTrace) {
    Sentry.captureException(error, stackTrace: stackTrace);
    // or show a toast, retry, etc.
  },
);
```

| Error source | How it surfaces |
|---|---|
| Snapshot listener / one-shot fetch | `onError` callback |
| Command-based writes | `command.errors` ValueNotifier |
| Direct writes (`*Direct`) | Exception on the returned Future |
| Auth guard (no signed-in user) | Synchronous `StateError` |

## UI State

- `isLoading`: true while fetching/refreshing
- `hasInitialized` (collections): first load completed
- `hasMore` (collections): whether `loadMore()` can grow the window
- `notifierFor(docId)`: get a pre-soaked `ValueNotifier<T?>` for a specific item (keyed by doc path for collection groups)

## Documentation

[![API Docs](https://img.shields.io/badge/docs-api-blue)](https://ratio-et-ars.github.io/firewatch/)

## License

MIT - See [LICENSE](LICENSE)
