import 'package:flutter/foundation.dart';

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
