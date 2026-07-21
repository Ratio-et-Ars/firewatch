import 'dart:async';

import 'package:flutter/foundation.dart';

import 'json_model.dart';

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
///     write can still fail later. An error arriving **after** the grace can
///     no longer throw (the future has already resolved); it is reported
///     fire-and-forget to the `onPostGraceError` callback when one is
///     provided (the Firewatch repositories wire their `onError` handler
///     here), otherwise swallowed.
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
  /// Errors that arrive before the grace still throw normally.
  ///
  /// Errors that arrive **after** the grace cannot throw through the returned
  /// future (it has already resolved). With [onPostGraceError] set they are
  /// reported there fire-and-forget — exactly once, with the original error
  /// and stack trace — so a late server rejection (e.g. a security-rules
  /// denial on a slow connection) stays observable. Without it they are
  /// swallowed. Post-grace errors never become unhandled zone errors either
  /// way. With a `null` [ackGrace], [onPostGraceError] is never invoked
  /// (errors propagate through the returned future as always).
  Future<T> apply<T>(
    Future<T> write, {
    required T Function() onTimeout,
    FirewatchErrorHandler? onPostGraceError,
  }) {
    final grace = ackGrace;
    if (grace == null) return write;

    var resolvedOptimistically = false;
    if (onPostGraceError != null) {
      // Watch the original write fire-and-forget. Pre-grace errors throw
      // through the returned (timed-out) future below and are NOT reported
      // here; only errors landing after the optimistic resolve are routed to
      // the callback. This listener also guarantees the error is handled, so
      // it can never surface as an unhandled zone error.
      unawaited(
        write.then<void>(
          (_) {},
          onError: (Object error, StackTrace stackTrace) {
            if (resolvedOptimistically) onPostGraceError(error, stackTrace);
          },
        ),
      );
    }

    return write.timeout(grace, onTimeout: () {
      resolvedOptimistically = true;
      return onTimeout();
    });
  }

  /// [apply] specialized for `Future<void>` writes (the common case).
  Future<void> applyVoid(
    Future<void> write, {
    FirewatchErrorHandler? onPostGraceError,
  }) =>
      apply<void>(write, onTimeout: () {}, onPostGraceError: onPostGraceError);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WriteAckPolicy && other.ackGrace == ackGrace;

  @override
  int get hashCode => ackGrace.hashCode;

  @override
  String toString() => 'WriteAckPolicy(ackGrace: $ackGrace)';
}
