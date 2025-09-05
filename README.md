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
```

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

## Bring your own Auth

Firewatch accepts any ValueListenable<String?> that yields the current user UID.
Update it on sign-in/out and the repos will re-attach.

```dart
authUid.value = 'abc123'; // sign in
authUid.value = null; // sign out
```

## Commands API

Both repos expose [`command_it`](https://pub.dev/packages/command_it) async
commands:

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

## Documentation

[![API Docs](https://img.shields.io/badge/docs-api-blue)](https://ratio-et-ars.github.io/firewatch/)

## License

MIT - See [LICENSE](LICENSE)
