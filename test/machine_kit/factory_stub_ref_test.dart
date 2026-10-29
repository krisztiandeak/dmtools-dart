/// Factory-stub ref guards for the machine loop (gh-146 review threads
/// 1, 2 and 7), reworked for the agents-by-version migration (owner
/// directive 2026-09-28) and again for the always-latest policy (owner
/// directive 2026-10-04).
///
/// Track-main model:
///
/// - Every stub (`machine-sm.yml`, `machine-merge.yml`, `merge-trigger.yml`,
///   `ai-teammate.yml`) calls its workflow in IstiN/dmtools-agentic-workflows
///   at the `main` branch ref — fixes in the factory home go live on merge,
///   with no re-pin ceremony per consumer (the 2026-10-04 kicker outages
///   (#13/#14) took ~1h to propagate through three manual re-pin PRs).
/// - Agent code and the dmtools CLI still resolve from RELEASES at run time
///   (vars.AGENTS_VERSION / vars.DMTOOLS_VERSION, 'latest' defaults).
///   2026-10-15: the `agents` submodule is removed — integration tests
///   fetch dmtools-agents MAIN via tool/fetch_agents.sh (no engine pin);
///   factory_ref is a plain literal (provenance only, the factory runs
///   from agents-rel-* releases).
/// - Trade-off accepted by the owner: awf main is load-bearing for all
///   factories; awf pushes stay review-gated.
///
/// The guards keep every awf `uses:` ref on `main` (never a stale SHA, never
/// a random branch/tag).
library;

import 'dart:io';

import 'package:test/test.dart';

/// The factory home all stubs track at the `main` branch ref.
const _agenticWorkflowsRef = 'main';

/// Stub → frozen-loop calls (agentic-workflows home).
const _frozenStubs = {
  '.github/workflows/machine-sm.yml': '.github/workflows/factory-sm.yml',
  '.github/workflows/machine-merge.yml': '.github/workflows/factory-merge.yml',
};

/// The historical teammate call: inside the agents submodule pin.
const _teammateStub = '.github/workflows/ai-teammate.yml';
const _mergeTriggerStub = '.github/workflows/merge-trigger.yml';
const _teammateFactoryPath = '.github/workflows/factory-teammate.yml';

final _agenticUsesRe = RegExp(
  r'uses:\s*IstiN/dmtools-agentic-workflows/(\S+)@(\S+)',
);

void main() {
  group('frozen machine-loop stubs (machine-sm / machine-merge)', () {
    _frozenPinUsesSha();
    _frozenNoFactoryRef();
    _frozenSecretsMapped();
    _frozenStatePublishBranch();
  });
  group('merge-trigger stub (factory home: dmtools-agentic-workflows)', () {
    _mergeTriggerPin();
  });
  group('teammate stub (factory home: dmtools-agentic-workflows)', () {
    _teammateLockstepPin();
    _teammateFactoryExists();
    _teammateSecretsMapped();
  });
}

/// Both machine-loop stubs track the factory home at the `main` ref.
void _frozenPinUsesSha() {
  test('pin uses: to the agentic-workflows main ref (always-latest)', () {
    expect(
      _agenticWorkflowsRef,
      'main',
      reason: 'always-latest policy: the factory home is tracked at main',
    );
    for (final entry in _frozenStubs.entries) {
      final yml = File(entry.key).readAsStringSync();
      final match = _agenticUsesRe.firstMatch(yml);
      expect(
        match,
        isNotNull,
        reason: '${entry.key} must call dmtools-agentic-workflows',
      );
      expect(
        match!.group(1),
        entry.value,
        reason: '${entry.key} must call the documented factory path',
      );
      expect(
        match.group(2),
        _agenticWorkflowsRef,
        reason: '${entry.key} must track the factory home at main '
            '(got ${match.group(2)}) — never a stale SHA or random ref '
            '(owner directive 2026-10-04)',
      );
    }
  });
}

/// The frozen loop declares no factory_ref — agents resolve from releases.
void _frozenNoFactoryRef() {
  test('no factory_ref input — agents resolve from releases by vars', () {
    for (final entry in _frozenStubs.keys) {
      final yml = File(entry).readAsStringSync();
      expect(
        yml.contains('factory_ref'),
        isFalse,
        reason: '$entry: the frozen loop declares no factory_ref — '
            'agent code resolves from the dmtools-agents release '
            'selected by vars.AGENTS_VERSION at run time',
      );
    }
  });
}

/// The mapped secret set must EQUAL the frozen loop's declared set.
void _frozenSecretsMapped() {
  test('secrets are explicitly mapped (inherit fails required check)', () {
    // The frozen loop declares SOURCE_GITHUB_TOKEN as REQUIRED plus
    // optional SILENT_GH_TOKEN (only factory-sm declares the latter;
    // factory-merge declares SOURCE_GITHUB_TOKEN only). Mapping an
    // UNDECLARED secret is rejected at call time, a missing REQUIRED
    // one fails validation (live bisect: inherit => startup failure,
    // run 35275493724).
    const declared = {
      '.github/workflows/machine-sm.yml': {
        'SOURCE_GITHUB_TOKEN',
        'SILENT_GH_TOKEN',
      },
      '.github/workflows/machine-merge.yml': {'SOURCE_GITHUB_TOKEN'},
    };
    for (final entry in declared.entries) {
      final yml = File(entry.key).readAsStringSync();
      final activeInherit =
          yml.split('\n').any((l) => l.trim() == 'secrets: inherit');
      expect(
        activeInherit,
        isFalse,
        reason: '${entry.key}: an ACTIVE `secrets: inherit` does not '
            'satisfy the REQUIRED named secret (live bisect run '
            '35275493724)',
      );
      final mapped = _mappedSecrets(yml);
      expect(
        mapped,
        entry.value,
        reason: '${entry.key} maps {${mapped.join(', ')}} but the '
            'frozen loop declares {${entry.value.join(', ')}}',
      );
    }
  });
}

/// machine-sm.yml must publish state to the `factory-data` branch (never
/// `factory-state`, which PR #321 accidentally reverted after PR #322).
void _frozenStatePublishBranch() {
  test(
      'machine-sm state-publish targets factory-data branch with dart-state.json',
      () {
    final yml = File('.github/workflows/machine-sm.yml').readAsStringSync();
    expect(
      yml,
      contains(
        'state-publish: \'{"channel":"release","tag":"factory-data","asset":"dart-state.json"}\'',
      ),
      reason: 'machine-sm.yml must publish dart-state.json to factory-data '
          '(where fa-tokens.json and the board read from)',
    );
    expect(
      yml.contains('"factory-state"'),
      isFalse,
      reason:
          'machine-sm.yml must never revert state-publish tag to factory-state',
    );
  });
}

/// merge-trigger.yml is the fourth called-workflow stub: it must track the
/// AW factory-merge-trigger at the `main` ref (always-latest policy).
void _mergeTriggerPin() {
  test('pins uses: to the AW factory-merge-trigger at the main ref', () {
    final yml = File(_mergeTriggerStub).readAsStringSync();
    final match = _agenticUsesRe.firstMatch(yml);
    expect(match, isNotNull,
        reason: '$_mergeTriggerStub must call dmtools-agentic-workflows');
    expect(
      match!.group(1),
      '.github/workflows/factory-merge-trigger.yml',
      reason: '$_mergeTriggerStub must call factory-merge-trigger.yml',
    );
    expect(
      match.group(2),
      _agenticWorkflowsRef,
      reason: 'the merge-trigger home must track main '
          '(got ${match.group(2)}) — always-latest (owner 2026-10-04)',
    );
  });
}

/// ai-teammate pins uses: to the factory home (dmtools-agentic-workflows,
/// immutable SHA) AND passes a factory_ref (the engine ref) — the factory
/// cannot see its own uses: ref, so the stub hands it the ref explicitly.
/// 2026-10-15: the agents submodule is GONE — the integration surface
/// fetches dmtools-agents from main (tool/fetch_agents.sh), and factory_ref
/// is a plain literal (provenance for the factory's FACTORY_REF env; the
/// factory resolves the engine from agents-rel-* releases, never a tree
/// checkout — owner mandate 2026-10-03), so there is no lockstep duty left
/// to enforce here.
void _teammateLockstepPin() {
  test('pins uses: to the factory home SHA + passes a factory_ref literal', () {
    final yml = File(_teammateStub).readAsStringSync();
    final match = _agenticUsesRe.firstMatch(yml);
    expect(match, isNotNull,
        reason: '$_teammateStub must call dmtools-agentic-workflows');
    expect(
      match!.group(1),
      _teammateFactoryPath,
      reason: '$_teammateStub must call factory-teammate.yml',
    );
    expect(
      match.group(2),
      _agenticWorkflowsRef,
      reason: 'the factory home must track main '
          '(got ${match.group(2)}) — always-latest (owner 2026-10-04)',
    );
    // factory_ref is GONE (awf#39 deprecated the input 2026-10-16): it was
    // the agents-submodule lockstep relic, read by nothing since dart#412.
    // The contract flips — the stub must NOT pass it anymore.
    expect(
      RegExp(r'^\s*factory_ref:', multiLine: true).hasMatch(yml),
      isFalse,
      reason: '$_teammateStub must not pass factory_ref — deprecated '
          'provenance relic (awf#39); the engine rides agents-rel releases',
    );
  });
}

/// The factory workflow lives in dmtools-agentic-workflows now — the
/// engine repo (agents/ submodule) must NOT carry a factory copy.
/// SKIPPED until dmtools-agents#591 (retire legacy copies) merges and
/// this stub's submodule bump lands past it.
void _teammateFactoryExists() {
  test('the fetched agents tree carries no factory-teammate copy', () {
    expect(
      File('agents/$_teammateFactoryPath').existsSync(),
      isFalse,
      reason: 'factory workflows moved to dmtools-agentic-workflows — '
          'a copy under agents/ would be an unmanaged legacy route',
    );
  });
}

/// The teammate stub maps exactly the secrets factory-teammate.yml declares.
void _teammateSecretsMapped() {
  test('secrets are explicitly mapped', () {
    final yml = File(_teammateStub).readAsStringSync();
    final activeInherit =
        yml.split('\n').any((l) => l.trim() == 'secrets: inherit');
    expect(activeInherit, isFalse, reason: 'explicit mapping required');
    final declared = _declaredTeammateSecrets();
    final mapped = _mappedSecrets(yml);
    expect(
      mapped,
      declared,
      reason: '$_teammateStub maps {${mapped.join(', ')}} but the '
          'factory declares {${declared.join(', ')}}',
    );
  });
}

/// The secret names mapped in a stub's `secrets:` block (6-space entries).
Set<String> _mappedSecrets(String yml) {
  final secretsBlock = yml.split('secrets:').last.split('jobs:').first;
  return RegExp(
    r'^\s{6}([A-Z_]+):',
    multiLine: true,
  ).allMatches(secretsBlock).map((m) => m.group(1)!).toSet();
}

/// The `secrets:` names the factory-teammate.yml declares. The workflow
/// lives in dmtools-agentic-workflows now (nothing in-tree to parse).
/// MANUAL LOCKSTEP DUTY: when factory-teammate.yml at the pinned AW SHA
/// declares/renames a secret, update BOTH this literal AND the mapping
/// in ai-teammate.yml — otherwise the workflow call fails at startup
/// ("required secret not mapped") while this test keeps passing stale.
Set<String> _declaredTeammateSecrets() {
  return {
    'SOURCE_GITHUB_TOKEN',
    'ZAI_CODE_KEY',
    'KIMI_REVIEW_KEY',
    'ENV_VAR_DEV_QUEUE',
    'ENV_VAR_REVIEW_QUEUE',
  };
}
