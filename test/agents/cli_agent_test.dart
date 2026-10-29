/// Tests for the Phase 5 CliAgent port — parameter parsing, command builder,
/// execution helper, lifecycle order, cleanup, and factory dispatch.
library;

import 'dart:io';

import 'package:dmtools/dmtools.dart';
import 'package:test/test.dart';

void main() {
  paramsParsingTests();
  paramsContextIdTests();
  paramsCliPromptsTests();
  resolveCliPromptsTests();
  buildCommandsTests();
  filterEnvTests();
  executeCommandsTests();
  readOutputResponseTests();
  lifecycleOrderTests();
  lifecycleInputCleanupTests();
  lifecycleFolderCleanupTests();
  lifecycleContextTests();
  lifecycleEnvTests();
  lifecycleTicketDataTests();
  ticketHydrationTests();
  ticketCompositeHydrationTests();
  ticketTimerHydrationTests();
  ticketHydrationEdgeTests();
  ticketHydrationPrecedenceTests();
  factoryTests();
}

// ======================================================================
// CliAgentParams — parsing
// ======================================================================

void paramsParsingTests() {
  group('CliAgentParams.fromJson', () {
    test('parses all fields from JSON', () {
      final params = CliAgentParams.fromJson({
        'cliCommands': ['echo hello', 'echo world'],
        'cliPrompt': 'Do the thing',
        'setup': 'make setup',
        'cache': 'make cache',
        'reset': 'make reset',
        'preCliJSAction': 'pre.js',
        'cleanupInputFolder': false,
        'requireCliOutputFile': true,
        'workingDirectory': '/tmp/work',
        'timerIntervalSeconds': 30,
        'cleanupOutputsFolder': true,
        'envVariables': {'KEY': 'value'},
        'metadata': {'contextId': 'my-job'},
      });
      expect(params.cliCommands, ['echo hello', 'echo world']);
      expect(params.cliPrompt, 'Do the thing');
      expect(params.cleanupInputFolder, isFalse);
      expect(params.timerIntervalSeconds, 30);
      expect(params.envVariables, {'KEY': 'value'});
    });

    test('applies correct defaults', () {
      final params = CliAgentParams.fromJson({
        'cliCommands': ['echo']
      });
      expect(params.cleanupInputFolder, isTrue);
      expect(params.requireCliOutputFile, isFalse);
      expect(params.cleanupOutputsFolder, isFalse);
      expect(params.timerIntervalSeconds, 60);
    });

    test('parses excludedEnvVariables and regex', () {
      final params = CliAgentParams.fromJson({
        'excludedEnvVariables': ['SECRET', 'TOKEN'],
        'excludeEnvVariablesByRegex': ['^_.*'],
      });
      expect(params.excludedEnvVariables, ['SECRET', 'TOKEN']);
      expect(params.excludeEnvVariablesByRegex, ['^_.*']);
    });

    test('parses cliPromptsByTracker', () {
      final params = CliAgentParams.fromJson({
        'cliPromptsByTracker': {
          'jira': ['j1', 'j2'],
          'ado': ['a1'],
        },
      });
      expect(params.cliPromptsByTracker?['jira'], ['j1', 'j2']);
      expect(params.cliPromptsByTracker?['ado'], ['a1']);
    });
  });
}

void paramsContextIdTests() {
  group('CliAgentParams.contextId', () {
    test('reads contextId from metadata', () {
      expect(
        CliAgentParams.fromJson({
          'metadata': {'contextId': 'job-1'}
        }).contextId,
        'job-1',
      );
    });

    test('falls back to cli-agent', () {
      expect(CliAgentParams.fromJson({}).contextId, 'cli-agent');
      expect(CliAgentParams.fromJson({'metadata': {}}).contextId, 'cli-agent');
    });
  });
}

void paramsCliPromptsTests() {
  group('CliAgentParams.cliPromptsAsArray', () {
    test('flattens structured config', () {
      final params = CliAgentParams.fromJson({
        'cliPrompts': [
          'plain',
          {
            'id': 's1',
            'prompts': ['a', 'b']
          },
        ],
      });
      expect(params.cliPromptsAsArray, ['plain', 'a', 'b']);
    });

    test('handles flat string array', () {
      final params = CliAgentParams.fromJson({
        'cliPrompts': ['x', 'y']
      });
      expect(params.cliPromptsAsArray, ['x', 'y']);
    });

    test('returns null when absent', () {
      expect(CliAgentParams.fromJson({}).cliPromptsAsArray, isNull);
    });
  });
}

// ======================================================================
// CliCommandBuilder
// ======================================================================

void resolveCliPromptsTests() {
  group('CliCommandBuilder.resolveCliPrompts', () {
    test('merges base with matching tracker prompts', () {
      expect(
        CliCommandBuilder.resolveCliPrompts(
          ['base1'],
          {
            'jira': ['j1', 'j2']
          },
          'jira',
        ),
        ['base1', 'j1', 'j2'],
      );
    });

    test('returns base when tracker not found', () {
      expect(
        CliCommandBuilder.resolveCliPrompts([
          'b'
        ], {
          'jira': ['j']
        }, 'ado'),
        ['b'],
      );
    });

    test('defaults to ado when tracker is null', () {
      expect(
        CliCommandBuilder.resolveCliPrompts([
          'b'
        ], {
          'ado': ['a']
        }, null),
        ['b', 'a'],
      );
    });

    test('selects the github tracker prompts (gh-125)', () {
      expect(
        CliCommandBuilder.resolveCliPrompts(
          ['base'],
          {
            'github': ['github-rule-1', 'github-rule-2'],
            'ado': ['ado-rule'],
          },
          'github',
        ),
        ['base', 'github-rule-1', 'github-rule-2'],
      );
    });
  });
}

void buildCommandsTests() {
  group('CliCommandBuilder.buildCommands', () {
    test('returns original commands when no prompt', () {
      final result = const CliCommandBuilder().buildCommands(
        ['echo hello'],
        null,
        null,
        null,
      );
      expect(result, ['echo hello']);
    });

    test('appends prompt file path when prompt provided', () {
      final result = const CliCommandBuilder().buildCommands(
        ['echo a', 'echo b'],
        'Do X',
        null,
        null,
      );
      expect(result, hasLength(2));
      expect(result[0], startsWith('echo a "'));
      expect(result[0], endsWith('.txt"'));
    });

    test('returns original when cliCommands empty', () {
      expect(const CliCommandBuilder().buildCommands([], 'p', null, null), []);
    });

    test('enriches file-path references via InstructionProcessor', () {
      final tmp = Directory.systemTemp.createTempSync('ip_cmd_test_');
      try {
        File('${tmp.path}/ref.md').writeAsStringSync('embedded-content');
        final result = const CliCommandBuilder().buildCommands(
          ['echo'],
          'See ./ref.md',
          null,
          null,
          workingDirectory: tmp.path,
        );
        final match = RegExp(r'"(.+)"').firstMatch(result.first);
        expect(File(match!.group(1)!).readAsStringSync(),
            contains('embedded-content'));
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });
  });
}

// ======================================================================
// CliExecutionHelper
// ======================================================================

void filterEnvTests() {
  group('CliExecutionHelper.filterEnvVariables', () {
    test('removes exact-name exclusions', () {
      final f = CliExecutionHelper.filterEnvVariables(
        {'A': '1', 'B': '2', 'S': 'x'},
        ['S'],
        null,
      );
      expect(f.containsKey('S'), isFalse);
      expect(f['A'], '1');
    });

    test('removes regex-matched keys', () {
      final f = CliExecutionHelper.filterEnvVariables(
        {'_X': '1', 'P': '2'},
        null,
        ['^_.*'],
      );
      expect(f.containsKey('_X'), isFalse);
      expect(f['P'], '2');
    });

    test('returns original when no filters', () {
      final orig = {'A': '1'};
      expect(
        CliExecutionHelper.filterEnvVariables(orig, null, null),
        same(orig),
      );
    });
  });
}

void executeCommandsTests() {
  group('CliExecutionHelper.executeCommands', () {
    test('captures successful output', () async {
      final r = await const CliExecutionHelper().executeCommands(
        ['echo hello_world'],
      );
      expect(r.commandResponses, contains('hello_world'));
      expect(r.hasFatalError, isFalse);
    });

    test('tracks fatal error on failure', () async {
      final r = await const CliExecutionHelper().executeCommands(['exit 42']);
      expect(r.hasFatalError, isTrue);
      expect(r.lastExitCode, 42);
    });
  });
}

void readOutputResponseTests() {
  group('CliExecutionHelper.readOutputResponse', () {
    test('prefers outputs/ when outputsFirst', () async {
      final tmp = await _createTempDir();
      try {
        await _writeResponse(tmp.path, 'outputs', 'from-outputs');
        await _writeResponse(tmp.path, 'output', 'from-legacy');
        final r = const CliExecutionHelper().readOutputResponse(
          tmp.path,
          OutputFolderPreference.outputsFirst,
        );
        expect(r, 'from-outputs');
      } finally {
        await tmp.delete(recursive: true);
      }
    });

    test('falls back to legacy folder', () async {
      final tmp = await _createTempDir();
      try {
        await _writeResponse(tmp.path, 'output', 'from-legacy');
        final r = const CliExecutionHelper().readOutputResponse(
          tmp.path,
          OutputFolderPreference.outputsFirst,
        );
        expect(r, 'from-legacy');
      } finally {
        await tmp.delete(recursive: true);
      }
    });

    test('returns null when neither exists', () {
      expect(
        const CliExecutionHelper().readOutputResponse(
          '/nonexistent',
          OutputFolderPreference.outputsFirst,
        ),
        isNull,
      );
    });
  });
}

// ======================================================================
// CliAgent lifecycle
// ======================================================================

void lifecycleOrderTests() {
  group('CliAgent lifecycle order', () {
    test('executes setup → cliCommands → cache → reset', () async {
      final tmp = await _createTempDir();
      final log = '${tmp.path}/order.log';
      try {
        final agent = CliAgent(
          params: CliAgentParams()
            ..cliCommands = ['echo cli >> "$log"']
            ..setup = 'echo setup >> "$log"'
            ..cache = 'echo cache >> "$log"'
            ..reset = 'echo reset >> "$log"'
            ..cleanupInputFolder = false,
          workingDirectory: tmp.path,
        );
        final result = await agent.run();
        expect(result['success'], isTrue);
        final lines = (await File(log).readAsString()).trim().split('\n');
        expect(lines, ['setup', 'cli', 'cache', 'reset']);
      } finally {
        await tmp.delete(recursive: true);
      }
    });

    test('reset runs even on failure', () async {
      final tmp = await _createTempDir();
      final log = '${tmp.path}/fail.log';
      try {
        await File('${tmp.path}/input/cli-agent').create(recursive: true);
        final agent = CliAgent(
          params: CliAgentParams()
            ..cliCommands = ['echo cli >> "$log"']
            ..reset = 'echo reset >> "$log"'
            ..cleanupInputFolder = false,
          workingDirectory: tmp.path,
        );
        expect((await agent.run())['success'], isFalse);
        expect((await File(log).readAsString()).trim(), 'reset');
      } finally {
        await tmp.delete(recursive: true);
      }
    });
  });
}

void lifecycleInputCleanupTests() {
  group('CliAgent input cleanup', () {
    test('cleanupInputFolder deletes input folder', () async {
      final tmp = await _createTempDir();
      try {
        await (CliAgent(
          params: CliAgentParams()..cliCommands = ['echo done'],
          workingDirectory: tmp.path,
        )).run();
        expect(
          Directory('${tmp.path}/input/cli-agent').existsSync(),
          isFalse,
        );
      } finally {
        await tmp.delete(recursive: true);
      }
    });

    test('cleanupInputFolder=false keeps input folder', () async {
      final tmp = await _createTempDir();
      try {
        await (CliAgent(
          params: CliAgentParams()
            ..cliCommands = ['echo done']
            ..cleanupInputFolder = false,
          workingDirectory: tmp.path,
        )).run();
        expect(
          Directory('${tmp.path}/input/cli-agent').existsSync(),
          isTrue,
        );
      } finally {
        await tmp.delete(recursive: true);
      }
    });
  });
}

void lifecycleFolderCleanupTests() {
  group('CliAgent folder cleanup', () {
    test('cleanupOutputsFolder deletes outputs folder', () async {
      final tmp = await _createTempDir();
      try {
        await (CliAgent(
          params: CliAgentParams()
            ..cliCommands = ['echo done']
            ..cleanupOutputsFolder = true,
          workingDirectory: tmp.path,
        )).run();
        expect(Directory('${tmp.path}/outputs').existsSync(), isFalse);
      } finally {
        await tmp.delete(recursive: true);
      }
    });

    test('clears stale outputs/response.md on start', () async {
      final tmp = await _createTempDir();
      try {
        await _writeResponse(tmp.path, 'outputs', 'stale');
        await (CliAgent(
          params: CliAgentParams()
            ..cliCommands = ['echo done']
            ..cleanupInputFolder = false,
          workingDirectory: tmp.path,
        )).run();
        expect(
          File('${tmp.path}/outputs/$responseFileName').existsSync(),
          isFalse,
        );
      } finally {
        await tmp.delete(recursive: true);
      }
    });
  });
}

void lifecycleContextTests() {
  group('CliAgent context', () {
    test('uses contextId from metadata', () async {
      final tmp = await _createTempDir();
      try {
        final agent = CliAgent(
          params: CliAgentParams()
            ..cliCommands = ['echo done']
            ..metadata = {'contextId': 'custom-ctx'}
            ..cleanupInputFolder = false,
          workingDirectory: tmp.path,
        );
        expect((await agent.run())['contextId'], 'custom-ctx');
        expect(
          Directory('${tmp.path}/input/custom-ctx').existsSync(),
          isTrue,
        );
      } finally {
        await tmp.delete(recursive: true);
      }
    });

    test('defaults to cli-agent contextId', () async {
      final tmp = await _createTempDir();
      try {
        final agent = CliAgent(
          params: CliAgentParams()
            ..cliCommands = ['echo done']
            ..cleanupInputFolder = false,
          workingDirectory: tmp.path,
        );
        expect((await agent.run())['contextId'], 'cli-agent');
      } finally {
        await tmp.delete(recursive: true);
      }
    });

    test('returns early when cliCommands empty', () async {
      final result = await CliAgent(
        params: CliAgentParams()..cliCommands = const [],
      ).run();
      expect(result['success'], isTrue);
      expect(result['message'], contains('No cliCommands'));
    });
  });
}

void lifecycleEnvTests() {
  group('CliAgent env', () {
    test('sets envVariables overrides and interpolates \$VAR from dmtools.env',
        () async {
      final tmp = await _createTempDir();
      final log = '${tmp.path}/env.log';
      try {
        await File('${tmp.path}/dmtools.env').writeAsString(
          'ENV_VAR_DEV_QUEUE=[{"provider_type":"copilot"}]\n',
        );
        await (CliAgent(
          params: CliAgentParams()
            ..cliCommands = [
              'printf "%s|%s" "\$MY_VAR" "\$FA_PROVIDERS_QUEUE" > "$log"'
            ]
            ..envVariables = {
              'MY_VAR': 'injected-value',
              'FA_PROVIDERS_QUEUE': r'$ENV_VAR_DEV_QUEUE',
            }
            ..cleanupInputFolder = false,
          workingDirectory: tmp.path,
        )).run();
        expect(
          (await File(log).readAsString()).trim(),
          'injected-value|[{"provider_type":"copilot"}]',
        );
      } finally {
        await tmp.delete(recursive: true);
      }
    });
  });
}

// ======================================================================
// AgentFactory
// ======================================================================

void factoryTests() {
  group('AgentFactory.create', () {
    test('creates CliAgent for cliagent', () {
      expect(
        AgentFactory.create('cliagent', {
          'cliCommands': ['echo']
        }),
        isA<CliAgent>(),
      );
    });

    test('creates JsRunnerJob for jsrunner', () {
      expect(
        AgentFactory.create('jsrunner', {'jsPath': 't.js'}),
        isA<JsRunnerJob>(),
      );
    });

    test('matches case-insensitively', () {
      expect(
        AgentFactory.create('CLIAGENT', {
          'cliCommands': ['echo']
        }),
        isA<CliAgent>(),
      );
    });

    test('throws ArgumentError for unknown', () {
      expect(() => AgentFactory.create('nope', {}), throwsArgumentError);
    });
  });
}

void lifecycleTicketDataTests() {
  group('CliAgent ticket data', () {
    test('writes ticket.md to input context when ticketData is set', () async {
      final tmp = await _createTempDir();
      try {
        await (CliAgent(
          params: CliAgentParams()
            ..cliCommands = ['echo done']
            ..cleanupInputFolder = false,
          workingDirectory: tmp.path,
          ticketData: {
            'key': 'PROJ-7',
            'fields': {'summary': 'Ship it', 'description': 'Final polish.'},
          },
        )).run();
        final dir = '${tmp.path}/input/cli-agent';
        expect(File('$dir/ticket.md').readAsStringSync(),
            contains('# PROJ-7: Ship it'));
        expect(File('$dir/ticket.json').existsSync(), isTrue);
      } finally {
        await tmp.delete(recursive: true);
      }
    });

    test('creates empty input context when ticketData is null', () async {
      final tmp = await _createTempDir();
      try {
        await (CliAgent(
          params: CliAgentParams()
            ..cliCommands = ['echo done']
            ..cleanupInputFolder = false,
          workingDirectory: tmp.path,
        )).run();
        expect(Directory('${tmp.path}/input/cli-agent').listSync(), isEmpty);
      } finally {
        await tmp.delete(recursive: true);
      }
    });
  });
}

void ticketHydrationTests() {
  group('CliAgent ticket hydration', () {
    test('hydrates params.ticket from input/<contextId>/ticket.json', () async {
      final tmp = await _createTempDir();
      final log = '${tmp.path}/ticket_key.log';
      final js = File(
        '${tmp.path}/post_cb.js',
      )..writeAsStringSync(
          'function action(params) { '
          'file_write({path: "$log", content: params.ticket.key}); }',
        );
      try {
        Directory('${tmp.path}/input/gh-77').createSync(recursive: true);
        File('${tmp.path}/input/gh-77/ticket.json').writeAsStringSync(
          '{"key":"gh-77","number":77,"title":"Port the thing"}',
        );
        await (CliAgent(
          params: CliAgentParams()
            ..cliCommands = ['echo done']
            ..metadata = {'contextId': 'gh-77'}
            ..postJSAction = js.path
            ..cleanupInputFolder = false,
          workingDirectory: tmp.path,
        )).run();
        expect((await File(log).readAsString()).trim(), 'gh-77');
      } finally {
        await tmp.delete(recursive: true);
      }
    });
  });
}

void ticketCompositeHydrationTests() {
  group('CliAgent composite ticket hydration', () {
    test(
      'hydrates params.ticket and inputFolderPath for composite GitHub contextId',
      () async {
        final tmp = await _createTempDir();
        final log = '${tmp.path}/ticket_key.log';
        final js = File(
          '${tmp.path}/post_cb.js',
        )..writeAsStringSync(
            'function action(params) { '
            'file_write({path: "$log", content: params.ticket.key + "|" + params.jobParams.inputFolderPath}); }',
          );
        try {
          Directory('${tmp.path}/input/gh-81').createSync(recursive: true);
          File('${tmp.path}/input/gh-81/ticket.json').writeAsStringSync(
            '{"key":"acme/widgets#81","number":81,"title":"Composite"}',
          );
          await (CliAgent(
            params: CliAgentParams()
              ..cliCommands = ['echo done']
              ..metadata = {'contextId': 'acme/widgets#81'}
              ..postJSAction = js.path
              ..cleanupInputFolder = false,
            workingDirectory: tmp.path,
          )).run();
          expect(
            (await File(log).readAsString()).trim(),
            'acme/widgets#81|${tmp.path}/input/gh-81',
          );
        } finally {
          await tmp.delete(recursive: true);
        }
      },
    );
  });
}

void ticketTimerHydrationTests() {
  group('CliAgent timer ticket hydration', () {
    test(
      'timer context action sees params.ticket hydrated from ticket.json',
      () async {
        final tmp = await _createTempDir();
        final log = '${tmp.path}/timer_key.log';
        final js = File(
          '${tmp.path}/timer_cb.js',
        )..writeAsStringSync(
            'function action(params) { '
            'file_write({path: "$log", content: params.ticket.key}); }',
          );
        try {
          Directory('${tmp.path}/input/gh-78').createSync(recursive: true);
          File('${tmp.path}/input/gh-78/ticket.json').writeAsStringSync(
            '{"key":"gh-78","number":78,"title":"T"}',
          );
          final agent = CliAgent(
            params: CliAgentParams()
              ..cliCommands = ['echo done']
              ..metadata = {'contextId': 'gh-78'}
              ..timerJSAction = js.path
              ..timerIntervalSeconds = 0
              ..cleanupInputFolder = false,
            workingDirectory: tmp.path,
          );
          await agent.run();
          expect((await File(log).readAsString()).trim(), 'gh-78');
        } finally {
          await tmp.delete(recursive: true);
        }
      },
    );
  });
}

void ticketHydrationEdgeTests() {
  group('CliAgent ticket hydration edge cases', () {
    test('malformed ticket.json behaves as no ticket', () async {
      final tmp = await _createTempDir();
      final log = '${tmp.path}/ticket_key.log';
      final js = File(
        '${tmp.path}/post_cb.js',
      )..writeAsStringSync(
          'function action(params) { '
          'file_write({path: "$log", content: String(!params.ticket)}); }',
        );
      try {
        Directory('${tmp.path}/input/gh-79').createSync(recursive: true);
        File('${tmp.path}/input/gh-79/ticket.json')
            .writeAsStringSync('{not json');
        await (CliAgent(
          params: CliAgentParams()
            ..cliCommands = ['echo done']
            ..metadata = {'contextId': 'gh-79'}
            ..postJSAction = js.path
            ..cleanupInputFolder = false,
          workingDirectory: tmp.path,
        )).run();
        expect((await File(log).readAsString()).trim(), 'true');
      } finally {
        await tmp.delete(recursive: true);
      }
    });
  });
}

void ticketHydrationPrecedenceTests() {
  group('CliAgent ticket hydration precedence', () {
    test('explicit ticketData wins over the ticket.json convention', () async {
      final tmp = await _createTempDir();
      final log = '${tmp.path}/ticket_key.log';
      final js = File('${tmp.path}/post_cb.js')
        ..writeAsStringSync('function action(params) { '
            'file_write({path: "$log", content: params.ticket.key}); }');
      try {
        Directory('${tmp.path}/input/gh-80').createSync(recursive: true);
        File('${tmp.path}/input/gh-80/ticket.json')
            .writeAsStringSync('{"key":"gh-80"}');
        await (CliAgent(
          params: CliAgentParams()
            ..cliCommands = ['echo done']
            ..metadata = {'contextId': 'gh-80'}
            ..postJSAction = js.path
            ..cleanupInputFolder = false,
          workingDirectory: tmp.path,
          ticketData: {'key': 'PROJ-9'},
        )).run();
        expect((await File(log).readAsString()).trim(), 'PROJ-9');
      } finally {
        await tmp.delete(recursive: true);
      }
    });
  });
}

Future<Directory> _createTempDir() =>
    Directory.systemTemp.createTemp('cli_agent_test_');

Future<void> _writeResponse(String baseDir, String folder, String content) =>
    File('$baseDir/$folder/$responseFileName')
        .create(recursive: true)
        .then((f) => f.writeAsString(content));
