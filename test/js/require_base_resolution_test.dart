import 'dart:convert';
import 'dart:io';

import 'package:dmtools/src/cli/run_command_processor.dart';
import 'package:dmtools/src/js/async_job_pool.dart';
import 'package:dmtools/src/js/job_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// gh-409: relative `require` must resolve against the requiring module's
/// directory (sync + async-pool dispatch), and config action paths must
/// resolve against the config file's directory with a CWD fallback.
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('dmtools_gh409');
    _seedTree(tmp.path);
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test('AC1 sync: module require resolves against its own directory', () {
    expect(_runSync(tmp.path), {'value': 'trackers-ok'});
  });

  test('AC1 negative: genuinely missing target still fails cleanly', () {
    expect(
      () => _runMissing(tmp.path),
      throwsA(
        predicate(
          (e) => e.toString().contains(
                'Failed to require module: ./nope/missing.js',
              ),
        ),
      ),
    );
  });

  test(
    'AC1/AC2 async: dispatched fn resolves its declaring module dir',
    () async {
      expect(
        await _runAsync(tmp.path, 'dispatch', 'asyncEntry', runAll: false),
        'trackers-ok:7',
      );
    },
  );

  test(
    'AC1 async: runAsync.all-aggregated dispatch resolves declaring module dir',
    () async {
      expect(
        await _runAsync(tmp.path, 'dispatchAll', 'asyncEntryAll', runAll: true),
        'trackers-ok:7',
      );
    },
  );

  group('AC3 config action paths', () {
    test('rebased to the config directory and runs from another CWD', () {
      final out = _runConfigRebase(tmp.path);
      expect(out['preJSAction'], p.join(tmp.path, 'cfg', 'hooks/pre.js'));
      expect(out['thenAction'], p.join(tmp.path, 'cfg', 'hooks/pre.js'));
    });

    test('falls back to CWD-relative path when absent from config dir', () {
      expect(_runConfigFallback(tmp.path)['postJSAction'], 'only-in-cwd.js');
    });
  });
}

/// Upstream-style tree: a/js/m.js requires ./common/t.js (only in a/js).
/// The entry lives in a sibling tree so entry-dir probing would fail.
void _seedTree(String root) {
  _write('$root/a/js/m.js', """
var t = require('./common/t.js');
module.exports.run = function (params) { return { value: t.value }; };
""");
  _write(
    '$root/a/js/common/t.js',
    "module.exports = { value: 'trackers-ok' };",
  );
  _write('$root/b/js/entry.js', """
var m = require('../../a/js/m.js');
function action(params) { return m.run(params); }
""");
}

dynamic _runSync(String root) {
  final out = const JsJobRunner().runScript(
    scriptPath: '$root/b/js/entry.js',
    jobParams: const {},
  );
  return jsonDecode(out!);
}

void _runMissing(String root) {
  _write('$root/a/js/bad.js', """
function action(params) { require('./nope/missing.js'); return 1; }
""");
  const JsJobRunner().runScript(
    scriptPath: '$root/a/js/bad.js',
    jobParams: const {},
  );
}

/// Dispatches a function declared in `a/js/<dispatchName>.js` through the
/// async pool, aggregating via `runAsync.all` when [runAll] is set.
Future<dynamic> _runAsync(
  String root,
  String dispatchName,
  String entryName, {
  required bool runAll,
}) async {
  final call =
      runAll ? 'return runAsync.all([job]).wait()[0];' : 'return job.wait();';
  _write('$root/a/js/$dispatchName.js', """
module.exports.run = function (params) {
  var job = runAsync(function (x) {
    var inner = require('./common/t.js');
    return inner.value + ':' + x;
  }, 7);
  $call
};
""");
  _write('$root/b/js/$entryName.js', """
var d = require('../../a/js/$dispatchName.js');
function action(params) { return d.run(params); }
""");
  final pool = AsyncJobPool(workers: 2);
  await pool.boot();
  try {
    final out = const JsJobRunner().runScript(
      scriptPath: '$root/b/js/$entryName.js',
      jobParams: const {'parallelWorkers': 2},
      config: JsRunConfig(pool: pool),
    );
    return jsonDecode(out!);
  } finally {
    pool.dispose();
  }
}

Map<String, dynamic> _runConfigRebase(String root) {
  final cfgDir = Directory('$root/cfg')..createSync();
  _write('${cfgDir.path}/hooks/pre.js', 'function action(p){return 1;}');
  final cfgFile = File('${cfgDir.path}/agent.json')
    ..writeAsStringSync(
      jsonEncode({'preJSAction': 'hooks/pre.js', 'thenAction': 'hooks/pre.js'}),
    );
  return jsonDecode(const RunCommandProcessor().process(['run', cfgFile.path]))
      as Map<String, dynamic>;
}

Map<String, dynamic> _runConfigFallback(String root) {
  final cfgDir = Directory('$root/cfg2')..createSync();
  final cfgFile = File('${cfgDir.path}/agent.json')
    ..writeAsStringSync(jsonEncode({'postJSAction': 'only-in-cwd.js'}));
  return jsonDecode(const RunCommandProcessor().process(['run', cfgFile.path]))
      as Map<String, dynamic>;
}

void _write(String path, String content) {
  File(path)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(content);
}
