# firewatch

Lightweight Firestore repositories for Flutter.

- 🔁 **Auth-reactive**: attach/detach on UID changes via any `ValueListenable<String?>`
- ⚡ **Instant UI**: primes from local cache; then streams live updates
- 🪶 **Small surface area**: single-doc + collection repos
- 📜 **Live window pagination**: grow with `loadMore()`, reset via `resetPages()`
- 🧩 **No auth lock-in**: bring your own auth listenable

## Install

```yaml
dependencies:
  firewatch: ^0.1.0
```

## Quick start

```dart
import 'package:firewatch/firewatch.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

final authUid = ValueNotifier<String?>(null); // wire to your auth layer

final profileRepo = FirestoreDocRepository<UserProfile>(
  firestore: FirebaseFirestore.instance,
  fromJson: UserProfile.fromJson,
  docRefBuilder: (fs, uid) => fs.doc('users/$uid'),
  authUid: authUid,
  subscribe: true,
);

final friendsRepo = FirestoreCollectionRepository<UserProfile>(
  firestore: FirebaseFirestore.instance,
  fromJson: UserProfile.fromJson,
  colRefBuilder: (fs, uid) => fs.collection('users/$uid/friends'),
  authUid: authUid,
  subscribe: true,
  pageSize: 25,
);

// Grow the list:
await friendsRepo.loadMore();
```

## Bring your own Auth

Firewatch accepts any ValueListenable<String?> that yields the current user UID.
Update it on sign-in/out and the repos will re-attach.

```dart
authUid.value = 'abc123'; // sign in
authUid.value = null; // sign out
```

## Commands API

Both repos expose [`command_it`](https://pub.dev/packages/command_it) async commands:

```dart
profileRepo.write(UserProfile(id: 'abc123', displayName: 'Marty'));
profileRepo.patch({'bio': 'Hello'});

friendsRepo.add({'displayName': 'Alice'});
friendsRepo.delete(id!);
```

## UI State

- `isLoading`: true while fetching/refreshing
- `hasInitialized` (collections): first load completed
- `hasMore` (collections): whether `loadMore()` can grow the window
- `notifierFor(docId)`: get a pre-soaked `ValueNotifier<T?>` for a specific item

## Examples & Tests

See [example/usage.dart](example/usage.dart)

## Documentation

[![API Docs](https://img.shields.io/badge/docs-api-blue)](https://ratio-et-ars.github.io/firewatch/)

## License

MIT - See [LICENSE](LICENSE)
