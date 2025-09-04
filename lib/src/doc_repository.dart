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
    required FirebaseFirestore firestore,
    required T Function(Map<String, dynamic>) fromJson,
    required DocumentReference<Map<String, dynamic>> Function(
      FirebaseFirestore fs,
      String? uid,
    ) docRefBuilder,
    AuthUidListenable? authUid, // optional auth source
    bool subscribe = true,
  })  : _fs = firestore,
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

  // Expose loading state so UIs can show spinners/progress bars.
  final ValueNotifier<bool> isLoading = ValueNotifier<bool>(true);

  String? get _currentUserUid => _authUid?.value;

  // ── helpers ───────────────────────────────────────────────────────────────
  DocumentReference<Map<String, dynamic>> _docOrThrow() {
    final uid = _currentUserUid;
    if (uid == null) {
      throw StateError('No signed-in user; repository is detached.');
    }
    return _docRefBuilder(_fs, uid);
  }

  void _onAuth() => _swap(_currentUserUid);

  /// Attach to the correct document for the given [uid].
  Future<void> _swap(String? uid) async {
    isLoading.value = true;

    // Stop previous stream
    await _sub?.cancel();
    _sub = null;

    if (uid == null) {
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
      if (cacheSnap.exists && cacheSnap.data() != null) {
        final data = Map<String, dynamic>.from(cacheSnap.data()!)
          ..['id'] = cacheSnap.id;
        _lastData = data;
        value = _fromJson(data);
        isLoading.value = false; // we have something useful already
      }
    } catch (_) {
      // Cache might be empty on first run; ignore.
    }

    if (_subscribe) {
      // 2) Live updates; include metadata but ignore metadata-only churn.
      _sub = ref.snapshots(includeMetadataChanges: true).listen((snap) {
        if (!snap.exists || snap.data() == null) {
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
      if (snap.exists && snap.data() != null) {
        final data = Map<String, dynamic>.from(snap.data()!)..['id'] = snap.id;
        _lastData = data;
        value = _fromJson(data);
      }
      isLoading.value = false;
    }
  }

  // ── public write API (require signed-in user) ─────────────────────────────
  late final write = Command.createAsync(
    (T model, {bool merge = true}) async =>
        (await _docOrThrow().set(model.toJson(), SetOptions(merge: merge))),
    initialValue: null,
  );

  late final update = Command.createAsync(
    (T update) async => _docOrThrow().update(update.toJson()),
    initialValue: null,
  );

  late final patch = Command.createAsync<Map<String, dynamic>, void>(
    (map) async => _docOrThrow().update(map),
    initialValue: null,
  );

  late final delete = Command.createAsyncNoParam(
    () => _docOrThrow().delete(),
    initialValue: null,
  );

  // ── lifecycle ─────────────────────────────────────────────────────────────
  @override
  void dispose() {
    _sub?.cancel();
    _authUid?.removeListener(_onAuth);
    isLoading.dispose();
    super.dispose();
  }
}
