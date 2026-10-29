import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:dmtools/src/compile/agent_pack_compiler.dart';
import 'package:test/test.dart';

/// Tests for [AgentPackCompiler] (dm.ai #595): closure walking, path
/// normalization, transitive JS scanning, deterministic zip, manifest schema.
/// Java parity: `AgentPackCompilerTest`.
void main() {
  setUp(() {
    agentRoot = Directory.systemTemp.createTempSync('pack_agents_');
    outDir = Directory.systemTemp.createTempSync('pack_dist_');
  });

  tearDown(() {
    agentRoot.deleteSync(recursive: true);
    outDir.deleteSync(recursive: true);
  });

  closureTests();
  referenceKindTests();
  workerSourceTests();
  manifestTests();
  scriptsTests();
  prefixNormalizationTests();
  conditionalCliPromptsTests();
  thenActionClosureTests();
  extraDirsTests();
  commentStripperTests();
}

late Directory agentRoot;
late Directory outDir;

/// Writes [content] to [relativePath] under the agent root; returns the file.
File write(String relativePath, String content) {
  final file = File('${agentRoot.path}/$relativePath');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(content);
  return file;
}

/// A minimal agent referencing one JS file with a relative require.
File writeSimpleAgent() {
  write('js/common/util.js', '// util\n');
  write('js/main.js', "var u = require('./common/util.js');\n");
  return write(
      'my_agent.json',
      jsonEncode({
        'name': 'Teammate',
        'params': {'jsPath': 'agents/js/main.js'},
      }));
}

/// Reads all zip entry names.
List<String> zipNames(File zipFile) {
  final archive = ZipDecoder().decodeBytes(zipFile.readAsBytesSync());
  return archive.files.map((f) => f.name).toList();
}

PackResult compileAgent(File entry,
        {String version = '1.0.0', List<String> extraDirs = const []}) =>
    AgentPackCompiler(agentRoot.path)
        .compile(entry, version, 'abc123', outDir, extraDirs: extraDirs);

/// Closure walking: transitive requires, missing-file negatives.
void closureTests() {
  group('AgentPackCompiler closure', () {
    test('includes entry and transitive JS', () {
      final result = compileAgent(writeSimpleAgent());
      expect(result.zipFile.existsSync(), isTrue);
      expect(result.manifestFile.existsSync(), isTrue);
      expect(result.shaFile.existsSync(), isTrue);

      final names = zipNames(result.zipFile);
      expect(names, contains('my_agent.json'));
      expect(names, contains('js/main.js'));
      expect(names, contains('js/common/util.js')); // transitive require
      expect(names, contains('manifest.json'));
      expect(names, isNot(contains('agents/js/main.js'))); // prefix stripped
    });

    test('missing referenced file fails with the exact path', () {
      final entry = write(
          'broken.json',
          jsonEncode({
            'name': 'X',
            'params': {'jsPath': 'agents/js/does_not_exist.js'},
          }));
      expect(
        () => compileAgent(entry),
        throwsA(isA<AgentPackException>().having(
            (e) => e.message, 'message', contains('does_not_exist.js'))),
      );
      expect(outDir.listSync(), isEmpty); // nothing written on failure
    });
  });
}

/// Reference-kind handling: URLs and classpath: refs are skipped.
void referenceKindTests() {
  group('AgentPackCompiler reference kinds', () {
    test('URL and classpath references are ignored', () {
      write('js/main.js', '// main\n');
      final entry = write(
          'mixed.json',
          jsonEncode({
            'name': 'X',
            'params': {
              'preJSAction': 'js/main.js',
              'postJSAction': 'https://github.com/user/repo/blob/main/x.js',
              'timerJSAction': 'classpath:js/timer.js',
            },
          }));
      expect(compileAgent(entry).zipFile.existsSync(), isTrue);
    });

    test('require inside a JSDoc comment is not matched', () {
      write('js/common/commentMarkup.js',
          '/**\n * var m = require("./common/commentMarkup.js");\n */\n');
      write('js/main.js', "var c = require('./common/commentMarkup.js');\n");
      final entry = write(
          'commented.json',
          jsonEncode({
            'name': 'X',
            'params': {'jsPath': 'agents/js/main.js'},
          }));
      final names = zipNames(compileAgent(entry).zipFile);
      expect(names, contains('js/common/commentMarkup.js'));
    });
  });
}

/// Embedded worker sources (dmtools-agents f377609 smAsync): require() calls
/// inside string literals must NOT enter the closure as real references.
void workerSourceTests() {
  group('embedded worker-source strings', () {
    test(
        'require inside an embedded worker-source string is not matched '
        '(dmtools-agents f377609 smAsync workers)', () {
      // githubSource.js embeds runAsync worker bodies as string literals;
      // their `require('./common/smProvider.js')` must NOT be resolved
      // against the embedding file's directory (js/sm/common/… does not
      // exist) — only real top-level requires enter the closure.
      write('js/common/smProvider.js', 'exports.create = function() {};\n');
      write(
        'js/sm/sources/githubSource.js',
        [
          "var WORKER = [",
          "  'function(args) {',",
          "  \"    var mod = require('./common/smProvider.js');\",",
          "  '    return mod.create();',",
          "  '}'",
          "].join('\n');",
          "var real = require('../../common/smProvider.js');",
        ].join('\n'),
      );
      final entry = write(
          'worker.json',
          jsonEncode({
            'name': 'X',
            'params': {'jsPath': 'js/sm/sources/githubSource.js'},
          }));
      final names = zipNames(compileAgent(entry).zipFile);
      expect(names, contains('js/common/smProvider.js')); // real require
      expect(names, isNot(contains('js/sm/common/smProvider.js')));
    });
  });
}

/// Manifest schema and deterministic-zip invariants.
void manifestTests() {
  group('AgentPackCompiler manifest', () {
    test('carries agent, version, files with sha256+mode', () {
      final result = compileAgent(writeSimpleAgent(), version: '1.2.0');
      final manifest = jsonDecode(result.manifestFile.readAsStringSync())
          as Map<String, dynamic>;

      expect(manifest['agent'], 'my_agent');
      expect(manifest['version'], '1.2.0');
      expect(manifest['sourceCommit'], 'abc123');
      expect(manifest['defaultEntry'], 'my_agent.json');
      expect(manifest.containsKey('minDmtoolsVersion'), isTrue);

      final files = manifest['files'] as List;
      final main = files.firstWhere((f) => (f as Map)['path'] == 'js/main.js')
          as Map<String, dynamic>;
      expect((main['sha256'] as String).length, 64);
      expect(main['mode'], '0644');
    });

    test('repeated builds are byte-identical', () {
      final entry = writeSimpleAgent();
      final out1 = Directory.systemTemp.createTempSync('d1_');
      final out2 = Directory.systemTemp.createTempSync('d2_');
      final r1 = AgentPackCompiler(agentRoot.path)
          .compile(entry, '1.0.0', 'abc', out1);
      final r2 = AgentPackCompiler(agentRoot.path)
          .compile(entry, '1.0.0', 'abc', out2);
      expect(r1.zipFile.readAsBytesSync(), r2.zipFile.readAsBytesSync());
      out1.deleteSync(recursive: true);
      out2.deleteSync(recursive: true);
    });
  });
}

/// scripts/ subtree embedding and exec-mode recording.
void scriptsTests() {
  group('AgentPackCompiler scripts', () {
    test('any scripts reference embeds the whole scripts subtree', () {
      write('scripts/run-agent.sh', '#!/bin/bash\necho hi\n');
      write('scripts/providers/_common.sh', '# common\n');
      write('scripts/providers/claude.sh', '# claude\n');
      final entry = write(
          'with_scripts.json',
          jsonEncode({
            'name': 'X',
            'params': {
              'cliCommands': ['./agents/scripts/run-agent.sh']
            },
          }));
      final names = zipNames(compileAgent(entry).zipFile);
      expect(names, contains('scripts/run-agent.sh'));
      expect(names, contains('scripts/providers/_common.sh'));
      expect(names, contains('scripts/providers/claude.sh'));
    });

    test('shell scripts carry 0755 mode in the manifest', () {
      write('scripts/run-agent.sh', '#!/bin/bash\necho hi\n');
      final entry = write(
          'mode_agent.json',
          jsonEncode({
            'name': 'X',
            'params': {
              'cliCommands': ['./agents/scripts/run-agent.sh']
            },
          }));
      final manifest =
          jsonDecode(compileAgent(entry).manifestFile.readAsStringSync())
              as Map<String, dynamic>;
      final files = manifest['files'] as List;
      final sh =
          files.firstWhere((f) => (f as Map)['path'] == 'scripts/run-agent.sh')
              as Map;
      expect(sh['mode'], '0755');
    });
  });
}

/// Path-duality normalization and parent-chain inclusion.
void prefixNormalizationTests() {
  group('AgentPackCompiler normalization', () {
    test('parent.path chain config is included in the pack', () {
      write('js/base.js', '// base\n');
      write(
          'base_config.json',
          jsonEncode({
            'name': 'Base',
            'params': {'jsPath': 'agents/js/base.js'},
          }));
      final entry = write(
          'child_config.json',
          jsonEncode({
            'name': 'Child',
            'parent': {
              'path': 'agents/base_config.json',
              'override': ['params.agentParams']
            },
            'params': <String, dynamic>{},
          }));
      final names = zipNames(compileAgent(entry).zipFile);
      expect(names, contains('base_config.json'));
      expect(names, contains('js/base.js'));
    });

    test('agents/ and plain prefixes both normalize', () {
      write('js/a.js', '// a\n');
      write('js/b.js', '// b\n');
      final entry = write(
          'dual.json',
          jsonEncode({
            'name': 'Dual',
            'params': {
              'preJSAction': 'agents/js/a.js',
              'postJSAction': 'js/b.js',
            },
          }));
      final names = zipNames(compileAgent(entry).zipFile);
      expect(names, contains('js/a.js'));
      expect(names, contains('js/b.js'));
      expect(names, isNot(contains('agents/js/a.js')));
    });

    test('AGENTS.md and LICENSE are included when present', () {
      final entry = writeSimpleAgent();
      write('AGENTS.md', '# Agents\n');
      write('LICENSE', 'Apache-2.0\n');
      final names = zipNames(compileAgent(entry).zipFile);
      expect(names, contains('AGENTS.md'));
      expect(names, contains('LICENSE'));
    });
  });
}

void conditionalCliPromptsTests() {
  group('AgentPackCompiler conditional cliPrompts', () {
    test(
        'structured conditional cliPrompts and cliPromptsByTracker embed prompt and condition JS with transitive requires',
        () {
      write('prompts/codegraph_tools.md', '# CodeGraph\n');
      write('prompts/jira_tools.md', '# Jira\n');
      write('js/common/cgHelper.js',
          'exports.check = function() { return true; };\n');
      write('js/conditions/isCodeGraphAvailable.js',
          "var h = require('../common/cgHelper.js');\nfunction action() { return h.check(); }\n");
      final entry = write(
          'cond_agent.json',
          jsonEncode({
            'name': 'CondAgent',
            'params': {
              'cliPrompts': [
                {
                  'id': 'codegraph',
                  'prompt': './agents/prompts/codegraph_tools.md',
                  'condition': 'agents/js/conditions/isCodeGraphAvailable.js',
                },
              ],
              'cliPromptsByTracker': {
                'jira': [
                  {
                    'id': 'jira_cg',
                    'prompts': ['./agents/prompts/jira_tools.md'],
                    'condition':
                        './agents/js/conditions/isCodeGraphAvailable.js',
                  },
                ],
              },
            },
          }));
      final names = zipNames(compileAgent(entry).zipFile);
      expect(names, contains('prompts/codegraph_tools.md'));
      expect(names, contains('prompts/jira_tools.md'));
      expect(names, contains('js/conditions/isCodeGraphAvailable.js'));
      expect(names, contains('js/common/cgHelper.js'));
    });
  });
}

void thenActionClosureTests() {
  group('AgentPackCompiler thenAction closure', () {
    test(
        'customParams.contentOutput.thenAction embeds bare JS script and transitive requires',
        () {
      write('js/common/assignHelper.js', 'exports.assign = function() {};\n');
      write('js/assignForSolutionArchitecture.js',
          "var a = require('./common/assignHelper.js');\nfunction action() { a.assign(); }\n");
      final entry = write(
          'story_ac.json',
          jsonEncode({
            'name': 'StoryAC',
            'params': {
              'customParams': {
                'contentOutput': {
                  'thenAction': 'assignForSolutionArchitecture.js',
                },
              },
            },
          }));
      final names = zipNames(compileAgent(entry).zipFile);
      expect(names, contains('js/assignForSolutionArchitecture.js'));
      expect(names, contains('js/common/assignHelper.js'));
    });
  });
}

/// `--include` whole-subtree embedding (zip flow): files that only
/// `pack:`-consuming child configs reference are embedded even when the
/// entry's computed closure does not reach them.
void extraDirsTests() {
  group('AgentPackCompiler extraDirs (--include)', () {
    test('embeds every file under the listed dir, referenced or not', () {
      final entry = writeSimpleAgent();
      write('instructions/pr_review/rules.md', '# rules\n');
      write('instructions/common/format.md', '# format\n');
      final names =
          zipNames(compileAgent(entry, extraDirs: ['instructions']).zipFile);
      expect(names, contains('instructions/pr_review/rules.md'));
      expect(names, contains('instructions/common/format.md'));
      expect(
        names,
        isNot(contains('agents/instructions/pr_review/rules.md')),
        reason: 'the agents/ prefix is stripped per the path duality',
      );
    });

    test('strips a leading agents/ prefix from the include dir', () {
      final entry = writeSimpleAgent();
      write('prompts/bash_tools.md', '# tools\n');
      final names =
          zipNames(compileAgent(entry, extraDirs: ['agents/prompts']).zipFile);
      expect(names, contains('prompts/bash_tools.md'));
    });

    test('missing include dir throws AgentPackException', () {
      final entry = writeSimpleAgent();
      expect(
        () => compileAgent(entry, extraDirs: ['nope']),
        throwsA(isA<AgentPackException>()),
      );
    });

    test('an include dir escaping the agents root is rejected', () {
      final entry = writeSimpleAgent();
      expect(
        () => compileAgent(entry, extraDirs: ['../outside']),
        throwsA(isA<AgentPackException>()),
      );
    });
  });
}

/// The comment-aware JS scanner (JSDoc/commented requires must not match).
void commentStripperTests() {
  group('stripJsComments', () {
    test('strips line and block comments, keeps strings', () {
      const src = '''
// line comment
var url = "https://example.com/a//b"; /* block */ var x = 1;
/* multi
   line */
var s = 'not // a comment';
''';
      final stripped = AgentPackCompiler.stripJsComments(src);
      expect(stripped, isNot(contains('line comment')));
      expect(stripped, isNot(contains('block')));
      expect(stripped, contains('https://example.com/a//b')); // string kept
      expect(stripped, contains('not // a comment'));
      expect(stripped, contains('var x = 1;'));
    });

    test('keeps escaped quotes inside strings', () {
      const src = 'var s = "a\\"// not a comment";';
      expect(AgentPackCompiler.stripJsComments(src), src);
    });
  });

  scrubForScanTests();
  scrubLexerTests();
  closureRegexTests();
}

/// gh-371: the scrub's regex-literal awareness — mirror fixtures of the
/// live dmtools-agents pullRequest.js desync.
void scrubForScanTests() {
  group('scrubForScan (gh-371: regex literals with quotes)', () {
    test('an escaped backtick in a regex no longer swallows later requires',
        () {
      // Mirror of dmtools-agents js/common/pullRequest.js:48 + :154 —
      // the live case that shipped pr_review packs without mergeState.js.
      const src = '''
function shellEscape(v) {
    return String(v === null || v === undefined ? '' : v)
        .replace(/"/g, '\\\\"')
        .replace(/[<>\\`\\|&;\$\\r\\n]/g, ' ')
        .trim();
}
var MAX = 60000;
var mergeState = require('./mergeState.js');
''';
      final scrubbed = AgentPackCompiler.scrubForScan(src);
      final re =
          RegExp(r'''(?:require|loadModule)\(\s*['"]([^'"]+)['"]\s*\)''');
      expect(re.allMatches(scrubbed).length, 1,
          reason: 'the require must survive the regex-literal region');
      expect(scrubbed.length, src.length, reason: 'length-preserving');
    });

    test('quotes inside regex literals do not open phantom strings', () {
      const src = '''
var a = /['"]/g;
var b = x.replace(/"/g, '');
var u = require('./util.js');
''';
      final scrubbed = AgentPackCompiler.scrubForScan(src);
      expect(scrubbed, contains('require('));
      expect(
        RegExp(r'''require\(\s*['"]''').hasMatch(scrubbed),
        isTrue,
        reason: "the require's opening quote must survive",
      );
    });
  });
}

/// gh-371 continued: lexer-context behaviors of the scrub.
void scrubLexerTests() {
  group('scrubForScan lexer context (gh-371)', () {
    test('division is not mistaken for a regex literal', () {
      const src = '''
var half = total / 2 / parts;
var u = require('./util.js');
''';
      final scrubbed = AgentPackCompiler.scrubForScan(src);
      expect(scrubbed, contains('total'));
      expect(scrubbed, contains('/ 2 /'));
    });

    test('nested template interpolations do not desync the scan', () {
      const src = '''
var msg = `outer \${cond ? `in\${deep}er` : 'plain'} tail`;
var u = require('./util.js');
''';
      final scrubbed = AgentPackCompiler.scrubForScan(src);
      final re =
          RegExp(r'''(?:require|loadModule)\(\s*['"]([^'"]+)['"]\s*\)''');
      expect(re.allMatches(scrubbed).length, 1);
    });

    test('requires inside strings and comments stay masked out', () {
      const src = '''
var s = "require('./never.js')";
// require('./commented.js')
var u = require('./real.js');
''';
      final scrubbed = AgentPackCompiler.scrubForScan(src);
      final re =
          RegExp(r'''(?:require|loadModule)\(\s*['"]([^'"]+)['"]\s*\)''');
      final matches = re.allMatches(scrubbed).toList();
      expect(matches.length, 1);
      expect(src.substring(matches[0].start, matches[0].end),
          contains('./real.js'));
    });
  });
}

void closureRegexTests() {
  group('closure across quote-bearing regexes (gh-371)', () {
    test('compile embeds modules required past a regex literal', () {
      write('js/common/mergeState.js', 'exports.ok = true;\n');
      write('js/common/pullRequest.js', '''
function esc(v) {
    return String(v)
        .replace(/[<>\\`\\|&;\$\\r\\n]/g, ' ')
        .trim();
}
var ms = require('./mergeState.js');
function action(params) { return ms.ok; }
''');
      write('js/main.js', "var pr = require('./common/pullRequest.js');\n");
      final entry = write(
          'my_agent.json',
          jsonEncode({
            'name': 'Teammate',
            'params': {'jsPath': 'agents/js/main.js'},
          }));

      final result = AgentPackCompiler(agentRoot.path)
          .compile(entry, '0.1.0', 'deadbeef', outDir);
      final names = zipNames(result.zipFile);
      expect(names, contains('js/common/mergeState.js'));
      expect(names, contains('js/common/pullRequest.js'));
    });
  });
}
