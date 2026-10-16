/// Unit tests for the local SM tick helper (gh-152).
///
/// `scripts/machine_tick.sh` is the pre-flight twin of the machine-sm.yml
/// cron tick: agents/docs/machine-factory-integration.md (Troubleshooting)
/// recommends "run a local tick" before enabling the rules on a target repo,
/// but until gh-152 that meant hand-assembling `dmtools run sm_github.json`
/// with the right jobParams override, the factory ref and the token.
///
/// Pinned contracts:
/// - file surface: bash, `set -euo pipefail`, tracked with the executable
///   bit (mode 100755), `bash -n` and `shellcheck` clean;
/// - flags: `--dry` (default), `--live`, `--ref <sha|branch>`;
/// - nothing about the target repository is hardcoded — the repo resolves
///   from `git remote get-url origin`, the default engine ref from the
///   `agents` submodule pin (what production executes);
/// - configuration errors exit 2 (wrong cwd, no token) and the token is
///   consumed but never printed;
/// - the README machine-loop section points at the helper.
library;

import 'dart:io';

import 'package:test/test.dart';

const _scriptPath = 'scripts/machine_tick.sh';

/// `Process.runSync` throws (not exit≠0) when the binary is missing.
bool _shellcheckInstalled() {
  try {
    return Process.runSync('shellcheck', ['--version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

/// Fake PAT for the dmtools.env leak check — must never surface in output.
const _fixtureToken = 'ghp_machine_tick_fixture_0123456789abcdef';

final File _script = File(_scriptPath).absolute;

String _read(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    fail('missing expected file: $path');
  }
  return file.readAsStringSync();
}

/// Runs the tick script from [cwd] with [args]. [env] replaces the parent
/// environment entirely (pass `_envWithoutSourceToken` to prove the script
/// does not lean on an ambient token).
ProcessResult _runTick(
    String cwd, List<String> args, Map<String, String>? env) {
  return Process.runSync(
    'bash',
    [_script.absolute.path, ...args],
    workingDirectory: cwd,
    environment: env ?? {...Platform.environment},
    // The maps passed here are complete — never merge the parent back in,
    // or stripping SOURCE_GITHUB_TOKEN from the map would be a no-op.
    includeParentEnvironment: false,
  );
}

/// The parent environment with SOURCE_GITHUB_TOKEN stripped.
Map<String, String> _envWithoutSourceToken() => {
      for (final entry in Platform.environment.entries)
        if (entry.key != 'SOURCE_GITHUB_TOKEN') entry.key: entry.value,
    };

/// One git command in [cwd]; fails the test when git exits non-zero.
String _git(String cwd, List<String> args) {
  final result = Process.runSync('git', args, workingDirectory: cwd);
  expect(result.exitCode, 0,
      reason: 'git ${args.join(" ")} failed: ${result.stderr}');
  return result.stdout as String;
}

/// A throwaway "target repo": git checkout with an origin remote, an
/// `agents` tree entry and a .gitmodules — the minimum surface the script
/// probes. The .gitmodules URL is a local path that can never clone, so the
/// script always stops at a config error without touching the network.
Directory _tempRepo({bool dmtoolsEnv = false}) {
  final dir = Directory.systemTemp.createTempSync('machine_tick_fixture_');
  addTearDown(() => dir.deleteSync(recursive: true));
  _git(dir.path, ['init', '-q']);
  _git(dir.path, [
    'remote',
    'add',
    'origin',
    'https://github.com/octocat/machine-tick-target.git',
  ]);
  Directory('${dir.path}/agents').createSync();
  File('${dir.path}/agents/README.md').writeAsStringSync('fixture pin\n');
  File('${dir.path}/.gitmodules').writeAsStringSync(
    '[submodule "agents"]\n'
    '\tpath = agents\n'
    '\turl = /nonexistent/machine-tick-fixture.git\n',
  );
  _git(dir.path, ['add', '-A']);
  _git(dir.path, [
    '-c',
    'user.name=machine-tick-fixture',
    '-c',
    'user.email=fixture@example.com',
    'commit',
    '-q',
    '-m',
    'fixture',
  ]);
  if (dmtoolsEnv) {
    File('${dir.path}/dmtools.env')
        .writeAsStringSync('SOURCE_GITHUB_TOKEN=$_fixtureToken\n');
  }
  return dir;
}

void main() {
  fileSurfaceTests();
  flagContractTests();
  noHardcodeTests();
  behaviorConfigErrorTests();
  behaviorArgParseTests();
  readmePointerTests();
}

/// gh-152 acceptance: valid bash, shellcheck-clean, executable bit set.
void fileSurfaceTests() {
  group('contract: file surface', () {
    test('exists and enforces strict bash mode', () {
      final script = _read(_scriptPath);
      expect(script, startsWith('#!/usr/bin/env bash'));
      expect(script, contains('set -euo pipefail'));
    });

    test('is tracked with the executable bit (mode 100755)', () {
      final ls = Process.runSync('git', ['ls-files', '-s', _scriptPath]);
      expect(ls.exitCode, 0, reason: ls.stderr);
      final entry = (ls.stdout as String).trim();
      expect(entry, isNotEmpty, reason: '$_scriptPath must be tracked by git');
      expect(
        entry.startsWith('100755'),
        isTrue,
        reason: 'the tick must be executable — stage it with '
            '`git update-index --chmod=+x $_scriptPath`; git reports: $entry',
      );
    });

    test('carries the POSIX owner-exec bit on the filesystem', () {
      if (Platform.isWindows) {
        return; // no POSIX mode bits there
      }
      final mode = File(_scriptPath).statSync().mode;
      // 0x40 = S_IXUSR (owner-exec, octal 100 — Dart has no 0o literals).
      expect(mode & 0x40, isNot(0), reason: 'owner-exec bit missing');
    });

    test('parses as bash (bash -n)', () {
      final result = Process.runSync('bash', ['-n', _scriptPath]);
      expect(result.exitCode, 0, reason: result.stderr);
    });

    test('shellcheck is clean (skipped when not installed)', () {
      if (!_shellcheckInstalled()) {
        return; // CI images ship shellcheck; locally this is best-effort
      }
      final result = Process.runSync('shellcheck', [_scriptPath]);
      expect(
        result.exitCode,
        0,
        reason: 'shellcheck findings — fix them in the script, do not '
            'suppress:\n${result.stdout}',
      );
    });
  });
}

/// The dry/live/ref surface, and the factory-parity override format.
void flagContractTests() {
  group('contract: flags', () {
    final script = _read(_scriptPath);

    test('declares --dry, --live and --ref', () {
      for (final flag in ['--dry', '--live', '--ref']) {
        expect(script, contains(flag), reason: 'missing flag: $flag');
      }
      expect(script, contains('mode="dry"'), reason: 'dry must be the default');
      expect(script, contains('mode="live"'), reason: 'live must be reachable');
    });

    test('the override mirrors factory-sm.yml (dryRun only in dry mode)', () {
      expect(script, contains('{"params":{"jobParams":{"repo":"%s"%s}}}'),
          reason: 'the factory passes jobParams.repo (+dryRun when dry)');
      expect(script, contains(',"dryRun":true'),
          reason: 'dry mode must set dryRun:true');
      expect(
        script.contains('"dryRun":false'),
        isFalse,
        reason: 'the factory live branch omits dryRun entirely — a '
            'dryRun:false key is a factory skew',
      );
    });

    test('documents the exit-code contract (0 / 1 / 2)', () {
      expect(script, contains('CONFIG_EXIT=2'));
      expect(script, contains('ENGINE_EXIT=1'));
    });

    test('invokes the same engine entrypoint as factory-sm.yml', () {
      expect(script, contains('sm_github.json'));
      expect(script, contains('run sm_github.json'));
    });
  });
}

/// Nothing about the deployment may be hardcoded: the helper must work on
/// any target repo that replicates the factory wiring.
void noHardcodeTests() {
  group('contract: no hardcoded deployment', () {
    final script = _read(_scriptPath);

    test('never names this repository', () {
      expect(script, isNot(contains('epam/dmtools-dart')));
    });

    test('resolves the repo from the origin remote', () {
      expect(script, contains('git remote get-url origin'));
    });

    test('defaults the ref to the agents submodule pin', () {
      expect(script, contains('git ls-tree HEAD agents'));
    });

    test('reuses the checked-out submodule when it already matches', () {
      expect(script, contains('git -C agents rev-parse HEAD'));
    });
  });
}

/// Behavioral config-error surface: every wrong-setup path exits 2 with a
/// human hint, and the dmtools.env token is consumed but never printed.
void behaviorConfigErrorTests() {
  group('behavior: config errors exit 2, secrets stay hidden', () {
    test('exits 2 outside a git repository', () {
      final dir = Directory.systemTemp.createTempSync('machine_tick_nogit_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final result = _runTick(dir.path, [], null);
      expect(result.exitCode, 2, reason: '${result.stdout}${result.stderr}');
      expect('${result.stdout}${result.stderr}',
          contains('not inside a git repository'));
    });

    test('exits 2 from a repository subdirectory', () {
      final repo = _tempRepo();
      final sub = Directory('${repo.path}/sub')..createSync();
      final result = _runTick(sub.path, [], null);
      expect(result.exitCode, 2, reason: '${result.stdout}${result.stderr}');
      expect('${result.stdout}${result.stderr}', contains('subdirectory'));
    });

    test('exits 2 with a hint when no SOURCE_GITHUB_TOKEN anywhere', () {
      final repo = _tempRepo();
      final result = _runTick(repo.path, [], _envWithoutSourceToken());
      expect(result.exitCode, 2, reason: '${result.stdout}${result.stderr}');
      expect(
          '${result.stdout}${result.stderr}', contains('SOURCE_GITHUB_TOKEN'));
    });

    test('a dmtools.env token is consumed but never printed', () {
      final repo = _tempRepo(dmtoolsEnv: true);
      final result = _runTick(repo.path, [], _envWithoutSourceToken());
      expect(
        result.exitCode,
        2,
        reason: 'the fixture cannot run the engine — a config error (2) is '
            'expected, not a run: ${result.stdout}${result.stderr}',
      );
      final output = '${result.stdout}${result.stderr}';
      expect(output, isNot(contains(_fixtureToken)),
          reason: 'the token value must never reach stdout/stderr');
    });
  });
}

/// Argument parsing rejects garbage before touching the working tree.
void behaviorArgParseTests() {
  group('behavior: argument parsing', () {
    test('--help prints usage and exits 0', () {
      final result = _runTick(Directory.systemTemp.path, ['--help'], null);
      expect(result.exitCode, 0, reason: result.stderr);
      for (final flag in ['--dry', '--live', '--ref']) {
        expect(result.stdout, contains(flag));
      }
    });

    test('--ref without a value is a config error (exit 2)', () {
      final result = _runTick(Directory.systemTemp.path, ['--ref'], null);
      expect(result.exitCode, 2, reason: '${result.stdout}${result.stderr}');
      expect('${result.stdout}${result.stderr}', contains('--ref'));
    });

    test('an unknown flag is a config error (exit 2)', () {
      final result =
          _runTick(Directory.systemTemp.path, ['--frobnicate'], null);
      expect(result.exitCode, 2, reason: '${result.stdout}${result.stderr}');
      expect('${result.stdout}${result.stderr}', contains('--frobnicate'));
    });
  });
}

/// The README machine-loop section must point at the local tick (gh-152
/// acceptance: the guide pointer gains the one-liner).
void readmePointerTests() {
  group('contract: README points at the local tick', () {
    test('the machine-loop section mentions ./scripts/machine_tick.sh', () {
      final readme = File('README.md').readAsStringSync();
      final machineLoop = readme.indexOf('## Machine loop');
      expect(machineLoop, greaterThan(-1),
          reason: 'README.md must keep its Machine loop section');
      final nextSection = readme.indexOf('\n## ', machineLoop + 1);
      final section = nextSection == -1
          ? readme.substring(machineLoop)
          : readme.substring(machineLoop, nextSection);
      expect(section, contains('./scripts/machine_tick.sh'),
          reason: 'the machine-loop section must tell readers about the '
              'local tick (`./scripts/machine_tick.sh`)');
    });
  });
}
