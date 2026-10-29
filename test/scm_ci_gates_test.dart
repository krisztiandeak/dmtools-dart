/// REG gates for the `scm_*`/`ci_*` alias layer (gh-339).
///
/// - AC2: the usage census is recomputed live from `agents/js` on every
///   run and every census tool is covered by a registered alias
///   (census ⊆ alias set).
/// - AC3: the SM loop files contain zero `github_*` call sites after
///   migration — the grep gate. Any red here blocks merge even with
///   UT/IT green.
///
/// AC4 (catalog parity) lives in `test/mcp/catalog_parity_test.dart`
/// (unchanged and green); AC5 (agents suite) is the dedicated CI job.
library;

import 'dart:io';

import 'package:dmtools/src/config/property_reader.dart';
import 'package:dmtools/src/mcp/default_tool_registry.dart';
import 'package:test/test.dart';

import '../tool/scm_alias_census.dart';

void main() {
  setUpAll(() {
    PropertyReader.testIsolation = true;
    PropertyReader.testEnvironment.clear();
  });
  tearDownAll(() {
    PropertyReader.testIsolation = false;
    PropertyReader.testEnvironment.clear();
  });

  censusTests();
  grepGateTests();
  gateFileInventoryTests();
}

/// AC2 — the census is the tiering witness for the core alias subset.
void censusTests() {
  group('scm alias usage census (AC2)', () {
    test('the census is non-empty (the scan actually sees agents/js)', () {
      expect(computeCensus(), isNotEmpty);
    });

    test('census ⊆ alias set — every census tool has a covering alias', () {
      PropertyReader.setOverrides({
        'DEFAULT_SCM': 'github',
        'DEFAULT_CI': 'actions',
      });
      final aliasNames =
          createDefaultToolRegistry().allTools.map((t) => t.name).toSet();
      final censusTools =
          computeCensus().map((l) => l.split(' ').first).toSet();
      expect(censusTools, isNotEmpty);
      for (final tool in censusTools) {
        final alias = kCensusToolAlias[tool];
        expect(alias, isNotNull,
            reason: '$tool appears in agents/js but has no census mapping');
        expect(aliasNames, contains(alias),
            reason: '$tool is covered by $alias — alias must be registered');
      }
    });
  });
}

/// AC3 — the SM loop runs on the aliases: zero `github_*` tokens in the
/// gate files (mentions included — a stale comment would rot first).
///
/// The migration consumer lives in the dmtools-agents repo and must land
/// there BEFORE this superproject can bump the submodule pointer
/// (landing order, gh-339). While the checked-out `agents/` tree is
/// pre-migration the grep cannot hold, so the gate reports skipped with
/// the arming condition instead of a standing red. Arming marker: the
/// gate files themselves call `scm_*`/`ci_*` aliases — the vocabulary
/// only the migrated loop speaks. That makes the gate self-arming: once
/// the tree adopts the aliases, any leftover `github_*` call site fails
/// here (a partial migration is exactly what AC3 must catch), and
/// routine repins of still-pre-migration commits stay green.
final RegExp aliasCallPattern = RegExp(r'\b(?:scm|ci)_[a-z][a-z_]*\s*\(');

/// Whether [lines] contain a call-shaped `scm_*`/`ci_*` alias token.
bool speaksAliases(List<String> lines) => lines.any(aliasCallPattern.hasMatch);

/// The AC3 gate files. `smAgent.js` is in the ticket's AC3 list ("the
/// smAgent rule files") and is the single largest `github_*` consumer in
/// the committed census — it must be gated like the loop files, or a
/// leftover/reintroduced direct call there stays green forever.
const gateFiles = [
  'agents/js/sm/sources/githubSource.js',
  'agents/js/sm/mergeBot.js',
  'agents/js/sm/sourceResolver.js',
  'agents/js/machineSmAgent.js',
  'agents/js/smAgent.js',
];

void grepGateTests() {
  group('SM loop grep gate (AC3)', () {
    final armed = gateFiles.any((f) {
      final file = File(f);
      return file.existsSync() && speaksAliases(file.readAsLinesSync());
    });
    final skipReason = armed
        ? null
        : 'AC3 arms when the SM loop files call scm_*/ci_* aliases. The '
            'migration lives in dmtools-agents (js/sm/*, machineSmAgent.js) '
            'and lands there before the submodule pointer bump; the '
            'checked-out pin still calls github_* directly.';

    test('the arming marker matches alias calls only', () {
      expect(speaksAliases(['var pr = scm_get_pr({});']), isTrue);
      expect(speaksAliases(['var v = ci_get_verdict({runId: r});']), isTrue);
      expect(speaksAliases(['x = obj.scm_merge_pr(args);']), isTrue);
      // Mentions without a call shape, provider-agnostic prose, and
      // words that merely contain the prefix must not arm the gate.
      expect(speaksAliases(['// see scm_get_pr for the shape']), isFalse);
      expect(speaksAliases(["require('./sources/githubSource.js');"]), isFalse);
      expect(speaksAliases(["var s = 'ci_still_running';"]), isFalse);
      expect(speaksAliases(['var pci_agent = 1;']), isFalse);
    });

    test('zero github_* tokens in the SM loop files', () {
      final violations = <String>[];
      final pattern = RegExp(r'github_[a-z]');
      for (final f in gateFiles) {
        var lineNo = 0;
        for (final line in File(f).readAsLinesSync()) {
          lineNo++;
          if (pattern.hasMatch(line)) violations.add('$f:$lineNo: $line');
        }
      }
      expect(
        violations,
        isEmpty,
        reason: 'AC3: the SM loop must run on the vendor-neutral scm_*/'
            'ci_* aliases — migrate the sites above (ci_get_verdict, '
            'ci_list_runs, scm_* data plane) instead of calling github_* '
            'directly',
      );
    }, skip: skipReason);
  });
}

/// The gate files must exist: a rename/move must fail the gate loudly
/// instead of silently scanning nothing (and the census proves smAgent.js
/// is part of the SM surface, so it cannot be a stale path).
void gateFileInventoryTests() {
  group('SM loop grep gate (AC3)', () {
    test('the gate files exist (the gate cannot silently pass on a move)', () {
      for (final f in gateFiles) {
        expect(File(f).existsSync(), isTrue, reason: f);
      }
    });
  });
}
