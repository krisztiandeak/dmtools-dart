import 'dart:convert';

import 'package:dmtools/src/integrations/ado/ado_json.dart';
import 'package:dmtools/dmtools.dart';
import 'package:test/test.dart';

import 'ado_test_support.dart';

/// WIQL id extraction for flat and link (`FROM WorkItemLinks`) queries
/// (Java `extractWorkItemIds` parity).
void main() {
  tearDown(PropertyReader.clearOverrides);

  group('extractWorkItemIds', () {
    _flatAndLinkShapes();
    _emptyShapes();
    _listWorkItemsOverLinkQuery();
  });
}

void _flatAndLinkShapes() {
  test('flat workItems keep response order', () {
    expect(
      extractWorkItemIds({
        'workItems': [
          {'id': 7},
          {'id': 3},
        ],
      }),
      [7, 3],
    );
  });

  test('link query returns targets and skips the anchoring source row', () {
    expect(
      extractWorkItemIds({
        'workItemRelations': [
          {
            'rel': null,
            'source': null,
            'target': {'id': 1},
          },
          {
            'rel': 'System.LinkTypes.Hierarchy-Forward',
            'source': {'id': 1},
            'target': {'id': 2},
          },
          {
            'rel': 'System.LinkTypes.Hierarchy-Forward',
            'source': {'id': 1},
            'target': {'id': 5},
          },
        ],
      }),
      [2, 5],
    );
  });

  test('drops duplicate ids, keeping first occurrence', () {
    expect(
      extractWorkItemIds({
        'workItemRelations': [
          {
            'rel': 'x',
            'target': {'id': 4},
          },
          {
            'rel': 'x',
            'target': {'id': 4},
          },
        ],
      }),
      [4],
    );
  });
}

void _emptyShapes() {
  test('empty and missing-target shapes yield no ids', () {
    expect(extractWorkItemIds({'workItemRelations': []}), isEmpty);
    expect(extractWorkItemIds({'workItems': []}), isEmpty);
    expect(extractWorkItemIds({}), isEmpty);
    expect(
      extractWorkItemIds({
        'workItemRelations': [
          {'rel': 'x'},
          {'rel': 'x', 'target': {}},
        ],
      }),
      isEmpty,
    );
  });
}

void _listWorkItemsOverLinkQuery() {
  test('listWorkItems over a link query fetches the child items', () async {
    final f = mockAdo((o) {
      if (o.path.endsWith('/wiql')) {
        return jsonEncode({
          'queryType': 'tree',
          'workItemRelations': [
            {
              'rel': null,
              'target': {'id': 10},
            },
            {
              'rel': 'x',
              'source': {'id': 10},
              'target': {'id': 11},
            },
          ],
        });
      }
      final ids = (o.queryParameters['ids'] as String).split(',');
      return jsonEncode({
        'count': ids.length,
        'value': [
          for (final id in ids) {'id': int.parse(id), 'fields': {}},
        ],
      });
    });
    final items = await f.client.listWorkItems(
      'SELECT [System.Id] FROM WorkItemLinks',
    );
    expect(items.map((i) => i['id']), [11]);
    expect(f.adapter.calls.last.queryParameters['ids'], '11');
  });
}
