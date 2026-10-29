import 'dart:convert';
import 'dart:io';

import 'package:dmtools/src/config/property_reader.dart';
import 'package:dmtools/src/js/async_job_pool.dart';
import 'package:dmtools/src/js/job_runner.dart';
import 'package:test/test.dart';

/// Tests for the `runAsync(fn, args)` engine-worker pool
/// (epam/dmtools-dart#224): dispatch/wait mechanics, error propagation,
/// worker-engine parity (params, require, host tools), the
/// `parallelWorkers` knob, and the pool lifecycle.
///
/// Every script defines `action(params)` — the JSRunner contract enforced
/// by [JsJobRunner.runScript].
void main() {
  final fixture = _Fixture();

  setUpAll(() async {
    await fixture.bootPool();
  });

  tearDownAll(fixture.disposePool);

  setUp(fixture.newTmp);

  tearDown(fixture.disposeTmp);

  _registerJobApiCoreTests(fixture);
  _registerJobApiKnobTests(fixture);
  _registerWorkerParityTests(fixture);
  _registerWorkerToolTests(fixture);
  _registerWorkerModuleTests(fixture);
  _registerPoolDispatchTests(fixture);
  _registerPoolErrorTests(fixture);
  _registerDrainPolicyTests(fixture);
}

/// Shared fixtures for the suite (shared 2-worker pool + per-test temp dir).
class _Fixture {
  Directory? _tmp;
  AsyncJobPool? _pool;

  AsyncJobPool get pool => _pool!;
  Directory get tmp => _tmp!;

  /// Boots the shared 2-worker pool once for the suite.
  Future<void> bootPool() async {
    _pool = AsyncJobPool(workers: 2);
    await _pool!.boot();
  }

  void disposePool() {
    _pool?.dispose();
    _pool = null;
  }

  /// Creates a fresh temp dir for a test.
  void newTmp() {
    _tmp = Directory.systemTemp.createTempSync('dmtools_async');
  }

  void disposeTmp() {
    _tmp?.deleteSync(recursive: true);
    _tmp = null;
  }

  String writeScript(String source) {
    final script = File('${tmp.path}/main.js')..writeAsStringSync(source);
    return script.path;
  }

  /// Runs [source] with the test pool enabled (`parallelWorkers: 2`).
  String? runScript(
    String source, {
    Map<String, dynamic>? jobParams,
    JsRunConfig? config,
  }) {
    return const JsJobRunner().runScript(
      scriptPath: writeScript(source),
      jobParams: jobParams ?? const {'parallelWorkers': 2},
      config: config ?? JsRunConfig(pool: pool),
    );
  }
}

/// `runAsync` / `AsyncJob` / `runAsync.all` API surface basics.
void _registerJobApiCoreTests(_Fixture f) {
  test('runAsync returns a job whose wait() yields the function result', () {
    final result = f.runScript('''
function action(params) {
    var job = runAsync(function(args) { return { sum: args.a + args.b }; },
        { a: 2, b: 3 });
    return { r: job.wait() };
}
''');
    expect(jsonDecode(result!), {
      'r': {'sum': 5}
    });
  });

  test('runAsync.all waits every job and returns ordered results', () {
    final result = f.runScript('''
function action(params) {
    var fn = function(args) { return args.n * 10; };
    return runAsync.all([
        runAsync(fn, { n: 1 }),
        runAsync(fn, { n: 2 }),
        runAsync(fn, { n: 3 })
    ]).wait();
}
''');
    expect(jsonDecode(result!), [10, 20, 30]);
  });

  test('runAsync validates its arguments', () {
    final result = f.runScript('''
function action(params) {
    try { runAsync(42, null); return 'no-error'; } catch (e) {
        return String(e);
    }
}
''');
    expect(result, contains('runAsync expects a function'));
  });
}

/// Knob and wiring-fallback behavior for the `runAsync` surface.
void _registerJobApiKnobTests(_Fixture f) {
  test('parallelWorkers knob off keeps the default sequential surface', () {
    final result = f.runScript(
      'function action(params) { return typeof runAsync; }',
      jobParams: const {},
    );
    expect(result, '"undefined"');
  });

  test('runAsync on an unbooted pool surfaces a clear JS error', () {
    final result = f.runScript(
      '''
function action(params) {
    try {
        runAsync(function() { return 1; }, null);
        return 'no-error';
    } catch (e) {
        return String(e);
    }
}
''',
      config: JsRunConfig(pool: AsyncJobPool(workers: 1)),
    );
    expect(result, contains('not booted'));
  });

  test('runScript action-error handling is untouched by the async wiring', () {
    expect(
      () => f.runScript('function action(params) { throw new Error('
          "'action-failed'); }"),
      throwsA(isA<StateError>().having(
        (e) => e.message,
        'message',
        contains('action-failed'),
      )),
    );
  });
}

/// Worker-engine parallelism and error propagation.
void _registerWorkerParityTests(_Fixture f) {
  test('two jobs run in parallel (wall time ~ one job, not the sum)', () {
    final result = f.runScript('''
function action(params) {
    var started = Date.now();
    var fn = function(args) {
        var end = Date.now() + args.ms;
        while (Date.now() < end) { /* busy wait */ }
        return args.ms;
    };
    var total = runAsync.all([
        runAsync(fn, { ms: 400 }),
        runAsync(fn, { ms: 400 })
    ]).wait();
    return { elapsed: Date.now() - started, total: total };
}
''');
    final decoded = jsonDecode(result!) as Map<String, dynamic>;
    final elapsed = decoded['elapsed'] as int;
    // Sequential execution would need >= 800ms of busy wait alone.
    expect(elapsed, lessThan(780), reason: 'jobs must overlap: $decoded');
    expect(decoded['total'], [400, 400]);
  });

  test('worker JS exceptions propagate through wait()', () {
    final result = f.runScript('''
function action(params) {
    try {
        runAsync(function() { throw new Error('boom-in-worker'); }, null)
            .wait();
        return 'no-error';
    } catch (e) {
        return String(e);
    }
}
''');
    expect(result, contains('boom-in-worker'));
  });
}

/// Worker tool-bridge parity (payloads, params, host functions).
void _registerWorkerToolTests(_Fixture f) {
  test('missing files read via worker tools follow the host contract', () {
    final result = f.runScript('''
function action(params) {
    var job = runAsync(function() {
        var raw = file_read({ path: '/nonexistent/async_target.txt' });
        return raw === null ? 'missing-file-is-null' : 'unexpected';
    }, null);
    return String(job.wait());
}
''');
    // The direct `file_read` host function answers a missing file with JS
    // `null` (same contract as on the main engine) — the worker sees the
    // tool payload verbatim, no special async error channel.
    expect(result, '"missing-file-is-null"');
  });

  test('worker engines see params, wrappers, and the full tool bridge', () {
    final file = File('${f.tmp.path}/tool_target.txt')
      ..writeAsStringSync('worker-tool-ok');
    final result = f.runScript('''
function action(params) {
    return runAsync(function(args) {
        return {
            marker: params.jobParams.marker,
            content: file_read({ path: args.path })
        };
    }, { path: '${file.path}' }).wait();
}
''', jobParams: const {
      'parallelWorkers': 2,
      'marker': 'async-marker',
    });
    expect(jsonDecode(result!), {
      'marker': 'async-marker',
      'content': 'worker-tool-ok',
    });
  });

  test('worker engines see overrides snapshotted at dispatch time', () {
    addTearDown(PropertyReader.clearOverrides);
    final result = f.runScript('''
function action(params) {
    set_env_variable('CLI_ALLOWED_COMMANDS', 'printenv');
    set_env_variable('MARKER', 'dispatch-time-value');
    return runAsync(function() {
        return cli_execute_command({command: 'printenv MARKER'});
    }, null).wait();
}
''');
    // Both `set_env_variable` calls run AFTER the pool was wired onto the
    // engine: `printenv` leaves the whitelist and MARKER enters the child
    // env only if the worker sees an override map captured at DISPATCH
    // time (dispatchContext provider), not at attach time
    // (epam/dmtools-dart#242 — Java ThreadLocal overrides parity).
    expect(jsonDecode(result!), 'dispatch-time-value');
  });
}

/// Worker module system and console parity.
void _registerWorkerModuleTests(_Fixture f) {
  test('require inside a worker resolves against the script directory', () {
    File('${f.tmp.path}/dep.js').writeAsStringSync('''
module.exports = { double: function(n) { return n * 2; } };
''');
    final result = f.runScript('''
function action(params) {
    var job = runAsync(function(args) {
        var dep = require('./dep.js');
        return dep.double(args.n);
    }, { n: 21 });
    return job.wait();
}
''');
    expect(result, '42');
  });

  test('console output inside workers does not break execution', () {
    final result = f.runScript('''
function action(params) {
    return runAsync(function() {
        console.log('from worker');
        return 'logged';
    }, null).wait();
}
''');
    expect(result, '"logged"');
  });
}

/// Dart-level pool dispatch mechanics (no JS engine on the caller side).
void _registerPoolDispatchTests(_Fixture f) {
  test('dispatch/wait roundtrip without a JS engine on the caller', () {
    final jobId = f.pool.dispatch(
      fnSource: 'function(args) { return args.x + 1; }',
      argsJson: '{"x":41}',
      scriptDirectory: f.tmp.path,
      params: const {},
    );
    final envelope = f.pool.wait(jobId);
    expect(envelope.ok, isTrue);
    expect(envelope.decodedResult, 42);
  });

  test('fire-and-forget jobs are served by a later wait()', () async {
    final jobId = f.pool.dispatch(
      fnSource: 'function(args) { return args; }',
      argsJson: '"late"',
      scriptDirectory: f.tmp.path,
      params: const {},
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(f.pool.wait(jobId).decodedResult, 'late');
  });
}

/// Pool error surfaces (unknown/double waits, dead workers).
void _registerPoolErrorTests(_Fixture f) {
  test('unknown and double waits fail with clear errors', () {
    expect(
      () => f.pool.wait(999),
      throwsA(isA<StateError>().having(
        (e) => e.message,
        'message',
        contains('Unknown or already-waited'),
      )),
    );
    final jobId = f.pool.dispatch(
      fnSource: 'function(args) { return 1; }',
      argsJson: 'null',
      scriptDirectory: f.tmp.path,
      params: const {},
    );
    f.pool.wait(jobId);
    expect(() => f.pool.wait(jobId), throwsA(isA<StateError>()));
  });

  test('dead workers surface a clear dispatch error', () async {
    final lone = AsyncJobPool(workers: 1);
    await lone.boot();
    addTearDown(lone.dispose);
    // Kill the idle worker — beforeNextEvent lets it unwind (its private
    // HTTP bridge is disposed by its own finally, so no isolate leaks).
    lone.killWorkerForTest(0);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(
      () => lone.dispatch(
        fnSource: 'function(args) { return 1; }',
        argsJson: 'null',
        scriptDirectory: f.tmp.path,
        params: const {},
      ),
      throwsA(isA<StateError>().having(
        (e) => e.message,
        'message',
        contains('no live workers'),
      )),
    );
  });
}

/// Timer-drain error policy (epam/dmtools-dart#243): the MAIN engine
/// propagates a drain failure — the script's timer chain is part of the
/// run's contract (side-effect timers, setTimeout-as-sleep). A WORKER
/// swallows it with a log line: the dispatched fn's own result/error IS
/// the job and must not be masked by a late timer callback.
void _registerDrainPolicyTests(_Fixture f) {
  test('main engine: a throwing timer callback fails the whole run', () {
    expect(
      () => f.runScript(
        '''
function action(params) {
  setTimeout(function () { throw new Error('drain-boom'); }, 0);
  return 'ok';
}
''',
        jobParams: const {'nodeCompat': true, 'parallelWorkers': 2},
      ),
      throwsA(predicate(
        (e) => e.toString().contains('drain-boom'),
        'error mentioning drain-boom',
      )),
    );
  });

  test('worker: a throwing late timer does not mask the fn result', () {
    final result = f.runScript(
      '''
function action(params) {
  return runAsync(
    function () {
      setTimeout(function () { throw new Error('late-boom'); }, 0);
      return 42;
    },
    null
  ).wait();
}
''',
      jobParams: const {'nodeCompat': true, 'parallelWorkers': 2},
    );
    expect(result, '42');
  });
}
