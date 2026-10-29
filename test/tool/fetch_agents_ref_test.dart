@TestOn('linux || mac-os')
library;

// gh-437 AC2: tool/fetch_agents.sh checks out exactly a SHA ref, and a
// branch ref keeps its clone behaviour. Uses a local file:// fixture repo,
// so no network access.
import 'dart:io';

import 'package:test/test.dart';

late Directory tmp;
late String srcPath;
late String firstSha;
late String secondSha;

Future<void> git(List<String> args, {String? dir}) async {
  final r = await Process.run(
    'git',
    args,
    workingDirectory: dir,
    environment: {
      ...Platform.environment,
      'GIT_AUTHOR_NAME': 't',
      'GIT_AUTHOR_EMAIL': 't@t',
      'GIT_COMMITTER_NAME': 't',
      'GIT_COMMITTER_EMAIL': 't@t',
    },
  );
  expect(r.exitCode, 0, reason: 'git ${args.join(' ')}: ${r.stderr}');
}

Future<String> head(String dir) async {
  const args = ['rev-parse', 'HEAD'];
  final r = await Process.run('git', args, workingDirectory: dir);
  return (r.stdout as String).trim();
}

Future<ProcessResult> fetch(String ref, String target) {
  return Process.run(
    'bash',
    ['${Directory.current.path}/tool/fetch_agents.sh'],
    environment: {
      ...Platform.environment,
      'AGENTS_FETCH_URL': 'file://$srcPath',
      'AGENTS_FETCH_REF': ref,
      'AGENTS_FETCH_DIR': target,
    },
  );
}

Future<void> setUpFixture() async {
  tmp = await Directory.systemTemp.createTemp('fetch_agents_ref_');
  srcPath = '${tmp.path}/src';
  await Directory(srcPath).create();
  await git(['init', '-q', '-b', 'main'], dir: srcPath);
  await File('$srcPath/f.txt').writeAsString('one\n');
  await git(['add', '.'], dir: srcPath);
  await git(['commit', '-q', '-m', 'one'], dir: srcPath);
  firstSha = await head(srcPath);
  await File('$srcPath/f.txt').writeAsString('two\n');
  await git(['commit', '-q', '-am', 'two'], dir: srcPath);
  secondSha = await head(srcPath);
}

void main() {
  setUpAll(setUpFixture);

  tearDownAll(() async {
    await tmp.delete(recursive: true);
  });

  test('SHA ref checks out exactly that commit, not main tip', () async {
    final target = '${tmp.path}/by_sha';
    final r = await fetch(firstSha, target);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    expect(await head(target), firstSha);
    expect(await File('$target/f.txt').readAsString(), 'one\n');
    expect(firstSha, isNot(secondSha));
  });

  test('branch ref still clones the branch tip', () async {
    final target = '${tmp.path}/by_branch';
    final r = await fetch('main', target);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    expect(await head(target), secondSha);
    expect(await File('$target/f.txt').readAsString(), 'two\n');
  });
}
