/// Firewatch – opinionated Firestore repositories for responsive UIs.
///
/// This package provides:
/// - `FirestoreCollectionRepository` for managing live queries and pagination
/// - `FirestoreDocRepository` for document-scoped state
/// - Command wrappers (`add`, `set`, `patch`, `update`, `delete`) for
///   single-item CRUD operations
/// - Batch methods (`batchAdd`, `batchSet`, `batchPatch`, `batchUpdate`,
///   `batchDelete`) for multi-document writes via `WriteBatch` (atomic per
///   500-op chunk; longer lists commit as multiple sequential batches)
/// - `WriteAckPolicy` for offline-safe writes: cap how long writes await the
///   server ack, resolving optimistically once queued locally, and `create()`
///   for locally-minted document IDs that resolve offline
///
/// Designed to integrate with ValueNotifier and Listenable patterns for
/// Flutter apps.
///
/// Example:
/// ```dart
/// final repo = FirestoreCollectionRepository<User>(
///   firestore: FirebaseFirestore.instance,
///   fromJson: User.fromJson,
///   colRefBuilder: (fs, uid) => fs.collection('users').doc(uid).collection('entries'),
/// );
/// repo.add.execute({'name': 'Alice'});
/// ```
library;

export 'src/collection_group_repository.dart';
export 'src/collection_repository.dart';
export 'src/doc_repository.dart';

/// Public exports for end-users.
///
/// Import this single file in your apps:
/// ```dart
/// import 'package:firewatch/firewatch.dart';
/// ```
export 'src/json_model.dart';
export 'src/write_ack_policy.dart';
