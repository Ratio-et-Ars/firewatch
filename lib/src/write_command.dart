import 'dart:async';
import 'dart:collection';

import 'package:command_it/command_it.dart';

/// A write call that has been sent to Firestore and is waiting for its
/// Command execution.
class _Pending<P, R> {
  _Pending(this.param, this.write, this.done);

  final P? param;
  final Future<R> write;

  /// Set for [WriteCommand.runAsync] calls; completes with this write's own
  /// outcome.
  final Completer<R>? done;

  void finish() {
    final d = done;
    if (d != null && !d.isCompleted) {
      write.then(d.complete, onError: d.completeError);
    }
  }
}

/// Holds the write the current Command execution reports on. Shared with the
/// function handed to the base Command, which is built before `this` exists.
class _Slot<R> {
  Future<R>? write;
}

/// A `command_it` Command for repository writes that never drops a call.
///
/// A plain async Command ignores `run()` while a previous run is in flight.
/// Firestore write futures complete only on the **server ack** (never, while
/// offline), so a plain write Command silently dropped every call made while
/// an earlier write was unacknowledged.
///
/// Here every `run(x)` / `runAsync(x)` sends its write to Firestore at once,
/// in call order, so the write reaches the local cache immediately and writes
/// to the same document keep their order. Each write then gets its own
/// Command execution, one at a time and in call order, which only waits for
/// that write's ack. So, per write, exactly as before:
/// - the result lands in `value` / `results`;
/// - an error goes through the Command's error filter to `errors`, `results`
///   and `Command.globalExceptionHandler`;
/// - `runAsync(x)` completes with x's own outcome.
///
/// `isRunning` is `true` while any write is unacknowledged (it may report
/// `false` for one microtask between two queued writes).
///
/// Only for writes: the write itself must not depend on Command state, since
/// it starts before its execution.
class WriteCommand<P, R> extends CommandAsync<P, R> {
  WriteCommand._(
    this._start,
    _Slot<R> slot, {
    required super.initialValue,
    required super.noReturnValue,
    required bool noParam,
  }) : _slot = slot,
       super(
         func: noParam ? null : (_) => slot.write!,
         funcNoParam: noParam ? () => slot.write! : null,
         restriction: null,
         ifRestrictedRunInstead: null,
         // ignore: deprecated_member_use
         ifRestrictedExecuteInstead: null,
         includeLastResultInCommandResults: false,
         errorFilter: null,
         errorFilterFn: null,
         notifyOnlyWhenValueChanges: false,
         name: null,
         noParamValue: noParam,
       ) {
    isRunningSync.addListener(_onRunningChanged);
  }

  /// A write Command with a parameter and a result (e.g. `add` → new ID).
  static Command<P, R> withResult<P, R>(
    Future<R> Function(P param) write, {
    required R initialValue,
  }) => WriteCommand<P, R>._(
    write,
    _Slot<R>(),
    initialValue: initialValue,
    noReturnValue: false,
    noParam: false,
  );

  /// A write Command with a parameter and no result (e.g. `set`).
  static Command<P, void> noResult<P>(Future<void> Function(P param) write) =>
      WriteCommand<P, void>._(
        write,
        _Slot<void>(),
        initialValue: null,
        noReturnValue: true,
        noParam: false,
      );

  /// A write Command with no parameter and no result (e.g. a doc `delete`).
  static Command<void, void> noParamNoResult(Future<void> Function() write) =>
      WriteCommand<void, void>._(
        (_) => write(),
        _Slot<void>(),
        initialValue: null,
        noReturnValue: true,
        noParam: true,
      );

  final Future<R> Function(P param) _start;
  final _Slot<R> _slot;
  final Queue<_Pending<P, R>> _queue = Queue<_Pending<P, R>>();
  _Pending<P, R>? _inFlight;
  bool _disposed = false;

  @override
  void run([P? param]) => _send(param, null);

  @override
  Future<R> runAsync([P? param]) {
    final done = Completer<R>();
    _send(param, done);
    return done.future;
  }

  void _send(P? param, Completer<R>? done) {
    if (_disposed) {
      done?.complete(value);
      return;
    }
    // Future.sync: a write that throws while being built (no signed-in user)
    // becomes a failed write, reported by its execution like any other.
    final write = Future<R>.sync(() => _start(param as P));
    // Its execution reports the error; this only keeps it from also
    // surfacing as an unhandled zone error (e.g. after dispose).
    unawaited(write.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
    _queue.add(_Pending<P, R>(param, write, done));
    _next();
  }

  /// Starts the execution for the oldest waiting write, if none is running.
  void _next() {
    if (_disposed || _queue.isEmpty || isRunningSync.value) return;
    final pending = _queue.removeFirst();
    _inFlight = pending;
    _slot.write = pending.write;
    super.run(pending.param);
  }

  void _onRunningChanged() {
    if (isRunningSync.value) return;
    // The execution has published its result or error; hand the same outcome
    // to its runAsync caller, then move on. A microtask, so the base Command
    // finishes its own bookkeeping first.
    final finished = _inFlight;
    _inFlight = null;
    finished?.finish();
    scheduleMicrotask(_next);
  }

  @override
  void dispose() {
    _disposed = true;
    isRunningSync.removeListener(_onRunningChanged);
    // The writes were already sent; their runAsync callers still get each
    // write's outcome, but no more executions report on them.
    _inFlight?.finish();
    _inFlight = null;
    for (final pending in _queue) {
      pending.finish();
    }
    _queue.clear();
    super.dispose();
  }
}
