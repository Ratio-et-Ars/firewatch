import 'package:flutter/foundation.dart';

/// Controls how long a Firewatch write waits for the Firestore **server
/// acknowledgement** before resolving optimistically.
///
/// ## Why this exists
///
/// Firestore write futures (`set`, `update`, `delete`, `add`,
/// `WriteBatch.commit`) complete only when the **server** acknowledges the
/// write. While offline, the write is durably queued in Firestore's local
/// mutation queue (and is visible to local reads immediately), but the future
/// does not complete until connectivity returns — potentially **never** within
/// the app session.
///
/// That interacts badly with `command_it` Commands: a Command whose wrapped
/// function never completes stays `isRunning` forever, `run()` silently no-ops
/// while a previous execution is in flight, and `runAsync()` returns the
/// original hung future. Because repositories are typically cached (in a
/// registry or DI container), **one offline write permanently bricks that
/// Command for the rest of the session** — every later invocation is silently
/// dropped.
///
/// ## Semantics
///
/// - **`ackGrace == null` (the default):** current/legacy behavior. Write
///   futures await the server ack indefinitely. Fully backwards compatible.
/// - **`ackGrace` set:** the write future is raced against the grace duration.
///   - If the server ack (or an error) arrives **before** the grace elapses,
///     the future completes normally — success resolves, errors throw.
///   - If the grace elapses first, the future **resolves successfully**. This
///     is optimistic-resolve, not failure: the write is already committed to
///     Firestore's local mutation queue and will sync when connectivity
///     returns. It is **not** server-confirmed — a rules rejection or invalid
///     write can still fail later, and any error arriving **after** the grace
///     is swallowed (the future has already resolved).
///
/// ## Guidance
///
/// - Apps that want offline-safe writes should pass a grace of **~1–2
///   seconds**: long enough that online writes normally resolve with a real
///   server ack, short enough that offline writes don't hang UI or Commands.
/// - Transactions are **not** covered by this policy — Firestore transactions
///   require connectivity and have no offline mutation-queue semantics.
/// - "Resolved" under a grace means *durably queued locally, will sync* — do
///   not treat it as proof the server accepted the write. If you need
///   server confirmation (e.g. security-rule-sensitive writes), use the
///   default policy or verify via a snapshot listener.
@immutable
class WriteAckPolicy {
  /// Creates a write-ack policy.
  ///
  /// The default (`ackGrace: null`) preserves legacy behavior: write futures
  /// await the server acknowledgement indefinitely.
  const WriteAckPolicy({this.ackGrace});

  /// How long to wait for the server ack before resolving optimistically.
  ///
  /// `null` means wait indefinitely (legacy behavior).
  final Duration? ackGrace;

  /// Whether this policy resolves writes optimistically after [ackGrace].
  bool get isGraced => ackGrace != null;

  /// Applies this policy to [write].
  ///
  /// With a `null` [ackGrace] the future is returned unchanged. With a grace,
  /// the future is capped: if it has not settled when the grace elapses, the
  /// returned future completes with `onTimeout()` (optimistic resolve).
  /// Errors that arrive before the grace still throw normally; errors that
  /// arrive after it are swallowed (the returned future has already resolved).
  Future<T> apply<T>(Future<T> write, {required T Function() onTimeout}) {
    final grace = ackGrace;
    if (grace == null) return write;
    return write.timeout(grace, onTimeout: onTimeout);
  }

  /// [apply] specialized for `Future<void>` writes (the common case).
  Future<void> applyVoid(Future<void> write) =>
      apply<void>(write, onTimeout: () {});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WriteAckPolicy && other.ackGrace == ackGrace;

  @override
  int get hashCode => ackGrace.hashCode;

  @override
  String toString() => 'WriteAckPolicy(ackGrace: $ackGrace)';
}
