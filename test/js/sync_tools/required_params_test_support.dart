import 'dart:convert';

import 'package:dmtools/src/config/property_reader.dart';
import 'package:test/test.dart';

/// Shared runner for required-parameter validation tests on sync tools.
typedef SyncToolHandler = String Function(Map<String, dynamic> args);

/// Runs [body] inside a suite with [emptyEnv] overrides cleared after each
/// test, passing a JSON-decoding `(tool, [args])` invoker and a raw string
/// invoker.
void withUnconfiguredSyncTools(
  Map<String, SyncToolHandler> handlers,
  Map<String, String> emptyEnv,
  void Function(
    Object? Function(String tool, [Map<String, dynamic> args]) callJson,
    String Function(String tool, [Map<String, dynamic> args]) callRaw,
  ) body,
) {
  setUp(() => PropertyReader.setOverrides(emptyEnv));
  tearDown(PropertyReader.clearOverrides);
  body(
    (tool, [args = const {}]) => jsonDecode(handlers[tool]!(args)),
    (tool, [args = const {}]) => handlers[tool]!(args),
  );
}

/// Builds the expected error payload for a missing required parameter.
Map<String, String> missingParamError(String param) =>
    {'error': "Required parameter '$param' is missing"};

/// Matcher asserting that a tool invocation did not fail required-parameter
/// validation.
Matcher get satisfiesRequiredParams => isNot(contains('Required parameter'));
