import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

/// Safely extracts the parent document ID for a Firestore document reference.
///
/// For subcollection docs (e.g. `apiaries/{id}/hives/{hiveId}`), returns the
/// parent document ID (`{id}`). For top-level collection docs, returns `null`.
///
/// The `cloud_firestore_web` implementation throws when calling `.parent` on a
/// top-level `CollectionReference` (Expando-on-null error), so this helper
/// wraps the call in a try-catch.
String? parentIdOf(DocumentReference ref) {
  try {
    return ref.parent.parent?.id;
  } catch (_) {
    return null;
  }
}

/// A minimal contract for Firestore-backed entities.
///
/// - `id` is always present on in-memory models.
/// - `toJson()` omits the `id` (Firestore owns the documentID).
abstract interface class JsonModel {
  String get id;
  Map<String, dynamic> toJson();
}

/// Firewatch avoids imposing an auth SDK. Instead, it accepts any
/// [ValueListenable] that exposes the *current user UID*.
///
/// Provide something like:
///   - `ValueNotifier<String?>` that you update on auth changes, or
///   - a wrapper around Firebase Auth that implements `ValueListenable<String?>`.
typedef AuthUidListenable = ValueListenable<String?>;

/// Signature for error callbacks used by Firewatch repositories.
///
/// Called when a Firestore snapshot listener or one-shot fetch encounters
/// an error. The [error] and [stackTrace] are forwarded from the underlying
/// Firestore operation.
typedef FirewatchErrorHandler = void Function(
  Object error,
  StackTrace stackTrace,
);
