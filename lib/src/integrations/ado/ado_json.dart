/// ADO response-envelope helpers shared by the async client and the sync
/// dispatcher.
///
/// ADO list endpoints never return bare arrays: paged endpoints wrap the
/// items as `{count, value: [...]}` and WIQL as
/// `{queryType, columns, workItems: [...]}`.
library;

/// Unwraps an ADO list envelope into typed maps.
///
/// Accepts a bare array, `{value: [...]}` or `{workItems: [...]}`;
/// returns an empty list for any other shape.
List<Map<String, dynamic>> unwrapAdoItems(dynamic decoded) {
  final List items;
  if (decoded is List) {
    items = decoded;
  } else if (decoded is Map && decoded['value'] is List) {
    items = decoded['value'] as List;
  } else if (decoded is Map && decoded['workItems'] is List) {
    items = decoded['workItems'] as List;
  } else {
    items = const [];
  }
  return items
      .whereType<Map>()
      .map((entry) => Map<String, dynamic>.from(entry))
      .toList();
}

/// Collects the integer work-item ids from a WIQL `workItems` stub list.
List<int> wiqlStubIds(List stubs) => [
      for (final stub in stubs)
        if (stub is Map && stub['id'] is int) stub['id'] as int,
    ];

/// Extracts work-item ids from any WIQL response (Java `extractWorkItemIds`).
///
/// Flat queries answer with `workItems` stubs, returned in order. Link
/// queries (`FROM WorkItemLinks`) answer with `workItemRelations`: each
/// relation's **target** is a result, while the anchoring source row (no
/// `rel`) is skipped. Duplicates are dropped, keeping first occurrence.
List<int> extractWorkItemIds(Map decoded) {
  final ids = <int>[];
  final seen = <int>{};
  void add(int id) {
    if (seen.add(id)) ids.add(id);
  }

  final flat = decoded['workItems'];
  if (flat is List) wiqlStubIds(flat).forEach(add);
  final relations = decoded['workItemRelations'];
  if (relations is List) {
    for (final relation in relations) {
      if (relation is! Map || relation['rel'] == null) continue;
      final target = relation['target'];
      if (target is Map && target['id'] is int) add(target['id'] as int);
    }
  }
  return ids;
}

/// Splits [ids] into batches of [size] — ADO caps `wit/workitems` at 200
/// ids per request (Java `searchAndPerform` batches the same way).
Iterable<List<int>> batchIds(List<int> ids, {int size = 200}) sync* {
  for (var start = 0; start < ids.length; start += size) {
    final end = start + size < ids.length ? start + size : ids.length;
    yield ids.sublist(start, end);
  }
}
