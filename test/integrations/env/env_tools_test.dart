import 'dart:convert';

import 'package:dmtools/src/config/property_names.dart';
import 'package:dmtools/src/env/js_env_policy.dart';
import 'package:dmtools/src/integrations/env/env_tools.dart';
import 'package:test/test.dart';

/// Java `EnvToolsTest` parity. Values come from an in-memory map; a lookup
/// counter proves refused and invalid names never reach the value source.
Map<String, String> _values = {};
List<String> _lookups = [];
late EnvTools _tools;

Map<String, dynamic> _get(String name) =>
    jsonDecode(_tools.envGet(name)) as Map<String, dynamic>;

void _resetHarness() {
  _values = {};
  _lookups = [];
  _tools = EnvTools(
    lookup: (key) {
      _lookups.add(key);
      return _values[key];
    },
  );
}

void main() {
  setUp(_resetHarness);
  _defineEnvGetTests();
  _defineEnvListAndCatalogTests();
  _defineCatalogTests();
}

void _defineEnvGetTests() {
  test('allowed name returns its value', () {
    _values['ADO_PROJECT'] = 'PROJ';
    expect(_get('ADO_PROJECT'), {'name': 'ADO_PROJECT', 'value': 'PROJ'});
  });

  test('lookup is case-insensitive', () {
    _values['ADO_PROJECT'] = 'PROJ';
    expect(_get('ado_project')['value'], 'PROJ');
  });

  test('unset allowed name answers value null', () {
    expect(_get('ADO_PROJECT'), {'name': 'ADO_PROJECT', 'value': null});
  });

  test('secret is refused without its value and without a secret lookup', () {
    _values['JIRA_API_TOKEN'] = 'REAL-SECRET';
    final out = _tools.envGet('JIRA_API_TOKEN');
    expect(out, isNot(contains('REAL-SECRET')));
    expect(_get('JIRA_API_TOKEN').containsKey('error'), isTrue);
    expect(_lookups, isNot(contains('JIRA_API_TOKEN')));
  });

  test('invalid names are rejected without a lookup', () {
    for (final bad in [null, '', '1X', 'A-B', 'A.B']) {
      final out = jsonDecode(_tools.envGet(bad)) as Map<String, dynamic>;
      expect(out['error'], contains('invalid name'), reason: '$bad');
    }
    // Only the allowlist key may be read for an invalid name, never the name.
    expect(_lookups.every((k) => k == JsEnvPolicy.allowlistKey), isTrue);
  });

  test('not-allowlisted name is refused', () {
    expect(_get('RANDOM_THING')['error'], contains('JS_ENV_ALLOWLIST'));
  });
}

void _defineEnvListAndCatalogTests() {
  test('JS_ENV_ALLOWLIST makes a custom name readable', () {
    _values[JsEnvPolicy.allowlistKey] = 'MY_CUSTOM';
    _values['MY_CUSTOM'] = 'hello';
    expect(_get('MY_CUSTOM')['value'], 'hello');
  });

  test('allowlisted secret-looking name stays refused', () {
    _values[JsEnvPolicy.allowlistKey] = 'JIRA_API_TOKEN';
    _values['JIRA_API_TOKEN'] = 'REAL-SECRET';
    expect(_tools.envGet('JIRA_API_TOKEN'), isNot(contains('REAL-SECRET')));
    expect(_get('JIRA_API_TOKEN').containsKey('error'), isTrue);
  });

  test(
      'worst case: every declared credential is never answered, '
      'even when allowlisted', () {
    final secrets = PropertyNames.all.where(JsEnvPolicy.looksSecret).toList();
    expect(secrets, isNotEmpty);
    final secretValues = {for (final s in secrets) s: 'SECRET-$s-VALUE'};
    _values.addAll(secretValues);
    _values[JsEnvPolicy.allowlistKey] = secrets.join(',');
    final sweep = StringBuffer();
    for (final s in secrets) {
      sweep.write(_tools.envGet(s));
    }
    sweep.write(_tools.envList());
    for (final value in secretValues.values) {
      expect(sweep.toString(), isNot(contains(value)));
    }
  });

  test('env_list returns names only, never _values', () {
    _values['ADO_PROJECT'] = 'VALUE-SHOULD-NOT-LEAK';
    _values['JIRA_API_TOKEN'] = 'TOKEN-SHOULD-NOT-LEAK';
    _values[JsEnvPolicy.allowlistKey] = 'MY_CUSTOM,JIRA_API_TOKEN';
    final out = _tools.envList();
    expect(out, isNot(contains('VALUE-SHOULD-NOT-LEAK')));
    expect(out, isNot(contains('TOKEN-SHOULD-NOT-LEAK')));
    final json = jsonDecode(out) as Map<String, dynamic>;
    final names = (json['names'] as List).cast<String>();
    expect(names, contains('ADO_PROJECT'));
    expect(names, contains('MY_CUSTOM'));
    expect(names, isNot(contains('JIRA_API_TOKEN')));
    expect(json['ignoredSecretLikeNames'], ['JIRA_API_TOKEN']);
  });

  test('env_list omits ignoredSecretLikeNames when nothing was rejected', () {
    final json = jsonDecode(_tools.envList()) as Map<String, dynamic>;
    expect(json.containsKey('ignoredSecretLikeNames'), isFalse);
  });
}

void _defineCatalogTests() {
  test('catalog exposes env_get and env_list in the env integration', () {
    final defs = envTools();
    expect(defs.map((d) => d.name), ['env_get', 'env_list']);
    expect(defs.every((d) => d.integration == 'env'), isTrue);
    expect(_tools.handlers.keys, ['env_get', 'env_list']);
  });

  test('handlers dispatch through the same contract', () {
    _values['ADO_PROJECT'] = 'PROJ';
    final out = _tools.handlers['env_get']!({'name': 'ADO_PROJECT'});
    expect(jsonDecode(out)['value'], 'PROJ');
    expect(jsonDecode(_tools.handlers['env_list']!({}))['names'], isNotEmpty);
  });
}
