/// Integration test: the default registry wires every tool catalog together.
///
/// Guards the wiring contract of [createDefaultToolRegistry]: all 17
/// integration catalogs registered, no duplicate tool names, and a stable
/// total count that changes only when a catalog deliberately grows.
library;

import 'package:dmtools/dmtools.dart';
import 'package:test/test.dart';

late ToolRegistry _registry;

void main() {
  setUp(() => _registry = createDefaultToolRegistry());

  _testCatalogMembership();
  _testCounts();
  _testResponseShape();
}

void _testCatalogMembership() {
  group('catalog membership', () {
    test('registers every integration catalog', () {
      const expected = {
        'jira',
        'github',
        'gitlab',
        'confluence',
        'ai',
        'file',
        'cli',
        'env',
        'ado',
        'testrail',
        'bitrise',
        'jenkins',
        'figma',
        'teams',
        'sharepoint',
        'jira_xray',
        'kb',
        'mermaid',
      };
      expect(_registry.availableIntegrations.length, expected.length);
      expect(_registry.availableIntegrations, containsAll(expected));
    });

    test('every integration contributes at least one tool', () {
      for (final integration in _registry.availableIntegrations) {
        final tools = _registry.toolsForIntegrations({integration});
        expect(tools, isNotEmpty, reason: 'no tools for $integration');
      }
    });

    test('tool names are unique across catalogs', () {
      final names = _registry.allTools.map((t) => t.name).toList();
      expect(names.toSet().length, names.length);
    });

    test('allTools is sorted alphabetically by name', () {
      final names = _registry.allTools.map((t) => t.name).toList();
      expect(names, equals(names.toList()..sort()));
    });
  });
}

void _testCounts() {
  group('counts', () {
    test('has the expected total tool count', () {
      expect(_registry.allTools.length, greaterThan(250));
    });

    test('per-integration counts sum to the total', () {
      var sum = 0;
      for (final integration in _registry.availableIntegrations) {
        sum += _registry.toolsForIntegrations({integration}).length;
      }
      expect(sum, _registry.allTools.length);
    });
  });
}

void _testResponseShape() {
  test('tools list response matches the registry contents', () {
    final response = _registry.generateToolsListResponse();
    final tools = response['tools'] as List;
    expect(tools.length, _registry.allTools.length);
    final first = tools.first as Map<String, dynamic>;
    expect(first.containsKey('name'), isTrue);
    expect(first.containsKey('inputSchema'), isTrue);
  });
}
