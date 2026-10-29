/// Phase 3 "CI comparison green" gate — Dart vs. Java MCP tool catalog.
///
/// Compares the Dart catalog from [createDefaultToolRegistry] against the Java
/// reference catalog extracted from the `@MCPTool` annotations in
/// `dm.ai/dmtools-core` (see `test/fixtures/java_mcp_tool_names.txt`). Every
/// Java tool must be accounted for by one of:
///
/// 1. an **exact** name match in the Dart registry, or
/// 2. a **documented naming-convention equivalent** (see below), or
/// 3. an entry in the **frozen gap snapshot** (`java_mcp_tool_gaps.txt`).
///
/// Tool **parameter names** get the same treatment (gh-123: a param renamed on
/// one side only — Java `statusName` vs Dart `status` — was invisible to a
/// name-only comparison):
///
/// - `java_mcp_tool_params.txt` — exact-name matches whose parameter names
///   match Java; parity is enforced per line.
/// - `java_mcp_param_drift.txt` — exact-name matches whose parameter names
///   still diverge (the param-side counterpart of the gap snapshot); each
///   listed tool must still diverge.
/// - Every exact-name match from the names fixture must appear in exactly one
///   of the two files, so newly ported tools cannot skip classification.
///
/// Regenerate both files from a fresh Java checkout with
/// `python3 scripts/extract_java_tool_params.py <tools-raw.json>`.
///
/// The documented naming conventions the Dart port deliberately diverges on:
///
/// - **AI**: Dart exposes both the unified `ai_chat` family and the
///   per-provider tools Java has (`openai_ai_chat`, `gemini_ai_chat`,
///   `anthropic_ai_chat`, …) — those match exactly. Remaining Java AI
///   variants (`*_ai_chat_with_files`, `*_list_models`,
///   `vertex_ai_gemini_chat`) map onto `ai_chat_with_history` /
///   `ai_list_models`.
/// - **Teams**: Java exposes `teams_*_raw` variants that return unprocessed
///   Graph JSON. Dart drops the `_raw` suffix when the consolidated tool covers
///   the same shape.
///
/// The snapshot test stays green while the gap is unchanged. Port a Java tool
/// and it turns red, prompting the gap to shrink; re-extract the fixture from a
/// newer Java build and it turns red if new unported tools appear.
library;

import 'dart:io';

import 'package:dmtools/dmtools.dart';
import 'package:test/test.dart';

void main() {
  final javaNames = _readFixture('java_mcp_tool_names.txt');
  final dartTools = createDefaultToolRegistry().allTools;
  final dartNames = dartTools.map((t) => t.name).toSet();
  final frozenGaps = _readFixture('java_mcp_tool_gaps.txt');

  fixtureSanityTests(javaNames, dartNames);
  paritySnapshotTests(javaNames, dartNames, frozenGaps);
  equivalentMappingTests(javaNames, dartNames);
  parameterParityTests(dartTools);
  createLabelsSchemaTests(dartTools);
}

/// Asserts the fixture files are well-formed and in sync.
void fixtureSanityTests(List<String> javaNames, Set<String> dartNames) {
  group('fixture sanity', () {
    test('Java fixture lists unique snake_case tool names', () {
      expect(javaNames, isNotEmpty);
      expect(javaNames.toSet().length, javaNames.length, reason: 'duplicates');
      for (final n in javaNames) {
        expect(_snakeCase.hasMatch(n), isTrue, reason: 'bad name: $n');
      }
    });

    test('Dart registry is non-empty', () {
      expect(dartNames, isNotEmpty);
    });
  });
}

/// The core gate: the computed parity gap must match the frozen snapshot.
void paritySnapshotTests(
  List<String> javaNames,
  Set<String> dartNames,
  List<String> frozenGaps,
) {
  group('catalog parity snapshot', () {
    test('computed gap equals the frozen snapshot', () {
      final computed = _computeGaps(javaNames, dartNames);
      expect(
        computed,
        unorderedEquals(frozenGaps.toSet()),
        reason: 'The Java↔Dart tool gap changed. Port a tool and shrink\n'
            'test/fixtures/java_mcp_tool_gaps.txt, or re-extract\n'
            'test/fixtures/java_mcp_tool_names.txt from the latest Java build.',
      );
    });

    test('no frozen gap is also a registered Dart tool (snapshot is fresh)',
        () {
      final stale = frozenGaps.where(dartNames.contains).toSet();
      expect(
        stale,
        isEmpty,
        reason: 'Tools now exist in Dart — remove them from the gap '
            'snapshot: $stale',
      );
    });
  });
}

/// The documented naming-convention equivalents must resolve to real Dart tools.
void equivalentMappingTests(List<String> javaNames, Set<String> dartNames) {
  group('documented equivalents', () {
    test('every documented equivalent resolves to a registered tool', () {
      for (final j in javaNames) {
        final equiv = _dartEquivalentFor(j, dartNames);
        if (equiv != null) {
          expect(
            dartNames,
            contains(equiv),
            reason: '$j maps to unregistered $equiv',
          );
        }
      }
    });
  });
}

/// Parses a `tool:param1,param2,...` fixture line (trailing colon = no params).
MapEntry<String, List<String>> _parseParamLine(String line) {
  final sep = line.indexOf(':');
  if (sep < 0) throw FormatException('bad param fixture line: "$line"');
  final name = line.substring(0, sep);
  final rest = line.substring(sep + 1);
  return MapEntry(
    name,
    rest.isEmpty ? const <String>[] : rest.split(','),
  );
}

/// Parameter-name parity for exact-name matches (gh-123 drift guard).
///
/// `java_mcp_tool_params.txt` enforces parity; `java_mcp_param_drift.txt`
/// freezes the tools that still diverge (they must keep diverging until fixed
/// and moved to the params fixture by a re-extraction).
void parameterParityTests(List<ToolDefinition> dartTools) {
  final dartToolsByName = {for (final t in dartTools) t.name: t};
  final parity = _readParamFixture('java_mcp_tool_params.txt');
  final drift = _readParamFixture('java_mcp_param_drift.txt');
  final dartNames = dartToolsByName.keys.toSet();

  group('parameter-name parity', () {
    test('fixture params match the Dart registry', () {
      for (final entry in parity.entries) {
        final tool = dartToolsByName[entry.key];
        expect(tool, isNotNull, reason: '${entry.key} missing from Dart');
        expect(
          tool!.params.map((p) => p.name).toList()..sort(),
          entry.value.toList()..sort(),
          reason: '${entry.key} parameter names diverge from Java; re-run '
              'scripts/extract_java_tool_params.py after fixing',
        );
      }
    });

    test('every frozen drift still diverges (snapshot is fresh)', () {
      final fixed = <String>[];
      for (final entry in drift.entries) {
        final tool = dartToolsByName[entry.key];
        if (tool == null) continue;
        final dartParams = tool.params.map((p) => p.name).toList()..sort();
        if (_listEquals(dartParams, entry.value.toList()..sort())) {
          fixed.add(entry.key);
        }
      }
      expect(
        fixed,
        isEmpty,
        reason: 'Parameter names now match Java — move these tools from '
            'java_mcp_param_drift.txt to java_mcp_tool_params.txt via '
            'scripts/extract_java_tool_params.py: $fixed',
      );
    });

    test('every exact-name match is classified (parity or frozen drift)', () {
      final classified = {...parity.keys, ...drift.keys};
      final unclassified = dartNames
          .where((n) => _javaNameFixture.contains(n) && !classified.contains(n))
          .toSet();
      expect(
        unclassified,
        isEmpty,
        reason: 'Newly ported tools must be classified by '
            'scripts/extract_java_tool_params.py: $unclassified',
      );
    });

    test('parity and drift fixtures do not overlap', () {
      expect(
        parity.keys.toSet().intersection(drift.keys.toSet()),
        isEmpty,
      );
    });
  });
}

/// gh-427 AC4/IT-3: the create tools advertise an optional `labels` param.
///
/// `jira_create_ticket_with_json` keeps its two-param shape — labels there is
/// a `fieldsJson` member, never a top-level argument (E5).
void createLabelsSchemaTests(List<ToolDefinition> dartTools) {
  group('create-tool labels schema', () {
    final byName = {for (final t in dartTools) t.name: t};

    test('both convenience create tools advertise optional labels', () {
      for (final name in [
        'jira_create_ticket_basic',
        'jira_create_ticket_with_parent',
      ]) {
        final param =
            byName[name]!.params.singleWhere((p) => p.name == 'labels');
        expect(param.required, isFalse, reason: name);
        expect(param.type, 'array', reason: name);
      }
    });

    test('with_json does not advertise a top-level labels param', () {
      final names =
          byName['jira_create_ticket_with_json']!.params.map((p) => p.name);
      expect(names, ['project', 'fieldsJson']);
    });
  });
}

/// The Java tool names fixture, used to detect unclassified exact matches.
final _javaNameFixture = _readFixture('java_mcp_tool_names.txt').toSet();

/// Reads a `tool:param1,param2,...` fixture into an ordered map.
Map<String, List<String>> _readParamFixture(String name) {
  final map = <String, List<String>>{};
  for (final line in _readFixture(name)) {
    final entry = _parseParamLine(line);
    map[entry.key] = entry.value;
  }
  return map;
}

bool _listEquals(List<String> a, List<String> b) =>
    a.length == b.length && a.indexed.every((e) => b[e.$1] == e.$2);

/// Reads a newline-delimited fixture under `test/fixtures`, sorted, no
/// blanks; `#` comment lines carry divergence notes and are skipped.
List<String> _readFixture(String name) {
  final lines = File('test/fixtures/$name')
      .readAsLinesSync()
      .where((l) => l.trim().isNotEmpty && !l.trim().startsWith('#'))
      .toList()
    ..sort();
  return lines;
}

/// Computes the Java tools with no exact Dart match and no documented
/// equivalent — the genuine not-yet-ported gap.
Set<String> _computeGaps(List<String> javaNames, Set<String> dartNames) {
  final gaps = <String>{};
  for (final j in javaNames) {
    if (dartNames.contains(j)) continue;
    final equiv = _dartEquivalentFor(j, dartNames);
    if (equiv == null || !dartNames.contains(equiv)) gaps.add(j);
  }
  return gaps;
}

/// Resolves a Java tool name to its Dart equivalent under the documented
/// naming conventions, or `null` when there is no documented mapping.
String? _dartEquivalentFor(String javaName, Set<String> dartNames) =>
    _aiEquivalent(javaName) ?? _teamsRawEquivalent(javaName, dartNames);

/// Maps Java per-provider AI tools onto Dart's unified `ai_*` family.
String? _aiEquivalent(String javaName) {
  if (javaName == 'vertex_ai_gemini_chat') return 'ai_chat';
  if (javaName == 'vertex_ai_gemini_chat_with_files') {
    return 'ai_chat_with_history';
  }
  for (final p in _aiProviders) {
    if (javaName == '${p}_ai_chat') return 'ai_chat';
    if (javaName == '${p}_ai_chat_with_files') return 'ai_chat_with_history';
    if (javaName == '${p}_list_models') return 'ai_list_models';
  }
  return null;
}

/// Maps Java `teams_*_raw` tools to their `_raw`-stripped Dart counterpart.
String? _teamsRawEquivalent(String javaName, Set<String> dartNames) {
  if (!javaName.endsWith('_raw')) return null;
  final stripped = javaName.substring(0, javaName.length - 4);
  return dartNames.contains(stripped) ? stripped : null;
}

/// Java AI integrations whose remaining variant tools Dart collapses into the
/// unified catalog (the per-provider `*_ai_chat` tools match exactly).
const _aiProviders = [
  'openai',
  'gemini',
  'anthropic',
  'ollama',
  'dial',
  'bedrock',
];

/// snake_case identifier pattern used by every MCP tool name.
final RegExp _snakeCase = RegExp(r'^[a-z][a-z0-9_]*$');
