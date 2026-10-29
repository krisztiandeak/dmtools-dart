import 'dart:io';
import 'package:test/test.dart';
import 'package:dmtools/src/agents/instruction_processor.dart';

void main() {
  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('ip_pack');
    Directory(
            '${dir.path}/.dmtools/packs/story_development-0.1.18/instructions/common')
        .createSync(recursive: true);
    File('${dir.path}/.dmtools/packs/story_development-0.1.18/instructions/common/agent_task_preamble.md')
        .writeAsStringSync('PREAMBLE CONTENT');
    File('${dir.path}/notes.md').writeAsStringSync('NOTES');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('absolute pack path with dots in segments is embedded', () {
    final p = InstructionProcessor(workingDirectory: dir.path);
    final prompt =
        'Senior Developer Engineer\n${dir.path}/.dmtools/packs/story_development-0.1.18/instructions/common/agent_task_preamble.md';
    final out = p.process(prompt);
    expect(out, contains('PREAMBLE CONTENT'));
    expect(out, contains('## agent_task_preamble.md'));
    expect(out, isNot(contains('<file path=')));
  });

  test('github/readme URLs are not treated as file paths', () {
    final p = InstructionProcessor(workingDirectory: dir.path);
    final out = p.process(
        'see https://github.com/foo/bar/pull/1 and https://x.com/readme.md ok');
    expect(out, isNot(contains('<file path="https')));
    expect(out, contains('[github-pr:foo/bar#1]'));
  });

  test('relative inline reference still embeds', () {
    final p = InstructionProcessor(workingDirectory: dir.path);
    final out = p.process('read ./notes.md please');
    expect(out, contains('NOTES'));
  });
}
