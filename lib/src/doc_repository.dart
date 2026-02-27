import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:command_it/command_it.dart';
import 'package:flutter/foundation.dart';

import 'json_model.dart';

/// A small, opinionated single-document repository that:
/// 1) Reacts to auth changes (attaches/detaches via UID),
/// 2) Primes state from the local cache for instant UI,
/// 3) Streams live updates (or can be one-shot),
/// 4) Exposes simple write/update/patch/delete Commands.
///
/// Usage:
/// ```dart
/// final repo = FirestoreDocRepository<UserProfile>(
///   firestore: FirebaseFirestore.instance,
///   fromJson: (m) => UserProfile.fromJson(m),
///   docRefBuilder: (fs, uid) => fs.doc('users/$uid'),
///   authUid: myAuthUidListenable, // ValueListenable<String?>
///   subscribe: true,
/// );
/// ```
class FirestoreDocRepository<T extends JsonModel> extends ValueNotifier<T?> {
  FirestoreDocRepository({
    required T Function(Map<String, dynamic>) fromJson,
    required DocumentReference<Map<String, dynamic>> Function(
      FirebaseFirestore fs,
      String? uid,
    ) docRefBuilder,
    FirebaseFirestore? firestore,
    AuthUidListenable? authUid, // optional auth source
    bool subscribe = true,
  })  : _fs = firestore ?? FirebaseFirestore.instance,
        _fromJson = fromJson,
        _docRefBuilder = docRefBuilder,
        _authUid = authUid,
        _subscribe = subscribe,
        super(null) {
    _authUid?.addListener(_onAuth);
    _swap(_currentUserUid);
  }

  // ── core fields ───────────────────────────────────────────────────────────
  final FirebaseFirestore _fs;
  final AuthUidListenable? _authUid;
  final T Function(Map<String, dynamic>) _fromJson;
  final DocumentReference<Map<String, dynamic>> Function(
    FirebaseFirestore,
    String?,
  ) _docRefBuilder;
  final bool _subscribe;

  // Last materialized data we set as [value]; used to squash metadata churn.
  Map<String, dynamic>? _lastData;

  // Active subscription (if any).
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _sub;

  // Epoch counter to prevent stale async operations from updating state.
  int _epoch = 0;

  /// Whether the repository is currently fetching data from Firestore.
  ///
  /// `true` during initial load, auth transitions, and pending writes.
  /// Use this to drive spinners or progress indicators in the UI.
  final ValueNotifier<bool> isLoading = ValueNotifier<bool>(true);

  String? get _currentUserUid => _authUid?.value;

  /// Whether this repo requires authentication. True when [authUid] was
  /// provided; false for public/unauthenticated collections.
  bool get _isAuthGated => _authUid != null;

  // ── helpers ───────────────────────────────────────────────────────────────
  DocumentReference<Map<String, dynamic>> _docOrThrow() {
    final uid = _currentUserUid;
    if (_isAuthGated && uid == null) {
      throw StateError('No signed-in user; repository is detached.');
    }
    return _docRefBuilder(_fs, uid);
  }

  void _onAuth() => _swap(_currentUserUid);

  // Cancel without blocking the hot path.
  void _cancelSubAsync() {
    final old = _sub;
    _sub = null;
    if (old != null) {
      unawaited(old.cancel());
    }
  }

  /// Attach to the correct document for the given [uid].
  Future<void> _swap(String? uid) async {
    final epoch = ++_epoch;
    isLoading.value = true;

    // Stop previous stream
    _cancelSubAsync();

    if (_isAuthGated && uid == null) {
      // Signed out: clear it all.
      value = null;
      _lastData = null;
      isLoading.value = false;
      return;
    }

    final ref = _docRefBuilder(_fs, uid);

    // 1) Prime from CACHE for instant UI, if available.
    try {
      final cacheSnap = await ref.get(const GetOptions(source: Source.cache));
      if (epoch != _epoch) return; // stale
      if (cacheSnap.exists && cacheSnap.data() != null) {
        final data = Map<String, dynamic>.from(cacheSnap.data()!)
          ..['id'] = cacheSnap.id;
        _lastData = data;
        value = _fromJson(data);
        isLoading.value = false; // we have something useful already
      }
    } catch (_) {
      if (epoch != _epoch) return; // stale
      // Cache might be empty on first run; ignore.
    }

    if (_subscribe) {
      // 2) Live updates; include metadata but ignore metadata-only churn.
      _sub = ref.snapshots(includeMetadataChanges: true).listen((snap) {
        if (epoch != _epoch) return; // stale

        if (!snap.exists || snap.data() == null) {
          // Document was deleted or is empty — clear value.
          if (_lastData != null || value != null) {
            _lastData = null;
            value = null;
          }
          if (!snap.metadata.hasPendingWrites) isLoading.value = false;
          return;
        }

        final next = Map<String, dynamic>.from(snap.data()!)..['id'] = snap.id;

        if (!mapEquals(_lastData, next)) {
          _lastData = next;
          value = _fromJson(next);
        }

        if (!snap.metadata.hasPendingWrites) isLoading.value = false;
      });
    } else {
      // One-shot; prefer server, fall back safely.
      final snap = await ref.get();
      if (epoch != _epoch) return; // stale
      if (snap.exists && snap.data() != null) {
        final data = Map<String, dynamic>.from(snap.data()!)..['id'] = snap.id;
        _lastData = data;
        value = _fromJson(data);
      }
      isLoading.value = false;
    }
  }

  // ── public write API (require signed-in user) ─────────────────────────────

  /// Creates or merges a document with the full model.
  ///
  /// Uses `set` with `merge: true`, so existing fields not present in
  /// [model] are preserved. Throws [StateError] if not authenticated.
  late final write = Command.createAsyncNoResult<T>(
    (T model) =>
        _docOrThrow().set(model.toJson(), SetOptions(merge: true)),
  );

  /// Replaces all fields on the existing document with [model].
  ///
  /// Unlike [write], this fails if the document does not already exist.
  /// Throws [StateError] if not authenticated.
  late final update = Command.createAsyncNoResult<T>(
    (T model) => _docOrThrow().update(model.toJson()),
  );

  /// Partially updates specific fields on the document.
  ///
  /// Only the keys present in the map are modified; all other fields
  /// remain unchanged. Throws [StateError] if not authenticated.
  late final patch = Command.createAsyncNoResult<Map<String, dynamic>>(
    (map) => _docOrThrow().update(map),
  );

  /// Deletes the document.
  ///
  /// Throws [StateError] if not authenticated.
  late final delete = Command.createAsyncNoParamNoResult(
    () => _docOrThrow().delete(),
  );

  // ── lifecycle ─────────────────────────────────────────────────────────────
  @override
  void dispose() {
    _cancelSubAsync();
    _authUid?.removeListener(_onAuth);
    write.dispose();
    update.dispose();
    patch.dispose();
    delete.dispose();
    isLoading.dispose();
    super.dispose();
  }
}
