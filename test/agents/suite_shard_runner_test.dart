import 'dart:convert';
import 'dart:io';

import 'package:dmtools/src/agents/suite_shard_args.dart';
import 'package:dmtools/src/agents/suite_shard_parity.dart';
import 'package:dmtools/src/agents/suite_shard_runner.dart';
import 'package:dmtools/src/agents/suite_sharding.dart';
import 'package:test/test.dart';

/// gh-315 — end-to-end IT for the sharded agents-suite runner on a fixture
/// mini-agents tree (temp dir with `run_all.json` + fake test files).
///
/// The fixture's `testRunner.js` implements the upstream action contract
/// (`testFiles` in → `{success, passed, failed}` out, silent skip on empty
/// files) so every scenario runs hermetically — no dmtools-agents checkout,
/// no network. One extra test runs the REAL unmodified `testRunner.js` (AC2's
/// "through the unmodified testRunner.js" clause) when the agents/ submodule
/// is checked out.
///
/// Covered acceptance hooks:
/// - AC2: `--shard-index/--total-shards` run only the planned subset and
///   write a valid manifest; invalid combos exit non-zero with a message.
/// - AC3: a planned file that is missing or empty fails BEFORE the engine.
/// - AC5: the no-flag serial path passes the identical full `testFiles`
///   list through and keeps the exit contract.
/// - AC6: parity-tool smoke test on the fixture tree (serial vs sharded).
void main() {
  setUp(_freshTree);
  tearDown(() => tree.dispose());

  _shardedRunTests();
  _invalidComboTests();
  _unknownFlagTests();
  _preflightTests();
  _serialTests();
  _jobParamsPassthroughTests();
  _configErrorShapeTests();
  _configErrorFieldTests();
  _engineCrashTests();
  _engineRedResultTests();
  _failingShardTests();
  _realRunnerTests();
  _parityTests();
  _parityCrashTests();
}

/// Fixture tree shared by every test in this file (recreated per test).
FixtureTree tree = FixtureTree();

void _freshTree() {
  tree = FixtureTree();
  tree.addTestFile('js/unit-tests/test_a1.js', ok: true);
  tree.addTestFile('js/unit-tests/test_a2.js', ok: true);
  tree.addTestFile('js/unit-tests/test_b1.js', ok: true);
  tree.addTestFile('js/unit-tests/test_b2.js', ok: true);
  tree.writeRunAll();
}

void _shardedRunTests() {
  group('sharded run (AC2)', () {
    test('runs only the planned subset and writes a valid manifest', () {
      final manifestPath = '${tree.root.path}/out/manifest-0.json';
      final code = _runShard(0, 2, manifestPath);

      expect(code, 0, reason: 'green shard must exit 0');
      final manifest = _readManifest(manifestPath);
      expect(manifest.shard, 0);
      expect(manifest.total, 2);
      expect(manifest.success, isTrue);
      expect(manifest.failed, 0);
      // Round-robin over [a1, a2, b1, b2] with N=2: shard 0 = a1, b1.
      expect(manifest.plannedFiles,
          ['js/unit-tests/test_a1.js', 'js/unit-tests/test_b1.js']);
      expect(manifest.passed, 2, reason: 'only the planned subset may run');
    });

    test('shard 1 gets the complement subset', () {
      final manifestPath = '${tree.root.path}/out/manifest-1.json';
      final code = _runShard(1, 2, manifestPath);

      expect(code, 0);
      final manifest = _readManifest(manifestPath);
      expect(manifest.passed, 2);
      expect(manifest.plannedFiles,
          ['js/unit-tests/test_a2.js', 'js/unit-tests/test_b2.js']);
    });
  });
}

void _invalidComboTests() {
  group('invalid flag combos exit non-zero before the engine (AC2)', () {
    // The fixture config points at a runner script that does not exist, so
    // if validation DIDN'T reject the args first, the engine start would
    // fail with a "not found" message instead — the message assertions
    // below discriminate the two paths.
    final bogusJsPath = 'js/unit-tests/does-not-exist.js';

    for (final entry in {
      'index >= total': (index: 2, total: 2, message: '--shard-index'),
      'total < 1': (index: 0, total: 0, message: '--total-shards'),
      'negative index': (index: -1, total: 2, message: '--shard-index'),
      'index without total': (index: 0, total: null, message: '--total-shards'),
      'total without index': (index: null, total: 2, message: '--shard-index'),
      'empty planned shard': (index: 4, total: 5, message: 'empty'),
      'missing --manifest-out': (index: 0, total: 2, message: '--manifest-out'),
      'empty --manifest-out value': (
        index: 0,
        total: 2,
        message: '--manifest-out',
      ),
    }.entries) {
      test('${entry.key} is rejected', () {
        expect(
          _rejectCombo(
            jsPath: bogusJsPath,
            shardIndex: entry.value.index,
            totalShards: entry.value.total,
            // The empty-value entry exercises `--manifest-out ""` — a
            // non-null flag that must still be rejected (thread 5).
            manifestOut: switch (entry.key) {
              'missing --manifest-out' => null,
              'empty --manifest-out value' => '',
              _ => '${tree.root.path}/out/manifest.json',
            },
          ),
          contains(entry.value.message),
        );
      });
    }
  });
}

/// Runs one invalid combo through the runner and returns the combined
/// stderr output; the caller asserts the rejection reason.
String _rejectCombo({
  required String jsPath,
  int? shardIndex,
  int? totalShards,
  String? manifestOut,
}) {
  tree.setJsPath(jsPath);
  final out = <String>[];
  final code = runAgentsSuite(
    SuiteShardArgs.parse([
      tree.root.path,
      if (shardIndex != null) ...['--shard-index', '$shardIndex'],
      if (totalShards != null) ...['--total-shards', '$totalShards'],
      if (manifestOut != null) ...['--manifest-out', manifestOut],
    ]),
    err: out.add,
  );
  expect(code, isNot(0), reason: 'expected rejection, got output: $out');
  return out.join('\n');
}

void _unknownFlagTests() {
  group('an unknown flag exits non-zero before the engine (AC2)', () {
    final bogusJsPath = 'js/unit-tests/does-not-exist.js';

    test('an unknown flag is rejected', () {
      tree.setJsPath(bogusJsPath);
      final out = <String>[];
      final code = runAgentsSuite(
        SuiteShardArgs.parse([
          tree.root.path,
          '--shard-index',
          '0',
          '--total-shards',
          '2',
          '--manifest-out',
          '${tree.root.path}/out/manifest.json',
          '--shard-quota',
          '9',
        ]),
        err: out.add,
      );
      expect(code, isNot(0));
      expect(out.join('\n'), contains('unknown'));
    });
  });
}

void _preflightTests() {
  group('pre-flight closes the silent-skip hole (AC3)', () {
    test('a planned EMPTY file fails the shard before the engine runs', () {
      tree.addTestFile('js/unit-tests/test_empty.js', ok: true, empty: true);
      tree.setTestFiles([
        'js/unit-tests/test_a1.js',
        'js/unit-tests/test_empty.js',
      ]);
      final manifestPath = '${tree.root.path}/out/manifest.json';
      final out = <String>[];

      final code = _runShard(0, 1, manifestPath, err: out.add);

      expect(code, isNot(0), reason: 'empty planned file must red the shard');
      expect(out.join('\n'), contains('test_empty.js'));
      final manifest = _readManifest(manifestPath);
      expect(manifest.success, isFalse);
    });

    test('a planned MISSING file fails the shard before the engine runs', () {
      tree.setTestFiles(['js/unit-tests/test_ghost.js']);
      final out = <String>[];

      final code = _runShard(
        0,
        1,
        '${tree.root.path}/out/manifest.json',
        err: out.add,
      );

      expect(code, isNot(0));
      expect(out.join('\n'), contains('test_ghost.js'));
    });

    test('the serial path also fails on a missing file (strictly stricter)',
        () {
      tree.setTestFiles(['js/unit-tests/test_ghost.js']);
      final out = <String>[];

      final code = runAgentsSuite(
        SuiteShardArgs.parse([tree.root.path]),
        err: out.add,
      );

      expect(code, isNot(0));
      expect(out.join('\n'), contains('test_ghost.js'));
    });
  });
}

void _serialTests() {
  group('serial path (AC5)', () {
    test('passes the identical full testFiles list through and exits 0', () {
      final out = <String>[];
      final code = runAgentsSuite(
        SuiteShardArgs.parse([tree.root.path]),
        out: out.add,
      );

      expect(code, 0);
      // The full list reached the engine: all four files counted as passed.
      expect(
          out.join('\n'), contains('Agents suite green: 4 passed, 0 failed.'));
      // No manifest on the serial path — sharding is opt-in.
      expect(File('${tree.root.path}/out').existsSync(), isFalse,
          reason: 'serial run must not write shard artifacts');
    });

    test('a red suite keeps the exit contract (non-zero)', () {
      tree.addTestFile('js/unit-tests/test_red.js', ok: false);
      final out = <String>[];

      final code = runAgentsSuite(
        SuiteShardArgs.parse([tree.root.path]),
        err: out.add,
      );

      expect(code, 1);
      expect(out.join('\n'), contains('Agents suite failed'));
    });
  });
}

void _jobParamsPassthroughTests() {
  // Thread 4 / edge case E2: the historical serial runner forwarded the
  // WHOLE jobParams map to the engine. The runner must keep doing that —
  // only `testFiles` is replaced by the planned subset — so an upstream
  // run_all.json that grows a new jobParams key is not silently dropped.
  group('jobParams passthrough (E2 forward-compat)', () {
    /// A runner script that refuses to run unless the extra key arrived.
    void useKeyCheckingRunner() {
      tree.setRunnerScript('''
function action(params) {
  var p = params.jobParams || params;
  if (p.extraFlag !== 'present') {
    return { success: false, passed: 0, failed: 1 };
  }
  var n = (p.testFiles || []).length;
  return { success: true, passed: n, failed: 0 };
}
''');
    }

    setUp(() {
      tree.extraJobParams['extraFlag'] = 'present';
      tree.writeRunAll(); // rewrite run_all.json with the extra key
      useKeyCheckingRunner();
    });

    test('serial run forwards extra jobParams keys to the engine', () {
      final code = runAgentsSuite(SuiteShardArgs.parse([tree.root.path]));

      expect(code, 0,
          reason: 'the engine must see the whole jobParams map, '
              'not just testFiles');
    });

    test('sharded run forwards extra keys with the planned testFiles subset',
        () {
      final manifestPath = '${tree.root.path}/out/manifest-0.json';
      final code = _runShard(0, 2, manifestPath);

      expect(code, 0);
      final manifest = _readManifest(manifestPath);
      // Round-robin over 4 files with N=2 → 2 planned; the count proves the
      // PLANNED SUBSET was sent together with the extra key (not the full
      // list, not an empty map).
      expect(manifest.passed, 2);
      expect(manifest.success, isTrue);
    });
  });
}

void _configErrorShapeTests() {
  group('config errors exit 2 (run_all.json contract)', () {
    test('a missing run_all.json exits 2', () {
      final out = <String>[];
      final code = runAgentsSuite(
        SuiteShardArgs.parse(['${tree.root.path}/nowhere']),
        err: out.add,
      );
      expect(code, 2);
      expect(out.join('\n'), contains('Config not found'));
    });

    test('a malformed run_all.json exits 2', () {
      File('${tree.root.path}/js/unit-tests/run_all.json')
          .writeAsStringSync('{not json');
      final out = <String>[];
      final code = runAgentsSuite(
        SuiteShardArgs.parse([tree.root.path]),
        err: out.add,
      );
      expect(code, 2);
      expect(out.join('\n'), contains('not valid JSON'));
    });

    test('a non-object params section exits 2', () {
      File('${tree.root.path}/js/unit-tests/run_all.json')
          .writeAsStringSync('{"params": 42}');
      final out = <String>[];
      final code = runAgentsSuite(
        SuiteShardArgs.parse([tree.root.path]),
        err: out.add,
      );
      expect(code, 2);
      expect(out.join('\n'), contains('"params"'));
    });
  });
}

void _configErrorFieldTests() {
  group('config errors exit 2 (run_all.json contract)', () {
    test('a non-string jsPath exits 2', () {
      File('${tree.root.path}/js/unit-tests/run_all.json').writeAsStringSync(
        jsonEncode({
          'params': {
            'jsPath': 7,
            'jobParams': {
              'testFiles': ['js/unit-tests/test_a1.js'],
            },
          },
        }),
      );
      final out = <String>[];
      final code = runAgentsSuite(
        SuiteShardArgs.parse([tree.root.path]),
        err: out.add,
      );
      expect(code, 2);
      expect(out.join('\n'), contains('"jsPath"'));
    });

    test('missing testFiles exits 2', () {
      File('${tree.root.path}/js/unit-tests/run_all.json').writeAsStringSync(
        jsonEncode({
          'params': {
            'jsPath': 'js/unit-tests/testRunner.js',
            'jobParams': <String, dynamic>{},
          },
        }),
      );
      final out = <String>[];
      final code = runAgentsSuite(
        SuiteShardArgs.parse([tree.root.path]),
        err: out.add,
      );
      expect(code, 2);
      expect(out.join('\n'), contains('"testFiles"'));
    });
  });
}

void _engineCrashTests() {
  group('engine failures keep the exit contract and red the manifest', () {
    test('a runner script without action() crashes the shard (exit 1)', () {
      tree.setRunnerScript('// no action function here');
      final manifestPath = '${tree.root.path}/out/manifest.json';
      final out = <String>[];

      final code = _runShard(0, 1, manifestPath, err: out.add);

      expect(code, 1);
      expect(out.join('\n'), contains('Agents suite crashed'));
      final manifest = _readManifest(manifestPath);
      expect(manifest.success, isFalse);
      expect(manifest.passed, 0);
    });

    test('an action() returning undefined fails the run', () {
      tree.setRunnerScript('function action(params) { return; }');
      final out = <String>[];

      final code = _runShard(
        0,
        1,
        '${tree.root.path}/out/manifest.json',
        err: out.add,
      );

      expect(code, 1);
      expect(out.join('\n'), contains('returned no result'));
    });
  });
}

void _engineRedResultTests() {
  group('engine failures keep the exit contract and red the manifest', () {
    test('a non-JSON result fails the run', () {
      tree.setRunnerScript('function action(params) { return "not json"; }');
      final out = <String>[];

      final code = _runShard(
        0,
        1,
        '${tree.root.path}/out/manifest.json',
        err: out.add,
      );

      expect(code, 1);
      expect(out.join('\n'), contains('non-object result'));
    });

    test('a failing result carries its counters into the manifest', () {
      tree.setRunnerScript(
        'function action(params) '
        '{ return {success: false, passed: 3, failed: 1}; }',
      );
      final manifestPath = '${tree.root.path}/out/manifest.json';

      final code = _runShard(0, 1, manifestPath);

      expect(code, 1);
      final manifest = _readManifest(manifestPath);
      expect(manifest.success, isFalse);
      expect(manifest.passed, 3, reason: 'upstream counters carried verbatim');
      expect(manifest.failed, 1);
    });
  });
}

void _failingShardTests() {
  group('sharded run with a failing test file', () {
    test('manifest reports failure and exit code is non-zero', () {
      tree.addTestFile('js/unit-tests/test_red.js', ok: false);
      final manifestPath = '${tree.root.path}/out/manifest.json';
      final out = <String>[];

      final code = _runShard(1, 3, manifestPath, err: out.add);

      expect(code, 1);
      final manifest = _readManifest(manifestPath);
      // Shard 1 of 3 over [a1, a2, b1, b2, red] = a2, red.
      expect(manifest.plannedFiles,
          ['js/unit-tests/test_a2.js', 'js/unit-tests/test_red.js']);
      expect(manifest.success, isFalse);
      expect(manifest.failed, 1);
    });
  });
}

void _realRunnerTests() {
  group('the REAL unmodified testRunner.js shards too (AC2)', () {
    test('subset of fixture tests runs green through the real runner', () {
      const agentsPath = 'agents';
      if (!File('$agentsPath/js/unit-tests/testRunner.js').existsSync()) {
        return; // Submodule not checked out.
      }
      final realTree = FixtureTree.fromRealRunner(agentsPath);
      try {
        realTree.addFixtureTestUsingTestApi('js/unit-tests/test_fx_a.js');
        realTree.addFixtureTestUsingTestApi('js/unit-tests/test_fx_b.js');
        realTree.writeRunAll();

        final manifestPath = '${realTree.root.path}/out/manifest.json';
        final code = runAgentsSuite(
          SuiteShardArgs.parse([
            realTree.root.path,
            '--shard-index',
            '1',
            '--total-shards',
            '2',
            '--manifest-out',
            manifestPath,
          ]),
        );

        expect(code, 0);
        final manifest = _readManifest(manifestPath);
        expect(manifest.success, isTrue);
        expect(manifest.plannedFiles, ['js/unit-tests/test_fx_b.js']);
        expect(manifest.passed, 1, reason: 'one fixture test in this shard');
        expect(manifest.failed, 0);
      } finally {
        realTree.dispose();
      }
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}

void _parityTests() {
  group('suite parity tool (AC6)', () {
    test('reports parity on a clean fixture (serial == sharded)', () {
      final report = runShardParity(
        agentsPath: tree.root.path,
        totalShards: 2,
      );
      expect(report.ok, isTrue, reason: 'mismatches: ${report.mismatches}');
      expect(report.serialOutcome.passed, 4);
      expect(report.shardOutcomes.map((o) => o.passed), [2, 2]);
    });

    test('flags an order-dependent fixture (outcome differs when split)', () {
      // test_order_b.js throws only when it shares an engine with
      // test_order_a.js — the serial shape. Sharded, both pass: the
      // outcome sets differ and the tool must red the report.
      tree.addTestFile(
        'js/unit-tests/test_order_a.js',
        ok: true,
        content: 'globalThis.__parityCanary = true;',
      );
      tree.addTestFile(
        'js/unit-tests/test_order_b.js',
        ok: true,
        content: 'if (globalThis.__parityCanary) '
            '{ throw new Error("order-dependent: ran after test_order_a.js"); }',
      );
      tree.setTestFiles([
        'js/unit-tests/test_order_a.js',
        'js/unit-tests/test_order_b.js',
      ]);

      final report = runShardParity(
        agentsPath: tree.root.path,
        totalShards: 2,
      );
      expect(report.ok, isFalse);
      expect(report.mismatches, isNotEmpty);
    });

    test('a crashing engine shows up as an outcome mismatch', () {
      tree.setRunnerScript('// no action function — every run crashes');
      final report = runShardParity(
        agentsPath: tree.root.path,
        totalShards: 2,
      );
      expect(report.ok, isFalse);
      expect(report.serialOutcome.crash, isNotNull);
      expect(report.shardOutcomes.every((o) => o.crash != null), isTrue);
    });
  }, timeout: const Timeout(Duration(minutes: 2)));
}

void _parityCrashTests() {
  group('suite parity — crashed engine outcomes (AC6)', () {
    test('an action() returning undefined is a crashed outcome', () {
      tree.setRunnerScript('function action(params) { return; }');
      final report = runShardParity(
        agentsPath: tree.root.path,
        totalShards: 1,
      );
      expect(report.ok, isFalse);
      expect(report.serialOutcome.crash, contains('returned undefined'));
    });
  }, timeout: const Timeout(Duration(minutes: 2)));
}

/// Runs one shard of [tree] with [shardIndex] of [total].
int _runShard(
  int shardIndex,
  int total,
  String manifestPath, {
  void Function(String line)? err,
  void Function(String line)? out,
}) {
  return runAgentsSuite(
    SuiteShardArgs.parse([
      tree.root.path,
      '--shard-index',
      '$shardIndex',
      '--total-shards',
      '$total',
      '--manifest-out',
      manifestPath,
    ]),
    err: err ?? (_) {},
    out: out ?? (_) {},
  );
}

ShardManifest _readManifest(String path) => ShardManifest.fromJson(
      jsonDecode(File(path).readAsStringSync()) as Map,
    );

/// A throwaway mini-agents tree: `js/unit-tests/testRunner.js` (a stand-in
/// implementing the upstream action contract) + `run_all.json` + test files.
class FixtureTree {
  FixtureTree() {
    root.createSync(recursive: true);
    _writeRunnerScript();
  }

  /// Builds the tree around the REAL `testRunner.js` + its base modules
  /// (copied read-only from the checked-out agents/ submodule).
  FixtureTree.fromRealRunner(String agentsPath) {
    root.createSync(recursive: true);
    for (final rel in [
      'js/unit-tests/testRunner.js',
      'js/config.js',
      'js/common/scm.js',
      // Upstream testRunner pre-loads machineNotice as a base module
      // (added with the network guard, 2026-10) — the minimal tree must
      // carry everything the preload reads.
      'js/common/machineNotice.js',
      'js/configLoader.js',
      // Preload inventory window: agents main testRunner preloads scmReal()
      // and its gh-1248 leaf modules. Copied best-effort.
      'js/common/reviewThreadInventory.js',
      'js/common/githubReviewFetch.js',
      'js/common/pullRequest.js',
      'js/common/mergeState.js',
      'js/common/loseJson.js',
      'js/common/machineAuthor.js',
      'js/common/legRunVocab.js',
      'js/common/reviewVerdicts.js',
    ]) {
      final src = File('$agentsPath/$rel');
      if (!src.existsSync()) continue;
      final dst = File('${root.path}/$rel');
      dst.createSync(recursive: true);
      dst.writeAsStringSync(src.readAsStringSync());
    }
  }

  final Directory root = Directory.systemTemp.createTempSync('agents_fixture_');

  final List<String> _testFiles = [];

  void addTestFile(
    String relPath, {
    required bool ok,
    bool empty = false,
    String? content,
  }) {
    final file = File('${root.path}/$relPath');
    file.createSync(recursive: true);
    if (empty) {
      file.writeAsStringSync('');
    } else {
      file.writeAsStringSync(
        content ?? (ok ? '// passing test file' : 'throw new Error("boom");'),
      );
    }
    if (!_testFiles.contains(relPath)) {
      _testFiles.add(relPath);
    }
    _syncRunAll();
  }

  /// A fixture test file exercising the REAL testRunner.js global API.
  void addFixtureTestUsingTestApi(String relPath) {
    File('${root.path}/$relPath')
      ..createSync(recursive: true)
      ..writeAsStringSync('''
suite('fixture', function () {
  test('always passes', function () {
    assert.equal(1, 1);
  });
});
''');
    _testFiles.add(relPath);
  }

  /// Replaces the runner script (engine-failure scenarios).
  void setRunnerScript(String source) {
    File('${root.path}/js/unit-tests/testRunner.js').writeAsStringSync(source);
  }

  /// Extra `jobParams` keys written verbatim into run_all.json next to
  /// `testFiles` (forward-compat scenarios — the engine contract is
  /// "forward the whole map").
  final Map<String, String> extraJobParams = {};

  void setTestFiles(List<String> files) {
    _testFiles
      ..clear()
      ..addAll(files);
    _syncRunAll();
  }

  void _syncRunAll() {
    final configPath = '${root.path}/js/unit-tests/run_all.json';
    if (!File(configPath).existsSync()) return;
    _writeRunAllFiles();
  }

  void writeRunAll() {
    if (_testFiles.isEmpty) {
      setTestFiles([
        'js/unit-tests/test_a1.js',
        'js/unit-tests/test_a2.js',
        'js/unit-tests/test_b1.js',
        'js/unit-tests/test_b2.js',
      ]);
      return;
    }
    _writeRunAllFiles();
  }

  void _writeRunAllFiles() {
    File('${root.path}/js/unit-tests/run_all.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode({
        'name': 'JSRunner',
        'params': {
          'jsPath': 'js/unit-tests/testRunner.js',
          'jobParams': {
            'testFiles': _testFiles,
            ...extraJobParams,
          },
        },
      }));
  }

  void setJsPath(String jsPath) {
    final configPath = '${root.path}/js/unit-tests/run_all.json';
    if (!File(configPath).existsSync()) {
      writeRunAll();
    }
    final config =
        jsonDecode(File(configPath).readAsStringSync()) as Map<String, dynamic>;
    (config['params'] as Map<String, dynamic>)['jsPath'] = jsPath;
    File(configPath).writeAsStringSync(jsonEncode(config));
  }

  void _writeRunnerScript() {
    // Minimal stand-in for dmtools-agents testRunner.js — the same
    // action(params) contract: testFiles in, {success, passed, failed} out,
    // silent skip on empty/missing files (the hole the pre-flight closes).
    File('${root.path}/js/unit-tests/testRunner.js')
      ..createSync(recursive: true)
      ..writeAsStringSync('''
function action(params) {
  var p = params.jobParams || params;
  var testFiles = p.testFiles || [];
  var passed = 0, failed = 0;
  for (var i = 0; i < testFiles.length; i++) {
    try {
      var code = file_read({ path: testFiles[i] });
      if (!code || !code.trim()) { continue; }
      eval(code);
      passed++;
    } catch (e) {
      failed++;
    }
  }
  return { success: failed === 0, passed: passed, failed: failed };
}
''');
  }

  void dispose() => root.deleteSync(recursive: true);
}
