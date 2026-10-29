/// Tests for the CliAgent JS-action surface — setup/preCli/post JS hooks,
/// the timer/error/line context actions, and the action() contract enforced
/// by JsJobRunner (Java `JobJavaScriptBridge` parity).
library;

import 'dart:io';

import 'package:dmtools/dmtools.dart';
import 'package:test/test.dart';

void main() {
  lifecycleJsActionTests();
  ticketContextJsActionTests();
  metadataBindingJsActionTests();
  metadataContextHooksJsActionTests();
  metadataOmissionJsActionTests();
  timerJsActionTests();
  cliErrorJsActionTests();
  cliOutputLineJsActionTests();
  cliPromptsConditionTests();
  cliPromptsPackConditionTests();
  cliPromptsConditionParserTests();
  jobParamsBindingAndPreActionSkipTests();
}

// ======================================================================
// AgentFactory
// ======================================================================

void lifecycleJsActionTests() {
  group('CliAgent JS actions', () {
    test('setup .js hook is executed via JsJobRunner', () async {
      final tmp = await _createTempDir();
      final log = '${tmp.path}/js_setup.log';
      try {
        final js = _actionJs(
          tmp,
          'setup_hook.js',
          'file_write({path: "$log", content: "ran"});',
        );
        await (CliAgent(
          params: CliAgentParams()
            ..cliCommands = ['echo done']
            ..setup = js.path
            ..cleanupInputFolder = false,
          workingDirectory: tmp.path,
        )).run();
        expect((await File(log).readAsString()).trim(), 'ran');
      } finally {
        await tmp.delete(recursive: true);
      }
    });

    test('preCliJSAction is executed via JsJobRunner', () async {
      final tmp = await _createTempDir();
      final log = '${tmp.path}/js_precli.log';
      try {
        final js = _actionJs(
          tmp,
          'pre_cli.js',
          'file_write({path: "$log", content: "ok"});',
        );
        await (CliAgent(
          params: CliAgentParams()
            ..cliCommands = ['echo done']
            ..preCliJSAction = js.path
            ..cleanupInputFolder = false,
          workingDirectory: tmp.path,
        )).run();
        expect((await File(log).readAsString()).trim(), 'ok');
      } finally {
        await tmp.delete(recursive: true);
      }
    });
  });
}

void ticketContextJsActionTests() {
  group('CliAgent JS actions — ticket context', () {
    test('JS actions see params.ticket from ticketData', () async {
      final tmp = await _createTempDir();
      final log = '${tmp.path}/js_ticket.log';
      try {
        final js = _actionJs(
          tmp,
          'post.js',
          'file_write({path: "$log", content: params.ticket.key});',
        );
        await (CliAgent(
          params: CliAgentParams()
            ..cliCommands = ['echo done']
            ..postJSAction = js.path
            ..cleanupInputFolder = false,
          workingDirectory: tmp.path,
          ticketData: const {
            'key': 'GH-21',
            'fields': {'summary': 's'},
          },
        )).run();
        expect((await File(log).readAsString()).trim(), 'GH-21');
      } finally {
        await tmp.delete(recursive: true);
      }
    });
  });
}

// ======================================================================
// CliAgent — top-level metadata binding (epam/dm.ai#623 parity)
// ======================================================================

void metadataBindingJsActionTests() {
  group('CliAgent JS actions — metadata binding (pre/post)', () {
    test('preJSAction and postJSAction see params.metadata', () async {
      final tmp = await _createTempDir();
      final log = '${tmp.path}/js_metadata.log';
      try {
        final pre = _actionJs(
          tmp,
          'pre_meta.js',
          'file_append({path: "$log", content: "pre=" + '
              'params.metadata.contextId + ":" + params.metadata.agentId '
              '+ "\\n"});',
        );
        final post = _actionJs(
          tmp,
          'post_meta.js',
          'file_append({path: "$log", content: "post=" + '
              'params.metadata.contextId + ":" + params.metadata.agentId '
              '+ "\\n"});',
        );
        await (CliAgent(
          params: CliAgentParams()
            ..cliCommands = ['echo done']
            ..metadata = const {'contextId': 'ctx-123', 'agentId': 'agent-1'}
            ..preJSAction = pre.path
            ..postJSAction = post.path
            ..cleanupInputFolder = false,
          workingDirectory: tmp.path,
        )).run();
        expect(
          (await File(log).readAsString()).trim().split('\n'),
          ['pre=ctx-123:agent-1', 'post=ctx-123:agent-1'],
        );
      } finally {
        await tmp.delete(recursive: true);
      }
    });
  });
}

void metadataContextHooksJsActionTests() {
  group('CliAgent JS actions — metadata binding (preCli/timer)', () {
    test('preCliJSAction sees params.metadata.contextId', () async {
      final tmp = await _createTempDir();
      final log = '${tmp.path}/js_precli_meta.log';
      try {
        final js = _actionJs(
          tmp,
          'pre_cli_meta.js',
          'file_write({path: "$log", content: params.metadata.contextId});',
        );
        await (CliAgent(
          params: CliAgentParams()
            ..cliCommands = ['echo done']
            ..metadata = const {'contextId': 'gh-317', 'agentId': 'senior'}
            ..preCliJSAction = js.path
            ..cleanupInputFolder = false,
          workingDirectory: tmp.path,
        )).run();
        expect((await File(log).readAsString()).trim(), 'gh-317');
      } finally {
        await tmp.delete(recursive: true);
      }
    });

    test('timerJSAction sees params.metadata.contextId', () async {
      final tmp = await _createTempDir();
      final log = '${tmp.path}/js_timer_meta.log';
      try {
        final js = _actionJs(
          tmp,
          'timer_meta.js',
          'file_write({path: "$log", content: params.metadata.contextId});',
        );
        await (CliAgent(
          params: CliAgentParams()
            ..cliCommands = ['echo done']
            ..metadata = const {'contextId': 'ctx-timer'}
            ..timerJSAction = js.path
            ..cleanupInputFolder = false,
          workingDirectory: tmp.path,
        )).run();
        // The final tick always runs after the batch, so this is
        // deterministic even though no periodic tick fits in the batch.
        expect((await File(log).readAsString()).trim(), 'ctx-timer');
      } finally {
        await tmp.delete(recursive: true);
      }
    });
  });
}

void metadataOmissionJsActionTests() {
  group('CliAgent JS actions — metadata null-omission', () {
    test('params.metadata stays undefined when the job has no metadata',
        () async {
      final tmp = await _createTempDir();
      final log = '${tmp.path}/js_no_meta.log';
      try {
        final js = _actionJs(
          tmp,
          'post_no_meta.js',
          'file_write({path: "$log", content: typeof params.metadata});',
        );
        await (CliAgent(
          params: CliAgentParams()
            ..cliCommands = ['echo done']
            ..postJSAction = js.path
            ..cleanupInputFolder = false,
          workingDirectory: tmp.path,
        )).run();
        // Java null-omission parity: no key instead of a null value.
        expect((await File(log).readAsString()).trim(), 'undefined');
      } finally {
        await tmp.delete(recursive: true);
      }
    });
  });
}

// ======================================================================
// CliAgent — context JS actions (timer / error / line)
// ======================================================================

void timerJsActionTests() {
  group('CliAgent timerJSAction', () {
    test('fires during execution and on final tick', () async {
      final tmp = await _createTempDir();
      final log = '${tmp.path}/timer.log';
      try {
        final js = _actionJs(
          tmp,
          'timer.js',
          'file_append({path: "$log", '
              'content: "len=" + currentCliOutput.length + "\\n"});',
        );
        await (CliAgent(
          params: CliAgentParams()
            // 4s window for a 1s interval: ≥1 periodic tick lands even when
            // the suite's parallel load delays timer delivery past 1–2s.
            ..cliCommands = ['sleep 4; echo done']
            ..timerJSAction = js.path
            ..timerIntervalSeconds = 1
            ..cleanupInputFolder = false,
          workingDirectory: tmp.path,
        )).run();
        final lines = (await File(log).readAsString())
            .trim()
            .split('\n')
            .where((l) => l.isNotEmpty)
            .toList();
        // At least one periodic tick (during the 2s command) + the final tick.
        expect(lines.length, greaterThanOrEqualTo(2));
        // The final tick runs after the batch, so it sees the full output.
        expect(lines.last, isNot('len=0'));
      } finally {
        await tmp.delete(recursive: true);
      }
    });
  });
}

void cliErrorJsActionTests() {
  group('CliAgent cliExecutionErrorJSAction', () {
    test('runs with errorMessage on failure', () async {
      final tmp = await _createTempDir();
      final log = '${tmp.path}/error.log';
      try {
        final js = _actionJs(
          tmp,
          'error.js',
          'file_write({path: "$log", content: errorMessage});',
        );
        await (CliAgent(
          params: CliAgentParams()
            ..cliCommands = ['exit 7']
            ..cliExecutionErrorJSAction = js.path
            ..cleanupInputFolder = false,
          workingDirectory: tmp.path,
        )).run();
        expect((await File(log).readAsString()), contains('exit code 7'));
      } finally {
        await tmp.delete(recursive: true);
      }
    });

    test('is skipped on success', () async {
      final tmp = await _createTempDir();
      final log = '${tmp.path}/error_ok.log';
      try {
        final js = _actionJs(
          tmp,
          'error_ok.js',
          'file_write({path: "$log", content: "ran"});',
        );
        await (CliAgent(
          params: CliAgentParams()
            ..cliCommands = ['echo ok']
            ..cliExecutionErrorJSAction = js.path
            ..cleanupInputFolder = false,
          workingDirectory: tmp.path,
        )).run();
        expect(File(log).existsSync(), isFalse);
      } finally {
        await tmp.delete(recursive: true);
      }
    });
  });
}

void cliOutputLineJsActionTests() {
  group('CliAgent cliOutputLineJSAction', () {
    test('runs for each output line', () async {
      final tmp = await _createTempDir();
      final log = '${tmp.path}/lines.log';
      try {
        final js = _actionJs(
          tmp,
          'lines.js',
          'file_append({path: "$log", content: line + "\\n"});',
        );
        await (CliAgent(
          params: CliAgentParams()
            ..cliCommands = ["printf 'a\\nb\\nc\\n'"]
            ..cliOutputLineJSAction = js.path
            ..cleanupInputFolder = false,
          workingDirectory: tmp.path,
        )).run();
        expect(
          (await File(log).readAsString()).trim().split('\n'),
          ['a', 'b', 'c'],
        );
      } finally {
        await tmp.delete(recursive: true);
      }
    });

    test('returning true stops the batch', () async {
      final tmp = await _createTempDir();
      final log = '${tmp.path}/stop.log';
      final marker = File('${tmp.path}/marker');
      try {
        final js = File('${tmp.path}/stop.js');
        await js.writeAsString(
          'function action(params) {'
          '  file_append({path: "$log", content: line + "\\n"});'
          '  return line === "stop";'
          '}',
        );
        await (CliAgent(
          params: CliAgentParams()
            ..cliCommands = ["printf 'go\\nstop\\n'", 'echo ran > marker']
            ..cliOutputLineJSAction = js.path
            ..cleanupInputFolder = false,
          workingDirectory: tmp.path,
        )).run();
        // The action saw "go" then "stop" (which triggered the stop).
        expect((await File(log).readAsString()).trim().split('\n'),
            ['go', 'stop']);
        // The second command never ran because the batch was aborted.
        expect(marker.existsSync(), isFalse);
      } finally {
        await tmp.delete(recursive: true);
      }
    });
  });
}

void cliPromptsConditionTests() {
  group('CliAgent cliPrompts condition evaluation', () {
    test('includes section when condition returns true and skips when false',
        () async {
      final tmp = await _createTempDir();
      try {
        final condTrue = _actionJs(tmp, 'cond_true.js', 'return true;');
        final condFalse = _actionJs(tmp, 'cond_false.js', 'return false;');
        final result = await (CliAgent(
          params: CliAgentParams()
            ..cliCommands = ['cat']
            ..cliPrompts = [
              'BASE_PROMPT',
              {
                'id': 'codegraph',
                'prompt': 'INCLUDED_SECTION',
                'condition': condTrue.path,
              },
              {
                'id': 'skipped',
                'prompts': ['EXCLUDED_SECTION'],
                'condition': condFalse.path,
              },
              'TAIL_PROMPT',
            ]
            ..cleanupInputFolder = false,
          workingDirectory: tmp.path,
        )).run();
        final resp = result['response'] as String;
        expect(resp, contains('BASE_PROMPT'));
        expect(resp, contains('INCLUDED_SECTION'));
        expect(resp, isNot(contains('EXCLUDED_SECTION')));
        expect(resp, contains('TAIL_PROMPT'));
      } finally {
        await tmp.delete(recursive: true);
      }
    });
  });
}

void cliPromptsPackConditionTests() {
  group('CliAgent cliPrompts pack condition resolution', () {
    test(
        'resolves agents/ and pack: condition paths against workDir or unpacked pack root',
        () async {
      final tmp = await _createTempDir();
      final packDir = await _createTempDir();
      try {
        Directory('${tmp.path}/js/conditions').createSync(recursive: true);
        File('${tmp.path}/js/conditions/local.js')
            .writeAsStringSync('function action() { return true; }\n');
        File('${packDir.path}/manifest.json').writeAsStringSync('{}');
        Directory('${packDir.path}/js/conditions').createSync(recursive: true);
        final postJs = File('${packDir.path}/js/post.js')
          ..writeAsStringSync('function action() {}\n');
        File('${packDir.path}/js/conditions/packed.js')
            .writeAsStringSync('function action() { return true; }\n');
        final result = await (CliAgent(
          params: CliAgentParams()
            ..cliCommands = ['cat']
            ..postJSAction = postJs.path
            ..cliPrompts = [
              {
                'id': 'local_cg',
                'prompt': 'LOCAL_CG_INCLUDED',
                'condition': './agents/js/conditions/local.js',
              },
              {
                'id': 'pack_cg',
                'prompt': 'PACK_CG_INCLUDED',
                'condition': 'pack:/agents/js/conditions/packed.js',
              },
              {
                'id': 'missing_cg',
                'prompt': 'MISSING_CG_EXCLUDED',
                'condition': 'agents/js/conditions/missing.js',
              },
            ]
            ..cleanupInputFolder = false,
          workingDirectory: tmp.path,
        )).run();
        final resp = result['response'] as String;
        expect(resp, contains('LOCAL_CG_INCLUDED'));
        expect(resp, contains('PACK_CG_INCLUDED'));
        expect(resp, isNot(contains('MISSING_CG_EXCLUDED')));
      } finally {
        await tmp.delete(recursive: true);
        await packDir.delete(recursive: true);
      }
    });
  });
}

void cliPromptsConditionParserTests() {
  group('isCliPromptConditionMet & flattenCliPrompts', () {
    test('isCliPromptConditionMet parses map, bool, and JSON string payloads',
        () {
      expect(isCliPromptConditionMet(null), isFalse);
      expect(isCliPromptConditionMet(true), isTrue);
      expect(isCliPromptConditionMet(false), isFalse);
      expect(
        isCliPromptConditionMet({'result': true, 'uncaughtException': false}),
        isTrue,
      );
      expect(
        isCliPromptConditionMet({'result': true, 'uncaughtException': true}),
        isFalse,
      );
      expect(isCliPromptConditionMet('true'), isTrue);
      expect(isCliPromptConditionMet('"true"'), isTrue);
      expect(isCliPromptConditionMet('false'), isFalse);
      expect(
        isCliPromptConditionMet('{"result":true,"uncaughtException":false}'),
        isTrue,
      );
      expect(
        isCliPromptConditionMet('{"result":true,"uncaughtException":true}'),
        isFalse,
      );
    });

    test('flattenCliPrompts evaluates condition callback and non-map elements',
        () {
      final params = CliAgentParams()
        ..cliPrompts = [
          'p1',
          42,
          {'id': 's1', 'prompt': 'p2', 'condition': '  '},
          {'id': 's2', 'prompt': 'p3', 'condition': 'yes'},
          {'id': 's3', 'prompt': 'p4', 'condition': 'no'},
        ];
      expect(
        params.flattenCliPrompts(
          params.cliPrompts,
          conditionEvaluator: (c) => c == 'yes',
        ),
        ['p1', 'p2', 'p3'],
      );
    });
  });
}

void jobParamsBindingAndPreActionSkipTests() {
  group('CliAgent params.jobParams bindings and preJSAction==false skip (#465)',
      () {
    _jobParamsBindingTest();
    _preActionSkipTest();
  });
}

void _jobParamsBindingTest() {
  test(
      'params.jobParams exposes customParams, metadata, initiator, and outputType',
      () async {
    final tmp = await _createTempDir();
    final log = '${tmp.path}/job_params.log';
    try {
      final js = _actionJs(
        tmp,
        'check_job_params.js',
        'var jp = params.jobParams || params; '
            'file_write({path: "$log", content: '
            'jp.customParams.targetRepository + "|" + '
            'jp.metadata.agentId + "|" + '
            'jp.initiator + "|" + '
            'jp.outputType});',
      );
      await (CliAgent(
        params: CliAgentParams()
          ..cliCommands = ['echo done']
          ..customParams = const {'targetRepository': 'acme/repo'}
          ..metadata = const {'contextId': 'KEY-1', 'agentId': 'pr_review'}
          ..initiator = 'bot-user'
          ..outputType = 'none'
          ..preCliJSAction = js.path
          ..cleanupInputFolder = false,
        workingDirectory: tmp.path,
      )).run();
      expect(
        (await File(log).readAsString()).trim(),
        'acme/repo|pr_review|bot-user|none',
      );
    } finally {
      await tmp.delete(recursive: true);
    }
  });
}

void _preActionSkipTest() {
  test(
      'preJSAction returning false skips input context, preCliJSAction, cliCommands, and postJSAction',
      () async {
    final tmp = await _createTempDir();
    final log = '${tmp.path}/skipped_steps.log';
    try {
      final pre = _actionJs(tmp, 'pre_skip.js', 'return false;');
      final preCli = _actionJs(
        tmp,
        'pre_cli.js',
        'file_append({path: "$log", content: "preCli\\n"});',
      );
      final post = _actionJs(
        tmp,
        'post.js',
        'file_append({path: "$log", content: "post\\n"});',
      );
      final result = await (CliAgent(
        params: CliAgentParams()
          ..cliCommands = ['echo cli >> "$log"']
          ..metadata = const {'contextId': 'KEY-99'}
          ..preJSAction = pre.path
          ..preCliJSAction = preCli.path
          ..postJSAction = post.path
          ..cleanupInputFolder = false,
        workingDirectory: tmp.path,
      )).run();
      expect(result['success'], isTrue);
      expect(result['response'], 'Skipped by pre-action');
      expect(File(log).existsSync(), isFalse);
      expect(Directory('${tmp.path}/input/KEY-99').existsSync(), isFalse);
    } finally {
      await tmp.delete(recursive: true);
    }
  });
}

/// Writes a JS hook script wrapped in the action() contract enforced by
/// [JsJobRunner.runScript] (Java `JobJavaScriptBridge` parity).
File _actionJs(Directory dir, String name, String body) =>
    File('${dir.path}/$name')
      ..writeAsStringSync('function action(params) { $body }');

Future<Directory> _createTempDir() async {
  return Directory.systemTemp.createTemp('cli_agent_test_');
}
