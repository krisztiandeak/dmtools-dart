/// Machine wiring tests for gh-125 — machine comments on GitHub issues must
/// be GitHub-flavored Markdown, not Jira wiki markup.
///
/// gh-122 posted `{code}` blocks and `h3.` headers to a GitHub issue because:
/// 1. no `github` entry existed in any `cliPromptsByTracker` map, and
/// 2. the dev/rework runners never engaged the mechanism at all.
///
/// These tests pin both halves: the Markdown format instruction file must
/// exist and prescribe GitHub-native constructs (fenced code blocks, `#`
/// headings, `[text](url)` links, GFM tables) while banning Jira prefixes,
/// and the dev + rework runners must select it via
/// `params.cliPromptsByTracker.github` with `DEFAULT_TRACKER=github` pinned
/// so the CliAgent's tracker lookup resolves the `github` key.
///
/// The runners live in `.dmtools/runners/` (selected per leg by the factory
/// guard via `.dmtools/config.js` sm.runners). Their `parent` and prompt
/// paths resolve at run time against the factory checkout
/// (`factory-agents/` — dmtools-agents cloned beside the target repo),
/// which does not exist in this repository: runner-level wiring is pinned
/// on the raw JSON here, the parent side on the same content in the pinned
/// `agents/` submodule.
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  formatFileTests();
  devRunnerWiringTests();
  reworkRunnerWiringTests();
  defaultTrackerWiringTests();
}

/// The format instruction exactly as the runners reference it — a `pack:`
/// ref resolved against the unpacked parent pack at run time.
const _runnerFormatPath = 'pack:instructions/common/github_comment_format.md';

/// In-repo location of the same instruction (agents/ submodule, pinned).
const _formatFile = 'agents/instructions/common/github_comment_format.md';

/// Runners whose comments land on GitHub issues (dev + rework; the review
/// runner posts structured PR-review output and stays upstream-scoped).
const _githubRunners = [
  '.dmtools/runners/fa-bug-dev.json',
  '.dmtools/runners/fa-story-dev.json',
  '.dmtools/runners/fa-rework.json',
];

/// Decodes a runner config as committed (no parent resolution — see the
/// library doc comment).
Map<String, dynamic> _runner(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

void formatFileTests() {
  test('github_comment_format.md exists and prescribes Markdown', () {
    final file = File(_formatFile);
    expect(file.existsSync(), isTrue, reason: '$_formatFile is missing');
    final content = file.readAsStringSync();
    // Prescribes the GitHub-native constructs the comments must use.
    expect(content, contains('```'), reason: 'fenced code blocks');
    expect(content, contains('##'), reason: 'ATX headings');
    expect(content, contains('[text](url)'), reason: 'inline links');
    expect(content, contains('|---|'), reason: 'GFM tables');
    // Bans the Jira wiki markup that leaked into gh-122's comment.
    expect(content, contains('{code}'), reason: 'bans {code} blocks');
    expect(content, contains('{panel}'), reason: 'bans {panel} macros');
    expect(content, contains('h3.'), reason: 'bans h1./h2./h3. prefixes');
  });
}

void devRunnerWiringTests() {
  for (final runner in _githubRunners) {
    test('$runner selects the github tracker prompts', () {
      final params = _runner(runner)['params'] as Map;
      final byTracker = params['cliPromptsByTracker'];
      expect(byTracker, isA<Map>(),
          reason: 'cliPromptsByTracker missing — the Jira-markup bug '
              '(gh-122) comes back');
      final github = (byTracker['github'] as List?)?.cast<String>();
      expect(github, isNotNull,
          reason: 'no "github" key — the format rules never engage');
      expect(github, contains(_runnerFormatPath));
    });
  }

  test(
      'parents keep base cliPrompts tracker-agnostic (tracker format lives in cliPromptsByTracker)',
      () {
    for (final parent in const [
      'agents/bug_development.json',
      'agents/story_development.json',
      'agents/pr_rework.json',
    ]) {
      final json = jsonDecode(File(parent).readAsStringSync()) as Map;
      final params = json['params'] as Map?;
      final basePrompts = (params?['cliPrompts'] as List?) ?? const [];
      expect(
        basePrompts.whereType<String>().any((p) =>
            p.contains('jira_comment_format.md') ||
            p.contains('ado_comment_format.md') ||
            p.contains('github_comment_format.md')),
        isFalse,
        reason: '$parent base cliPrompts must stay tracker-agnostic',
      );
      final byTracker = params?['cliPromptsByTracker'] as Map?;
      if (byTracker != null) {
        expect(
          byTracker['github'],
          contains('./agents/instructions/common/github_comment_format.md'),
          reason:
              '$parent cliPromptsByTracker.github must wire github_comment_format.md',
        );
      }
    }
  });
}

void reworkRunnerWiringTests() {
  test('rework runner pins its pack parent (registry ref sanity)', () {
    final runner = _runner('.dmtools/runners/fa-rework.json');
    expect(
      (runner['parent'] as Map)['path'],
      'pr_rework@latest',
      reason: 'the rework runner extends the pr_rework agent pack — the '
          'parent chain resolves from the release registry at run time',
    );
    final params = runner['params'] as Map;
    expect(
      (params['envVariables'] as Map)['AI_AGENT_PROVIDER'],
      'fa',
    );
  });
}

void defaultTrackerWiringTests() {
  for (final runner in _githubRunners) {
    test('$runner pins DEFAULT_TRACKER=github (the active tracker)', () {
      final params = _runner(runner)['params'] as Map;
      final env = params['envVariables'] as Map;
      expect(env['DEFAULT_TRACKER'], 'github',
          reason: 'CliCommandBuilder resolves tracker prompts via '
              'DEFAULT_TRACKER (Java: configuration.getDefaultTracker()) — '
              'without the pin it falls back to "ado" and the github key '
              'never engages');
    });
  }
}
