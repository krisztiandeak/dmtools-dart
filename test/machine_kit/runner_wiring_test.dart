/// Runner-wiring contract tests for the machine loop (gh-146 edition).
///
/// The per-leg runner configs live in `.dmtools/runners/` and are selected
/// by the factory guard via `.dmtools/config.js` `sm.runners`. Their
/// `parent` and prompt paths resolve at run time in the factory checkout
/// (`factory-agents/` — dmtools-agents cloned beside the target repo by the
/// factory workflow), which does not exist in this repository. Runner-level
/// wiring is therefore pinned on the raw runner JSON here, and the parent
/// side on the same content in the pinned `agents/` submodule.
///
/// Covered contracts:
/// - the review runner opts in to the formal GitHub review (gh-129) with
///   approve-with-suggestions, while the parent's own customParams survive
///   the deepMerge;
/// - the review runner extends the parent prompts with the verdict rules
///   (gh-71 machine protocol) and the rules file exists;
/// - the rework runner keeps its pack parent and the fa provider pin;
/// - the factory workflow invokes review-verdict.sh and defines the cap.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:dmtools/src/cli/run_command_processor.dart';
import 'package:dmtools/src/compile/agent_pack_compiler.dart'
    hide AgentPackException;
import 'package:dmtools/src/config/property_reader.dart';
import 'package:dmtools/src/pack/agent_pack_resolver.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../pack/pack_fixtures.dart';

Map<String, dynamic> _runnerJson(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

/// The verdict-rules prompt exactly as the review runner references it
/// (a `pack:` ref resolved against the unpacked parent pack at run time).
const _verdictRulesRunnerPath =
    'pack:instructions/pr_review/review_verdict_rules.md';

/// In-repo copy of the verdict-rules instruction (agents/ submodule).
const _verdictRulesFile =
    'agents/instructions/pr_review/review_verdict_rules.md';

void main() {
  formalReviewWiringTests();
  wiringTests();
  resolutionTests();
  resolutionPackRefTests();
  faProviderPreconfigTests();
}

/// gh-129: the review runner must opt in to the formal GitHub review
/// (real APPROVE / REQUEST_CHANGES reviews, not just the pr_approved
/// label) while the parent's own customParams survive the deepMerge.
void formalReviewWiringTests() {
  group('machine wiring: formal review', () {
    test(
        'review runner turns on formalGithubReview '
        '(real approvals, not just labels)', () {
      final customParams =
          (_runnerJson('.dmtools/runners/fa-review.json')['params']) as Map;
      final runnerCustomParams = customParams['customParams'] as Map;
      expect(runnerCustomParams['formalGithubReview'], true);
      expect(runnerCustomParams['allowApproveWithSuggestions'], true);
      // deepMerge keeps the parent's own customParams alongside the flags
      // at run time — pinned here on the parent's in-repo copy.
      final parentCustomParams =
          (_runnerJson('agents/pr_review.json')['params'])['customParams']
              as Map;
      expect(parentCustomParams['removeLabel'], 'sm_story_review_triggered');
      expect(parentCustomParams['checkOpenPR'], true);
    });
  });
}

/// Contract tests: the runners + workflow must stay wired to the script and
/// the verdict-rules instruction file.
void wiringTests() {
  group('machine wiring', () {
    test('review runner extends parent prompts with the verdict rules', () {
      final runner = _runnerJson('.dmtools/runners/fa-review.json');
      final params = runner['params'] as Map;
      final prompts = (params['cliPrompts'] as List).cast<String>();
      expect(prompts, contains(_verdictRulesRunnerPath));
      // Parent prompts survive the merge (merge: ["params.cliPrompts"]).
      expect(runner['merge'], contains('params.cliPrompts'));
      final parentPrompts = ((_runnerJson('agents/pr_review.json')['params'])
          as Map)['cliPrompts'] as List;
      expect(parentPrompts.cast<String>(),
          contains('./agents/instructions/pr_review/general_guidelines.md'));
      expect(
        (params['customParams'] as Map)['allowApproveWithSuggestions'],
        true,
      );
    });

    test('verdict-rules instruction file exists', () {
      expect(File(_verdictRulesFile).existsSync(), isTrue);
    });

    test('rework runner still resolves against its pack parent', () {
      final runner = _runnerJson('.dmtools/runners/fa-rework.json');
      expect((runner['parent'] as Map)['path'], 'pr_rework@latest');
      expect(
          ((runner['params'] as Map)['envVariables']
              as Map)['AI_AGENT_PROVIDER'],
          'fa');
    });

    test('workflow invokes the script and defines the cap', () {
      // 2026-10-15: the factory teammate workflow moved to
      // dmtools-agentic-workflows. When a pinned submodule still vendors it
      // the wiring invariants run; on the new tree the dart tree owns only
      // the delegation (content invariants re-homed to awf).
      final workflowFile =
          File('agents/.github/workflows/factory-teammate.yml');
      if (!workflowFile.existsSync()) {
        final stub =
            File('agents/.github/workflows/ai-teammate.yml').readAsStringSync();
        expect(
          stub.contains('factory-teammate.yml'),
          isTrue,
          reason: 'the agents stub must delegate to the awf factory workflow',
        );
        return;
      }
      final yml = workflowFile.readAsStringSync();
      expect(yml, contains('review-verdict.sh'));
      expect(yml, contains('MAX_AUTO_REWORK_ROUNDS'));
      expect(yml, contains('needs-human'));
    });
  });
}

/// gh-146 review thread 4 — the raw pins above cannot execute the
/// parent-chain deepMerge `dmtools run` performs: a typo in a `merge`
/// directive or a parent-shape change passes raw-pin tests and breaks the
/// leg at run time. The resolution groups below build the real zip flow
/// end to end: the four parent pipelines are compiled into agent packs
/// from the pinned `agents/` submodule, served from a loopback registry
/// under `<pipeline>@latest`, and each runner under
/// `<tmp>/.dmtools/runners/` (a bare target repo — no `factory-agents/`
/// checkout anywhere) is resolved through [RunCommandProcessor] with an
/// [AgentPackResolver] pointed at that registry. The parent's own paths
/// and the runner's `pack:` prompt refs must land in the pack cache for
/// the legs to work.

/// Shared fixture for the pack-resolution groups: compiles the four parent
/// pipelines into agent packs from the pinned `agents/` submodule and
/// serves them from a loopback registry under `<pipeline>@latest`.
class _PackRegistryFixture {
  late Directory tmp;
  late Directory packsRoot;
  ({int port, Isolate isolate})? server;

  Future<void> setUp() async {
    tmp = Directory.systemTemp.createTempSync('fa_runner_pack_resolution');
    packsRoot = Directory('${tmp.path}/packs')..createSync();
    final staging = Directory('${tmp.path}/agents-root')..createSync();
    final dist = Directory('${tmp.path}/dist')..createSync();
    // Staging mirrors a dmtools-agents checkout root: the pipeline
    // configs at the root, the subtrees their closures reference.
    for (final name in _packAgents) {
      File('agents/$name').copySync('${staging.path}/$name');
    }
    for (final dir in _packAgentsSubtrees) {
      _copyTree(Directory('agents/$dir'), Directory('${staging.path}/$dir'));
    }
    final files = <String, List<int>>{};
    final catalog = <String, String>{};
    for (final name in _packAgents) {
      final agent = name.replaceAll('.json', '');
      final zip = AgentPackCompiler(staging.path).compile(
          File('${staging.path}/$name'), '1.0.0', 'deadbeef', dist,
          extraDirs: ['instructions', 'prompts']).zipFile;
      final bytes = zip.readAsBytesSync();
      files['/$agent-1.0.0.zip'] = bytes;
      files['/$agent-1.0.0.zip.sha256'] = utf8.encode(
        '${sha256.convert(bytes)}  $agent-1.0.0.zip',
      );
      catalog[agent] = '1.0.0';
    }
    files['/catalog.json'] = utf8.encode(jsonEncode(catalog));
    server = await startRegistryServer(files);
    Directory('${tmp.path}/.dmtools/runners').createSync(recursive: true);
    for (final runner in _runners) {
      File('.dmtools/runners/$runner')
          .copySync('${tmp.path}/.dmtools/runners/$runner');
    }
  }

  void tearDown() {
    server?.isolate.kill();
    tmp.deleteSync(recursive: true);
  }

  /// Resolves one committed runner through [RunCommandProcessor] against
  /// the loopback registry.
  Map<String, dynamic> resolved(String runner) => jsonDecode(
        RunCommandProcessor(
          packResolver: AgentPackResolver(
            packsRoot: packsRoot,
            registryBaseUrl: 'http://127.0.0.1:${server!.port}',
          ),
        ).process(['run', '${tmp.path}/.dmtools/runners/$runner']),
      ) as Map<String, dynamic>;
}

/// Runner resolution through [RunCommandProcessor] with the pack registry
/// flow — merged-config semantics (fa pin, deep merge).
void resolutionTests() {
  final fixture = _PackRegistryFixture();
  group(
      'machine wiring: runner resolution through RunCommandProcessor '
      '(pack registry flow)', () {
    setUpAll(fixture.setUp);
    tearDownAll(fixture.tearDown);

    test('all four runners resolve their parent chain and keep the fa pin', () {
      for (final runner in _runners) {
        final env =
            (fixture.resolved(runner)['params'] as Map)['envVariables'] as Map;
        expect(env['AI_AGENT_PROVIDER'], 'fa',
            reason: '$runner must keep the fa provider pin after the '
                'parent-chain deepMerge');
      }
    });

    test(
        'review runner deep-merges gh-129 custom params '
        'alongside the parent\'s own', () {
      final custom = (fixture.resolved('fa-review.json')['params']
          as Map)['customParams'] as Map;
      expect(custom['formalGithubReview'], isTrue);
      expect(custom['allowApproveWithSuggestions'], isTrue);
      expect(custom['checkOpenPR'], isTrue,
          reason: "the parent's own customParams must survive the "
              'deepMerge alongside the runner overrides');
      expect(custom['removeLabel'], 'sm_story_review_triggered',
          reason: "the parent's own removeLabel must survive too");
    });
  });
}

/// Runner resolution through [RunCommandProcessor] with the pack registry
/// flow — `pack:` references landing in the unpacked cache.
void resolutionPackRefTests() {
  final fixture = _PackRegistryFixture();
  group(
      'machine wiring: runner pack refs rewrite into the pack cache '
      '(pack registry flow)', () {
    setUpAll(fixture.setUp);
    tearDownAll(fixture.tearDown);

    test('merge directive appends the pack-resolved verdict rules', () {
      final params = fixture.resolved('fa-review.json')['params'] as Map;
      final parentPrompts = (_runnerJson('agents/pr_review.json')['params']
          as Map)['cliPrompts'] as List;
      final prompts = params['cliPrompts'] as List;
      // Runner appends: the pack verdict rules + the repo-local Java
      // parity instruction (gh-430).
      expect(prompts, hasLength(parentPrompts.length + 2),
          reason: 'a missing/typoed "merge": ["params.cliPrompts"] would '
              'replace the parent prompts instead of appending');
      expect(prompts.last, '.dmtools/instructions/java_parity.md',
          reason: 'repo-local prompt passes through unrewritten');
      final verdictRules = prompts[prompts.length - 2] as String;
      expect(verdictRules, startsWith(fixture.packsRoot.path),
          reason: 'the pack: ref must resolve into the pack cache');
      expect(verdictRules,
          endsWith('instructions/pr_review/review_verdict_rules.md'));
      expect(File(verdictRules).existsSync(), isTrue);
      // The parent's own prompts are rewritten into the cache as well;
      // literal prompt text (no file behind it) passes through untouched.
      for (final item in prompts.take(parentPrompts.length)) {
        if (item is String && item.startsWith(fixture.packsRoot.path)) {
          expect(File(item).existsSync(), isTrue, reason: item);
        } else if (item is Map) {
          final secPrompt = item['prompt'] as String?;
          if (secPrompt != null &&
              secPrompt.startsWith(fixture.packsRoot.path)) {
            expect(File(secPrompt).existsSync(), isTrue, reason: secPrompt);
          }
          final cond = item['condition'] as String?;
          if (cond != null && cond.startsWith(fixture.packsRoot.path)) {
            expect(File(cond).existsSync(), isTrue, reason: cond);
          }
        }
      }
    });

    test('parent pack paths rewrite into the cache (js/actions/scripts)', () {
      final params = fixture.resolved('fa-bug-dev.json')['params'] as Map;
      final post = params['postJSAction'] as String;
      expect(post, startsWith(fixture.packsRoot.path));
      expect(post, endsWith('js/developBugAndCreatePR.js'));
      expect(File(post).existsSync(), isTrue);
      final commands = (params['cliCommands'] as List).cast<String>();
      expect(commands.single, startsWith(fixture.packsRoot.path));
      expect(commands.single, endsWith('scripts/run-agent.sh'));
      expect(File(commands.single).existsSync(), isTrue);
    });
  });
}

/// The parent pipelines, one agent pack each (`<name>@latest` registry
/// refs), served from the loopback registry in [resolutionTests].
const _packAgents = [
  'bug_development.json',
  'story_development.json',
  'pr_review.json',
  'pr_rework.json',
];

/// Subtrees of the `agents/` submodule the pack closures resolve against.
const _packAgentsSubtrees = [
  'js',
  'instructions',
  'scripts',
  'docs',
  'prompts'
];

const _runners = [
  'fa-bug-dev.json',
  'fa-story-dev.json',
  'fa-review.json',
  'fa-rework.json',
];

/// Recursively copies [src] into [dst] (no symlink following).
void _copyTree(Directory src, Directory dst) {
  dst.createSync(recursive: true);
  for (final entity in src.listSync(followLinks: false)) {
    final name = p.basename(entity.path);
    if (entity is Directory) {
      _copyTree(entity, Directory('${dst.path}/$name'));
    } else if (entity is File) {
      entity.copySync('${dst.path}/$name');
    }
  }
}

/// De-hardcoded runner contract: runners declare `DEFAULT_TRACKER: "github"`,
/// `AI_AGENT_PROVIDER: "fa"`, and `FA_PROVIDERS_QUEUE` via `$ENV_VAR_DEV_QUEUE`
/// or `$ENV_VAR_REVIEW_QUEUE` (resolved at runtime via `PropertyReader` env
/// variable interpolation), without hardcoding `FA_PROVIDER_TYPE` or
/// `FA_PROVIDER_CONFIG`.
void faProviderPreconfigTests() {
  group('machine wiring: fa provider boot preconfig (fa.sh contract)', () {
    for (final runner in _runners) {
      _faBootPreconfigRunnerTests(runner);
    }
    _reviewQueueHeadPreconfigTests();
    _devQueueFallbackPreconfigTests();
    _queueEnvInterpolationTests();
  });
}

/// Per-runner boot pins: every runner sets `DEFAULT_TRACKER: "github"` and
/// `AI_AGENT_PROVIDER: "fa"`, and does NOT hardcode `FA_PROVIDER_TYPE` or
/// `FA_PROVIDER_CONFIG`.
void _faBootPreconfigRunnerTests(String runner) {
  final env =
      (_runnerJson('.dmtools/runners/$runner')['params'])['envVariables']
          as Map;

  test('$runner sets DEFAULT_TRACKER=github and AI_AGENT_PROVIDER=fa', () {
    expect(env['DEFAULT_TRACKER'], 'github');
    expect(env['AI_AGENT_PROVIDER'], 'fa');
  });

  test(
      '$runner does not hardcode FA_PROVIDER_TYPE or FA_PROVIDER_CONFIG '
      '(derived from FA_PROVIDERS_QUEUE at runtime)', () {
    expect(env.containsKey('FA_PROVIDER_TYPE'), isFalse);
    expect(env.containsKey('FA_PROVIDER_CONFIG'), isFalse);
    expect(env['FA_PROVIDERS_QUEUE'], allOf(isA<String>(), startsWith(r'$')));
  });
}

void _reviewQueueHeadPreconfigTests() {
  test('review runner sets FA_PROVIDERS_QUEUE to \$ENV_VAR_REVIEW_QUEUE', () {
    final env = (_runnerJson(
        '.dmtools/runners/fa-review.json')['params'])['envVariables'] as Map;
    expect(env['FA_PROVIDERS_QUEUE'], r'$ENV_VAR_REVIEW_QUEUE');
  });
}

void _devQueueFallbackPreconfigTests() {
  for (final runner in ['fa-bug-dev', 'fa-story-dev', 'fa-rework']) {
    test('$runner sets FA_PROVIDERS_QUEUE to \$ENV_VAR_DEV_QUEUE', () {
      final env = (_runnerJson(
          '.dmtools/runners/$runner.json')['params'])['envVariables'] as Map;
      expect(env['FA_PROVIDERS_QUEUE'], r'$ENV_VAR_DEV_QUEUE');
    });
  }
}

void _queueEnvInterpolationTests() {
  test(
      'PropertyReader.runWithOverrides resolves \$ENV_VAR_DEV_QUEUE and '
      '\$ENV_VAR_REVIEW_QUEUE failover queues from environment', () async {
    const devQueueJson = '[{"provider_type":"copilot","provider_config":'
        '{"model":"claude-haiku-5.5","apiKeyEnv":"COPILOT_EPAM_KEY"}},'
        '{"provider_type":"kimi","provider_config":{"apiKeyEnv":"KIMI_REVIEW_KEY"}},'
        '{"provider_type":"zai","provider_config":{"apiKeyEnv":"ZAI_CODE_KEY"}}]';
    const reviewQueueJson = '[{"provider_type":"copilot","provider_config":'
        '{"model":"claude-sonnet-5.5","apiKeyEnv":"COPILOT_EPAM_KEY"}},'
        '{"provider_type":"kimi","provider_config":{"apiKeyEnv":"KIMI_REVIEW_KEY"}},'
        '{"provider_type":"zai","provider_config":{"apiKeyEnv":"ZAI_CODE_KEY"}}]';
    final prevIsolation = PropertyReader.testIsolation;
    PropertyReader.testIsolation = true;
    PropertyReader.testEnvironment['ENV_VAR_DEV_QUEUE'] = devQueueJson;
    PropertyReader.testEnvironment['ENV_VAR_REVIEW_QUEUE'] = reviewQueueJson;
    try {
      final devEnv = (_runnerJson('.dmtools/runners/fa-bug-dev.json')['params']
              ['envVariables'] as Map)
          .cast<String, String>();
      await PropertyReader.runWithOverrides(devEnv, () async {
        final resolved = PropertyReader.getOverrides()['FA_PROVIDERS_QUEUE']!;
        final queue = (jsonDecode(resolved) as List).cast<Map>();
        expect(
          queue.map((e) => e['provider_type']).toList(),
          ['copilot', 'kimi', 'zai'],
        );
      });
      final reviewEnv =
          (_runnerJson('.dmtools/runners/fa-review.json')['params']
                  ['envVariables'] as Map)
              .cast<String, String>();
      await PropertyReader.runWithOverrides(reviewEnv, () async {
        final resolved = PropertyReader.getOverrides()['FA_PROVIDERS_QUEUE']!;
        final queue = (jsonDecode(resolved) as List).cast<Map>();
        expect(
          queue.map((e) => e['provider_type']).toList(),
          ['copilot', 'kimi', 'zai'],
        );
      });
    } finally {
      PropertyReader.testEnvironment.remove('ENV_VAR_DEV_QUEUE');
      PropertyReader.testEnvironment.remove('ENV_VAR_REVIEW_QUEUE');
      PropertyReader.testIsolation = prevIsolation;
    }
  });
}
