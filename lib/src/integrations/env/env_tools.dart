/// `env_get` / `env_list` — read-only access to NON-SECRET configuration for
/// JS agents. Dart port of Java `com.github.istin.dmtools.env.EnvTools`.
///
/// The policy lives in [JsEnvPolicy]; this file only applies it. Both tools
/// answer with a JSON string. A refusal never contains the value.
library;

import 'dart:convert';

import '../../config/property_reader.dart';
import '../../env/js_env_policy.dart';
import '../../mcp/tool_definition.dart';
import '../../mcp/tool_param.dart';

/// Returns the `env` integration tool definitions.
List<ToolDefinition> envTools() => const [
      ToolDefinition(
        name: 'env_get',
        description:
            'Read one non-secret configuration value (for example ADO_PROJECT, '
            'DEFAULT_TRACKER, JIRA_BASE_PATH). Credentials (names containing '
            'TOKEN, KEY, SECRET, PASSWORD, PAT, AUTH, ...) are never returned. '
            'Names outside the built-in list can be allowed with '
            'JS_ENV_ALLOWLIST=NAME1,NAME2. Returns {"name":..,"value":..} or '
            '{"name":..,"error":..}; value is null when the variable is unset.',
        integration: 'env',
        category: 'configuration',
        params: [
          ToolParam(name: 'name', description: 'Configuration variable name'),
        ],
      ),
      ToolDefinition(
        name: 'env_list',
        description:
            'List the configuration names env_get will answer for: the built-in '
            'non-secret names plus those added through JS_ENV_ALLOWLIST. Names '
            'only, never values.',
        integration: 'env',
        category: 'configuration',
      ),
    ];

/// Reads configuration values for the `env_*` tools.
///
/// [lookup] supplies values; production uses [PropertyReader.getValue], tests
/// inject a map-backed function. The lookup is called for [JsEnvPolicy.allowlistKey]
/// and for allowed names only — never for secrets or invalid names.
class EnvTools {
  /// Value source (Java `EnvTools` test seam).
  final String? Function(String key) lookup;

  /// Creates the tools over [lookup].
  EnvTools({String? Function(String key)? lookup})
      : lookup = lookup ?? ((key) => PropertyReader().getValue(key));

  /// Sync handlers keyed by tool name, JSON-string results.
  Map<String, String Function(Map<String, dynamic> args)> get handlers => {
        'env_get': (args) => envGet(args['name']?.toString()),
        'env_list': (_) => envList(),
      };

  /// `env_get {name}` — see the tool description for the contract.
  String envGet(String? name) {
    final decision = JsEnvPolicy.decide(name, lookup(JsEnvPolicy.allowlistKey));
    final out = <String, dynamic>{'name': name};
    switch (decision) {
      case EnvDecision.allowed:
        final value = lookup(name!.toUpperCase());
        out['value'] = (value == null || value.isEmpty) ? null : value;
      case EnvDecision.secret:
        out['error'] = 'not readable: the name looks like a credential';
      case EnvDecision.notAllowlisted:
        out['error'] =
            'not allowed: add it to JS_ENV_ALLOWLIST to make it readable';
      case EnvDecision.invalidName:
        out['error'] = 'invalid name: expected letters, digits and underscores';
    }
    return jsonEncode(out);
  }

  /// `env_list {}` — names only, plus `ignoredSecretLikeNames` when the
  /// allowlist contains credential-looking entries.
  String envList() {
    final raw = lookup(JsEnvPolicy.allowlistKey);
    final all = {
      ...JsEnvPolicy.defaultAllowed,
      ...JsEnvPolicy.projectAllowed(raw),
    }.toList()
      ..sort();
    final out = <String, dynamic>{'names': all};
    final rejected = JsEnvPolicy.rejectedFromAllowlist(raw).toList()..sort();
    if (rejected.isNotEmpty) out['ignoredSecretLikeNames'] = rejected;
    return jsonEncode(out);
  }
}
