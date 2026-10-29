/// Unit tests for [RunCommandProcessor] (Java `RunCommandProcessor` port).
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dmtools/dmtools.dart';
import 'package:dmtools/src/compile/agent_pack_compiler.dart'
    hide AgentPackException;
import 'package:dmtools/src/pack/agent_pack_resolver.dart';
import 'package:test/test.dart';

import '../pack/pack_fixtures.dart';

late Directory _tmp;

void main() {
  setUp(() {
    _tmp = Directory.systemTemp.createTempSync('dmtools_rcp_');
  });

  tearDown(() {
    if (_tmp.existsSync()) _tmp.deleteSync(recursive: true);
  });

  _testJobNameMode();
  _testJobNameOverrides();
  _testJsFileMode();
  _testConfigFileResolution();
  _testPackTokenWiring();
}

File _writeFile(String name, String content) {
  final f = File('${_tmp.path}/$name');
  f.writeAsStringSync(content);
  return f;
}

String _run(List<String> args) => const RunCommandProcessor().process(args);

void _testJobNameMode() {
  group('job-name mode', () {
    test('builds minimal config for a known job', () {
      final json = jsonDecode(_run(['run', 'codegenerator'])) as Map;
      expect(json['name'], 'codegenerator');
      expect(json['params'], {});
    });

    test('injects CLI overrides into params', () {
      final json =
          jsonDecode(_run(['run', 'teammate', '--model', 'gpt-4'])) as Map;
      expect(json['params']['model'], 'gpt-4');
    });

    test('parses JSON-array override values', () {
      final json =
          jsonDecode(_run(['run', 'teammate', '--list', '[1,2]'])) as Map;
      expect(json['params']['list'], [1, 2]);
    });

    test('parses JSON-object override values', () {
      final json =
          jsonDecode(_run(['run', 'teammate', '--obj', '{"a":"b"}'])) as Map;
      expect(json['params']['obj'], {'a': 'b'});
    });

    test('keeps non-JSON bracket values as strings', () {
      final json = jsonDecode(
        _run([
          'run',
          'teammate',
          '--inputJql',
          '[System.Id] = 1839749',
        ]),
      ) as Map;
      expect(json['params']['inputJql'], '[System.Id] = 1839749');
    });

    test('keeps values with trailing text after a valid JSON prefix', () {
      final json = jsonDecode(
        _run([
          'run',
          'teammate',
          '--a',
          '["a"] trailing',
          '--b',
          '{"a":1} and more',
        ]),
      ) as Map;
      expect(json['params']['a'], '["a"] trailing');
      expect(json['params']['b'], '{"a":1} and more');
    });
  });
}

void _testJobNameOverrides() {
  group('job-name override parsing', () {
    test('still parses valid arrays, objects and empty containers', () {
      final json = jsonDecode(
        _run([
          'run',
          'teammate',
          '--cmd',
          '["cursor-agent","x"]',
          '--obj',
          '{"a": 1}',
          '--empty',
          '[]',
        ]),
      ) as Map;
      expect(json['params']['cmd'], ['cursor-agent', 'x']);
      expect(json['params']['obj'], {'a': 1});
      expect(json['params']['empty'], []);
    });

    test('applies base64-encoded override config', () {
      final encoded = base64.encode(utf8.encode('{"params":{"k":"v"}}'));
      final json = jsonDecode(_run(['run', 'codegenerator', encoded])) as Map;
      expect(json['params']['k'], 'v');
    });
  });
}

void _testJsFileMode() {
  group('.js file mode', () {
    test('builds JSRunner config', () {
      final json = jsonDecode(_run(['run', 'script.js'])) as Map;
      expect(json['name'], 'JSRunner');
      expect(json['params']['jsPath'], 'script.js');
      expect(json['params']['jobParams'], {});
    });

    test('injects overrides into jobParams', () {
      final json =
          jsonDecode(_run(['run', 'script.js', '--key', 'val'])) as Map;
      expect(json['params']['jobParams']['key'], 'val');
    });

    test('injects JSON-array override into jobParams', () {
      final json =
          jsonDecode(_run(['run', 'script.js', '--items', '[1,2,3]'])) as Map;
      expect(json['params']['jobParams']['items'], [1, 2, 3]);
    });

    test('applies base64-encoded config', () {
      final encoded = base64.encode(
        utf8.encode('{"params":{"jobParams":{"extra":"data"}}}'),
      );
      final json = jsonDecode(_run(['run', 'script.js', encoded])) as Map;
      expect(json['params']['jobParams']['extra'], 'data');
    });
  });
}

void _testConfigFileResolution() {
  group('config file resolution', () {
    test('loads a simple JSON config file', () {
      _writeFile('job.json', '{"name":"myjob","params":{"k":"v"}}');
      final json = jsonDecode(_run(['run', '${_tmp.path}/job.json'])) as Map;
      expect(json['name'], 'myjob');
      expect(json['params']['k'], 'v');
    });

    test('throws ArgumentError for a missing file', () {
      expect(
        () => _run(['run', '${_tmp.path}/nope.json']),
        throwsArgumentError,
      );
    });

    test('injects CLI overrides on top of file config', () {
      _writeFile('job.json', '{"name":"job","params":{"a":"1"}}');
      final json =
          jsonDecode(_run(['run', '${_tmp.path}/job.json', '--b', '2'])) as Map;
      expect(json['params']['a'], '1');
      expect(json['params']['b'], '2');
    });
  });

  _testParentResolution();
  _testParentStructuredCliPromptsMerge();
  _testParentStructuredCliPromptsStrategies();
  _testParentPackResolution();
  _testParentPackRegistryRef();
  _testParentPackEntryOverride();
  _testChildPackRefs();
  _testChildPackRefErrors();
  _testRegistryRefGuard();
}

void _testParentResolution() {
  group('parent-config resolution', () {
    test('deep-merges parent into child', () {
      _writeFile('parent.json', '{"params":{"k1":"p1","k2":"p2"}}');
      _writeFile('child.json', '''{
        "name":"child",
        "parent":{"path":"parent.json"},
        "params":{"k2":"c2"}
      }''');
      final json = jsonDecode(_run(['run', '${_tmp.path}/child.json'])) as Map;
      expect(json['name'], 'child');
      expect(json['params']['k1'], 'p1');
      expect(json['params']['k2'], 'c2');
    });

    test('concatenates arrays via merge directive', () {
      _writeFile('parent.json', '{"items":["a","b"]}');
      _writeFile('child.json', '''{
        "name":"child",
        "parent":{"path":"parent.json"},
        "merge":["items"],
        "items":["c"]
      }''');
      final json = jsonDecode(_run(['run', '${_tmp.path}/child.json'])) as Map;
      expect(json['items'], ['a', 'b', 'c']);
    });

    test('applies override directive', () {
      _writeFile('parent.json', '{"params":{"k":"parent"}}');
      _writeFile('child.json', '''{
        "name":"child",
        "parent":{"path":"parent.json"},
        "override":["params.k"],
        "params":{"k":"child"}
      }''');
      final json = jsonDecode(_run(['run', '${_tmp.path}/child.json'])) as Map;
      expect(json['params']['k'], 'child');
    });

    test('handles parent block with non-string path', () {
      _writeFile('child.json', '''{
        "name":"child",
        "parent":{"path":123}
      }''');
      final json = jsonDecode(_run(['run', '${_tmp.path}/child.json'])) as Map;
      expect(json['name'], 'child');
      expect(json.containsKey('parent'), isFalse);
    });

    test('handles non-map parent block', () {
      _writeFile('child.json', '{"name":"child","parent":"string"}');
      final json = jsonDecode(_run(['run', '${_tmp.path}/child.json'])) as Map;
      expect(json['name'], 'child');
      expect(json.containsKey('parent'), isFalse);
    });
  });
}

void _testParentStructuredCliPromptsMerge() {
  group('parent-config structured cliPrompts merge', () {
    test('merges structured cliPrompts section objects with matching id', () {
      _writeFile(
          'parent.json',
          jsonEncode({
            'params': {
              'cliPrompts': [
                'base1',
                {
                  'id': 'codegraph',
                  'prompt': 'cg1.md',
                  'condition': 'agents/js/conditions/isCodeGraphAvailable.js',
                },
                'base2',
              ],
            },
          }));
      _writeFile(
          'child.json',
          jsonEncode({
            'name': 'child',
            'parent': {'path': 'parent.json'},
            // Omit 'merge' to also exercise implicit _applyStructuredCliPromptsMerge
            'params': {
              'cliPrompts': [
                {'id': 'codegraph', 'prompt': 'cg2.md'},
                'child1',
              ],
            },
          }));
      final json = jsonDecode(_run(['run', '${_tmp.path}/child.json'])) as Map;
      final cliPrompts = json['params']['cliPrompts'] as List;
      expect(cliPrompts.length, 4);
      expect(cliPrompts[0], 'base1');
      expect(cliPrompts[1], {
        'id': 'codegraph',
        'prompts': ['cg1.md', 'cg2.md'],
        'condition': 'agents/js/conditions/isCodeGraphAvailable.js',
      });
      expect(cliPrompts[2], 'base2');
      expect(cliPrompts[3], 'child1');
    });
  });
}

void _testParentStructuredCliPromptsStrategies() {
  group('parent-config structured cliPrompts strategies', () {
    test('supports prepend and replace mergeStrategy', () {
      _writeFile(
        'parent.json',
        '{"params":{"cliPrompts":['
            '{"id":"s1","prompts":["p1"],"mergeStrategy":"prepend"},'
            '{"id":"s2","prompts":["p2"]}]}}',
      );
      _writeFile(
        'child.json',
        '{"name":"child","parent":{"path":"parent.json"},'
            '"merge":["params.cliPrompts"],"params":{"cliPrompts":['
            '{"id":"s1","prompt":"c1","mergeStrategy":"prepend","condition":"cond.js"},'
            '{"id":"s2","prompt":"c2","mergeStrategy":"replace"},'
            '{"id":"s3","prompt":"c3"}]}}',
      );
      final json = jsonDecode(_run(['run', '${_tmp.path}/child.json'])) as Map;
      expect(json['params']['cliPrompts'], [
        {
          'id': 's1',
          'prompts': ['c1', 'p1'],
          'mergeStrategy': 'prepend',
          'condition': 'cond.js',
        },
        {
          'id': 's2',
          'prompts': ['c2'],
        },
        {'id': 's3', 'prompt': 'c3'},
      ]);
    });

    test('concatenates plain cliPrompts via merge directive', () {
      _writeFile('parent.json', '{"params":{"cliPrompts":["p1"]}}');
      _writeFile(
        'child.json',
        '{"name":"child","parent":{"path":"parent.json"},'
            '"merge":["params.cliPrompts"],"params":{"cliPrompts":["c1"]}}',
      );
      final json = jsonDecode(_run(['run', '${_tmp.path}/child.json'])) as Map;
      expect(json['params']['cliPrompts'], ['p1', 'c1']);
    });
  });
}

/// Test seam: records the token passed to [AgentPackResolver.resolve] and
/// stops the pack path before any download/unpack happens.
class _RecordingPackResolver extends AgentPackResolver {
  String? capturedToken;

  @override
  bool isPack(String? runArg) => true;

  @override
  ResolvedPack resolve(String runArg, {String? githubToken}) {
    capturedToken = githubToken;
    throw const AgentPackException('recording seam');
  }
}

/// SOURCE_GITHUB_TOKEN wiring into the pack resolver (PR #249 review: the
/// token was never passed to `resolve()`).
void _testPackTokenWiring() {
  group('agent-pack token wiring', () {
    test('passes SOURCE_GITHUB_TOKEN to the pack resolver', () {
      final resolver = _RecordingPackResolver();
      PropertyReader.setOverrides({'SOURCE_GITHUB_TOKEN': 'test-token-123'});
      try {
        expect(
          () => RunCommandProcessor(
            packResolver: resolver,
          ).process(['run', 'pack.zip']),
          throwsA(isA<AgentPackException>()),
        );
        expect(resolver.capturedToken, 'test-token-123');
      } finally {
        PropertyReader.clearOverrides();
      }
    });

    test('passes no usable token when SOURCE_GITHUB_TOKEN is empty', () {
      final resolver = _RecordingPackResolver();
      // An empty override is accepted as-is (Java parity) and must not leak
      // a developer's real env token into the resolver.
      PropertyReader.setOverrides({'SOURCE_GITHUB_TOKEN': ''});
      try {
        expect(
          () => RunCommandProcessor(
            packResolver: resolver,
          ).process(['run', 'pack.zip']),
          throwsA(isA<AgentPackException>()),
        );
        expect(resolver.capturedToken, isNot('test-token-123'));
      } finally {
        PropertyReader.clearOverrides();
      }
    });
  });
}

/// `parent.path` pointing at an agent pack (local .zip / URL / registry ref):
/// the parent is unpacked, its own chain resolved inside the pack, and its
/// pack-relative paths rewritten to absolute cache paths before the merge.
void _testParentPackResolution() {
  group('parent-config from agent pack', () {
    test('local pack zip parent merges and rewrites paths to the cache', () {
      final zip = _buildParentPack();
      final packsRoot = Directory('${_tmp.path}/packs');
      final resolver = AgentPackResolver(packsRoot: packsRoot);
      _writeFile('child.json', '''{
        "name":"child",
        "parent":{"path":"${zip.path.replaceAll('\\', '/')}"},
        "params":{"fromChild":"yes"}
      }''');
      final json = jsonDecode(
        RunCommandProcessor(
          packResolver: resolver,
        ).process(['run', '${_tmp.path}/child.json']),
      ) as Map;
      expect(json['params']['fromParent'], 'yes');
      expect(json['params']['fromChild'], 'yes');
      final jsPath = json['params']['jsPath'] as String;
      expect(
        jsPath.startsWith(packsRoot.path),
        isTrue,
        reason: 'parent jsPath is rewritten into the pack cache: $jsPath',
      );
      expect(File(jsPath).existsSync(), isTrue);
    });

    test('non-pack parent paths still resolve from the filesystem', () {
      _writeFile('parent.json', '{"params":{"k":"p"}}');
      _writeFile(
        'child.json',
        '{"name":"child","parent":{"path":"parent.json"}}',
      );
      final json = jsonDecode(_run(['run', '${_tmp.path}/child.json'])) as Map;
      expect(json['params']['k'], 'p');
    });
  });
}

/// Registry-ref parent (`<agent>@latest`) — split out of
/// [_testParentPackResolution] for the loc gate.
void _testParentPackRegistryRef() {
  group('parent-config from agent pack (registry ref)', () {
    test('registry-ref parent (<agent>@latest) resolves and merges', () async {
      final zip = _buildParentPack();
      final zipBytes = zip.readAsBytesSync();
      final server = await startRegistryServer({
        '/parent_agent-1.0.0.zip': zipBytes,
        '/parent_agent-1.0.0.zip.sha256': utf8.encode(
          '${sha256.convert(zipBytes)}  parent_agent-1.0.0.zip',
        ),
        '/catalog.json': utf8.encode(jsonEncode({'parent_agent': '1.0.0'})),
      });
      try {
        final packsRoot = Directory('${_tmp.path}/packs');
        final resolver = AgentPackResolver(
          packsRoot: packsRoot,
          registryBaseUrl: 'http://127.0.0.1:${server.port}',
        );
        _writeFile('child.json', '''{
          "name":"child",
          "parent":{"path":"parent_agent@latest"},
          "params":{"fromChild":"yes"}
        }''');
        final json = jsonDecode(
          RunCommandProcessor(
            packResolver: resolver,
          ).process(['run', '${_tmp.path}/child.json']),
        ) as Map;
        expect(json['params']['fromParent'], 'yes');
        expect(json['params']['fromChild'], 'yes');
        final jsPath = json['params']['jsPath'] as String;
        expect(
          jsPath.startsWith(packsRoot.path),
          isTrue,
          reason: 'registry parent jsPath is rewritten into the pack cache',
        );
        expect(File(jsPath).existsSync(), isTrue);
      } finally {
        server.isolate.kill();
      }
    });
  });
}

/// Pack parent with a `#entry` override — split out of
/// [_testParentPackResolution] for the loc gate.
void _testParentPackEntryOverride() {
  group('parent-config from agent pack (entry override)', () {
    test('pack parent with #entry override uses the overridden entry', () {
      final zip = _buildParentPack(withAltEntry: true);
      final packsRoot = Directory('${_tmp.path}/packs');
      final resolver = AgentPackResolver(packsRoot: packsRoot);
      _writeFile('child.json', '''{
        "name":"child",
        "parent":{"path":"${zip.path.replaceAll('\\', '/')}#alt.json"}
      }''');
      final json = jsonDecode(
        RunCommandProcessor(
          packResolver: resolver,
        ).process(['run', '${_tmp.path}/child.json']),
      ) as Map;
      expect(json['params']['altEntry'], 'yes');
      expect(
        json['params']['fromParent'],
        isNull,
        reason: 'the default entry config is not loaded',
      );
    });
  });
}

/// Child-side `pack:` references against a pack parent — the zip flow where
/// no agents checkout is mounted: instructions/js resolve into the unpacked
/// pack cache. Split out for the loc gate.
void _testChildPackRefs() {
  group('child pack: refs against a pack parent', () {
    test(
        'pack: strings and repo-relative paths in child and encoded config rewrite into the pack cache',
        () {
      final zip = _buildPackWithInstructions();
      final packsRoot = Directory('${_tmp.path}/packs');
      final resolver = AgentPackResolver(packsRoot: packsRoot);
      _writeFile('child.json', '''{
        "name":"child",
        "parent":{"path":"${zip.path.replaceAll('\\', '/')}"},
        "override":["params.cliPrompts"],
        "params":{
          "cliPrompts":[
            "pack:instructions/review_rules.md",
            "literal prompt",
            {"id":"cg","prompt":"agents/instructions/review_rules.md","condition":"agents/js/helper.js"}
          ],
          "customParams":{"rulesFile":"pack:/instructions/review_rules.md"}
        }
      }''');
      final encoded = base64.encode(utf8.encode(jsonEncode({
        'params': {'postJSAction': 'agents/js/helper.js'}
      })));
      final json = jsonDecode(
        RunCommandProcessor(
          packResolver: resolver,
        ).process(['run', '${_tmp.path}/child.json', encoded]),
      ) as Map;
      final prompts = json['params']['cliPrompts'] as List;
      expect(prompts[1], 'literal prompt');
      expect(prompts[0], startsWith(packsRoot.path));
      expect(File(prompts[0] as String).existsSync(), isTrue);
      final cgSection = prompts[2] as Map;
      expect(cgSection['prompt'], prompts[0]);
      expect(File(cgSection['condition'] as String).existsSync(), isTrue);
      expect(json['params']['postJSAction'], cgSection['condition']);
      final rules = json['params']['customParams']['rulesFile'] as String;
      expect(rules, prompts[0], reason: 'pack:/ with a slash normalizes too');
    });
  });
}

/// Error paths for child-side `pack:` refs and registry-ref parents.
void _testChildPackRefErrors() {
  group('child pack: refs against a pack parent (errors)', () {
    test('pack: ref escaping the pack root is rejected', () {
      final zip = _buildPackWithInstructions();
      final resolver = AgentPackResolver(
        packsRoot: Directory('${_tmp.path}/packs'),
      );
      _writeFile('child.json', '''{
        "name":"child",
        "parent":{"path":"${zip.path.replaceAll('\\', '/')}"},
        "params":{"cliPrompts":["pack:../outside.md"]}
      }''');
      expect(
        () => RunCommandProcessor(
          packResolver: resolver,
        ).process(['run', '${_tmp.path}/child.json']),
        throwsA(isA<AgentPackException>()),
      );
      expect(File('${_tmp.path}/outside.md').existsSync(), isFalse);
    });

    test('pack: ref missing inside the pack throws AgentPackException', () {
      final zip = _buildPackWithInstructions();
      final resolver = AgentPackResolver(
        packsRoot: Directory('${_tmp.path}/packs'),
      );
      _writeFile('child.json', '''{
        "name":"child",
        "parent":{"path":"${zip.path.replaceAll('\\', '/')}"},
        "params":{"cliPrompts":["pack:instructions/nope.md"]}
      }''');
      expect(
        () => RunCommandProcessor(
          packResolver: resolver,
        ).process(['run', '${_tmp.path}/child.json']),
        throwsA(isA<AgentPackException>()),
      );
    });

    test('pack: refs with a non-pack filesystem parent are rejected', () {
      _writeFile('parent.json', '{"params":{"k":"p"}}');
      _writeFile('child.json', '''{
        "name":"child",
        "parent":{"path":"parent.json"},
        "params":{"cliPrompts":["pack:instructions/review_rules.md"]}
      }''');
      expect(
        () => _run(['run', '${_tmp.path}/child.json']),
        throwsArgumentError,
      );
    });
  });
}

/// Registry-ref parents: the `<agent>@<version|latest>` shape with no
/// registry configured must error clearly instead of a bare file-not-found.
void _testRegistryRefGuard() {
  group('registry ref parents (errors)', () {
    test(
      '<agent>@latest parent without a configured registry errors clearly',
      () {
        final resolver = AgentPackResolver(
          packsRoot: Directory('${_tmp.path}/packs'),
          registryBaseUrl: '', // hermetic: no registry
        );
        _writeFile('child.json', '''{
        "name":"child",
        "parent":{"path":"pr_review@latest"},
        "params":{}
      }''');
        expect(
          () => RunCommandProcessor(
            packResolver: resolver,
          ).process(['run', '${_tmp.path}/child.json']),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.toString(),
              'toString',
              allOf(
                contains('pr_review@latest'),
                contains('DMTOOLS_PACK_REGISTRY'),
              ),
            ),
          ),
        );
      },
    );
  });
}

/// Builds a real pack zip containing `instructions/review_rules.md` plus the
/// standard parent-pack fixture content. The entry references the
/// instructions file (via the `agents/` path duality) so the compiler's
/// closure embeds it in the zip.
File _buildPackWithInstructions() {
  final agentRoot = Directory('${_tmp.path}/parent_agent_root')
    ..createSync(recursive: true);
  File('${agentRoot.path}/js/helper.js')
    ..createSync(recursive: true)
    ..writeAsStringSync('// helper\n');
  File('${agentRoot.path}/instructions/review_rules.md')
    ..createSync(recursive: true)
    ..writeAsStringSync('# review rules\n');
  final entry = File('${agentRoot.path}/parent_agent.json')
    ..writeAsStringSync(
      jsonEncode({
        'name': 'ParentAgent',
        'params': {
          'jsPath': 'agents/js/helper.js',
          'fromParent': 'yes',
          'cliPrompts': ['agents/instructions/review_rules.md'],
        },
      }),
    );
  final dist = Directory('${_tmp.path}/parent_dist')
    ..createSync(recursive: true);
  return AgentPackCompiler(
    agentRoot.path,
  ).compile(entry, '1.0.0', 'deadbeef', dist).zipFile;
}

/// Builds a real parent pack zip with `js/helper.js` and an entry config.
File _buildParentPack({bool withAltEntry = false}) {
  final agentRoot = Directory('${_tmp.path}/parent_agent_root')
    ..createSync(recursive: true);
  File('${agentRoot.path}/js/helper.js')
    ..createSync(recursive: true)
    ..writeAsStringSync('// helper\n');
  final params = <String, dynamic>{
    'jsPath': 'agents/js/helper.js',
    'fromParent': 'yes',
  };
  final entryMap = <String, dynamic>{
    'name': 'ParentAgent',
    if (withAltEntry)
      // Referencing alt.json via parent pulls it into the pack closure, so
      // the `#alt.json` entry override has a file to load.
      'parent': {'path': 'agents/alt.json'},
    'params': params,
  };
  final entry = File('${agentRoot.path}/parent_agent.json')
    ..writeAsStringSync(jsonEncode(entryMap));
  if (withAltEntry) {
    File('${agentRoot.path}/alt.json').writeAsStringSync(
      jsonEncode({
        'name': 'ParentAgent',
        'params': {'altEntry': 'yes'},
      }),
    );
  }
  final dist = Directory('${_tmp.path}/parent_dist')
    ..createSync(recursive: true);
  return AgentPackCompiler(
    agentRoot.path,
  ).compile(entry, '1.0.0', 'deadbeef', dist).zipFile;
}
