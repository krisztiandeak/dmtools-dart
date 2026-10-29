/// Synchronous bounded worker pool for frozen event-loop contexts
/// (gh-348 — Java `ConfluenceParallel` parity, dm.ai d61a4abd).
///
/// QuickJS `NativeCallable` callbacks freeze the calling isolate's event
/// loop, so `Future`-based parallelism can never complete there. Like
/// [SyncHttpBridge], this pool spawns worker isolates up front (while the
/// event loop is still alive), submits jobs over `SendPort`s (a native,
/// non-blocking send that works from a blocked FFI callback), and parks
/// the caller's OS thread on `Mailbox.take()` until every job answered.
///
/// Semantics mirror the Java helper:
/// - results keep the input order of the job list;
/// - a job that throws yields `null` instead of aborting the others;
/// - the concurrency bound is the worker count (each worker serves one
///   job at a time — sync HTTP blocks the worker thread, so real
///   parallelism needs N busy workers, not N tasks on one loop);
/// - a pool that was never booted reports `ready == false`; callers are
///   expected to fall back to running jobs inline on the calling isolate.
///
/// The worker entry must be a top-level (or static) function — like
/// `Isolate.spawn` entries everywhere it cannot capture instance state —
/// so each domain defines a tiny entry that delegates to [serveSyncWorker]
/// with its own [SyncWorkerRunner]. Runner closures cannot ride the spawn
/// message; the entry binds them in the worker isolate instead.
///
/// Transport: each job carries its own single-slot reply [Mailbox] (the
/// primitive is one-message deep, so a shared response mailbox cannot
/// serve concurrent workers); the caller collects replies in submission
/// order — already-finished jobs answer instantly, so collection costs
/// about as much as the slowest job.
///
/// Boot discipline: [boot] must complete while the event loop is alive
/// — the CLI boots its pools lazily in `CliDispatcher`, right before a
/// command that can reach them (`SyncHttpBridge.shared` at startup,
/// since every sync tool shares it; the Confluence pool only before a
/// Confluence-capable command). Workers additionally warm their
/// per-isolate [SyncHttpBridge] so their HTTP calls reuse pooled
/// connections instead of spawning one curl process per request.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:native_synchronization/mailbox.dart';
import 'package:native_synchronization/sendable.dart';

import 'sync_http_bridge.dart';

/// Executes one pool job; bound to the worker entry by the domain that
/// owns the pool.
///
/// Must be synchronous (it runs inside blocked FFI contexts on the
/// calling isolate as the inline fallback and inside worker isolates).
/// Any throw is reported back as a `null` result, never propagated.
typedef SyncWorkerRunner = Map<String, dynamic>? Function(
  String kind,
  Map<String, dynamic> args,
);

/// Worker entry point handed to [SyncWorkerPool]; top-level or static so
/// `Isolate.spawn` can resolve it by symbol (no captured state).
typedef SyncWorkerEntry = Future<void> Function(SyncWorkerBoot boot);

/// Boot payload handed to every [SyncWorkerEntry].
class SyncWorkerBoot {
  /// Creates the boot payload for one worker isolate.
  const SyncWorkerBoot({required this.handshake});

  /// Reply port: the worker sends its job-inbox [SendPort] here once.
  final SendPort handshake;
}

/// One unit of parallel work: [kind] selects the runner's handler,
/// [args] is the handler's argument map, [index] restores input order in
/// the result list.
class SyncParallelJob {
  /// Creates a job identified by [index] of [kind] with handler [args].
  const SyncParallelJob({
    required this.index,
    required this.kind,
    this.args = const <String, dynamic>{},
  });

  /// Position of this job in the submitted list; results are keyed by it.
  final int index;

  /// Handler selector interpreted by the pool's [SyncWorkerRunner].
  final String kind;

  /// Sendable argument map for the handler.
  final Map<String, dynamic> args;
}

/// The serve-forever loop behind every [SyncWorkerEntry]: handshakes the
/// job inbox, then answers each job on its own reply mailbox until the
/// pool shuts the inbox down.
///
/// Every failure path answers — the caller is parked in a blocking
/// `Mailbox.take()` and must always wake.
Future<void> serveSyncWorker(
    SyncWorkerBoot boot, SyncWorkerRunner runner) async {
  await SyncHttpBridge.shared.boot();
  final inbox = ReceivePort();
  boot.handshake.send(inbox.sendPort);
  await for (final message in inbox) {
    if (message == 'shutdown') {
      // The pool's dispose sentinel: stop serving, close the ReceivePort so
      // the isolate can exit cleanly, and tear down this worker's per-isolate
      // HTTP worker.
      inbox.close();
      SyncHttpBridge.shared.dispose();
      return;
    }
    if (message is! Map) continue; // foreign traffic
    final job = message.cast<String, dynamic>();
    final reply = (job['reply'] as Sendable<Mailbox>).materialize();
    Map<String, dynamic>? result;
    try {
      result = runner(
        job['kind'] as String,
        (job['args'] as Map).cast<String, dynamic>(),
      );
    } catch (_) {
      result = null; // Java parity: a failing task yields null, not abort.
    }
    reply.put(Uint8List.fromList(
      utf8.encode(jsonEncode(<String, dynamic>{'i': job['i'], 'r': result})),
    ));
  }
}

/// A bounded pool of worker isolates serving synchronous parallel jobs.
///
/// The constructor [entry] must be a top-level function or static method
/// (the same rule as any `Isolate.spawn` entry — closures capturing state
/// are rejected at [boot] time).
class SyncWorkerPool {
  /// Creates a pool booting [entry] workers.
  SyncWorkerPool(
    this._entry, {
    this.name = 'sync-worker',
    this.workerCount = 4,
  });

  final SyncWorkerEntry _entry;

  /// Worker/thread name prefix (diagnostics).
  final String name;

  /// Number of worker isolates; jobs run concurrently up to this bound.
  final int workerCount;

  final List<SendPort> _inboxes = <SendPort>[];
  final List<Isolate> _isolates = <Isolate>[];
  Future<void>? _booting;
  var _next = 0;

  /// Whether [boot] completed and [run] can be used.
  bool get ready => _inboxes.isNotEmpty;

  /// Boots [workerCount] worker isolates; idempotent.
  ///
  /// Must complete while the event loop is alive (see the library docs).
  /// A failed boot is not cached: the error propagates and the next
  /// [boot] call attempts a fresh boot, so a transient failure (isolate
  /// quota, sandbox limit) does not disable the pool for the process
  /// lifetime.
  Future<void> boot() => _booting ??=
          _boot(workerCount < 1 ? 1 : workerCount).catchError((Object e) {
        _booting = null; // let the next boot() retry
        throw e;
      });

  Future<void> _boot(int workers) async {
    for (var i = 0; i < workers; i++) {
      final handshake = ReceivePort();
      final iso = await Isolate.spawn(
        _entry,
        SyncWorkerBoot(handshake: handshake.sendPort),
        debugName: '$name-${i + 1}',
      );
      _isolates.add(iso);
      _inboxes.add(await handshake.first as SendPort);
      handshake.close();
    }
  }

  /// Runs [jobs] across the pool and returns their results in input
  /// order; a job that throws (or an unknown kind) yields `null`.
  ///
  /// Only valid once [ready]; throws [StateError] otherwise — callers
  /// that may run unbooted are expected to check [ready] and fall back to
  /// executing the jobs inline on the calling isolate.
  List<Map<String, dynamic>?> run(List<SyncParallelJob> jobs) {
    if (!ready) {
      throw StateError('SyncWorkerPool "$name" is not booted');
    }
    if (jobs.isEmpty) return const <Map<String, dynamic>>[];
    final replies = _submit(jobs);
    return _collect(replies);
  }

  /// Sends every job to a worker inbox (round-robin) with its own reply
  /// mailbox; returns the mailboxes aligned with [jobs].
  List<Mailbox> _submit(List<SyncParallelJob> jobs) {
    final replies = <Mailbox>[];
    for (final job in jobs) {
      final reply = Mailbox();
      replies.add(reply);
      _inboxes[_next].send(<String, dynamic>{
        'i': job.index,
        'kind': job.kind,
        'args': job.args,
        'reply': reply.asSendable,
      });
      _next = (_next + 1) % _inboxes.length;
    }
    return replies;
  }

  /// Parks this thread until every job answered and restores input order;
  /// jobs that already finished answer instantly.
  List<Map<String, dynamic>?> _collect(List<Mailbox> replies) {
    final results = List<Map<String, dynamic>?>.filled(replies.length, null);
    for (var i = 0; i < replies.length; i++) {
      final env =
          jsonDecode(utf8.decode(replies[i].take())) as Map<String, dynamic>;
      results[env['i'] as int] = env['r'] as Map<String, dynamic>?;
    }
    return results;
  }

  /// Stops the workers (test teardown; the CLI hard-exits instead).
  void dispose() {
    for (final inbox in _inboxes) {
      inbox.send('shutdown');
    }
    _inboxes.clear();
    for (final iso in _isolates) {
      iso.kill(priority: Isolate.beforeNextEvent);
    }
    _isolates.clear();
    _booting = null;
  }
}
