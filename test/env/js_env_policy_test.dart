import 'package:dmtools/src/config/property_names.dart';
import 'package:dmtools/src/env/js_env_policy.dart';
import 'package:test/test.dart';

/// Java `JsEnvPolicyTest` parity: one secret-aware policy for env_get/env_list.
void main() {
  _defineLooksSecretTests();
  _defineDefaultAllowedTests();
  _defineAllowlistTests();
}

void _defineLooksSecretTests() {
  group('looksSecret', () {
    test('credential names are secret', () {
      for (final name in [
        'JIRA_API_TOKEN',
        'ADO_PAT_TOKEN',
        'GH_TOKEN',
        'SOURCE_GITHUB_TOKEN',
        'OPENAI_API_KEY',
        'XRAY_CLIENT_SECRET',
        'JIRA_LOGIN_PASS_TOKEN',
        'AWS_BEARER_TOKEN_BEDROCK',
        'BEDROCK_SESSION_TOKEN',
        'CONFLUENCE_LOGIN_PASS_TOKEN',
        'DB_PASSWORD',
        'MY_APIKEY',
        'SESSION_COOKIE',
        'PRIVATE_KEY',
        'JSAI_SECRETS_KEYS',
      ]) {
        expect(JsEnvPolicy.looksSecret(name), isTrue, reason: name);
      }
    });

    test('limits that contain TOKEN are configuration, not secrets', () {
      expect(JsEnvPolicy.looksSecret('OPENAI_MAX_TOKENS'), isFalse);
      expect(JsEnvPolicy.looksSecret('PROMPT_CHUNK_TOKEN_LIMIT'), isFalse);
      expect(JsEnvPolicy.looksSecret('ANTHROPIC_MAX_TOKENS'), isFalse);
    });

    test('token-shaped credentials are never exempted as limits', () {
      expect(JsEnvPolicy.looksSecret('MAX_AUTH_TOKEN'), isTrue);
      expect(JsEnvPolicy.looksSecret('MAX_PAT_TOKEN'), isTrue);
      expect(JsEnvPolicy.looksSecret('GITHUB_TOKEN_MAX'), isTrue);
      expect(JsEnvPolicy.looksSecret('ADO_PAT_TOKEN_LIMIT'), isFalse);
      expect(JsEnvPolicy.looksSecret('AUTH_TOKEN_COUNT'), isTrue);
    });

    test('matching is whole-word, not substring', () {
      expect(JsEnvPolicy.looksSecret('KEYBOARD_LAYOUT'), isFalse);
      expect(JsEnvPolicy.looksSecret('AUTHOR'), isFalse);
      expect(JsEnvPolicy.looksSecret('ADO_PROJECT'), isFalse);
      expect(JsEnvPolicy.looksSecret('DEFAULT_TRACKER'), isFalse);
    });

    test('null and blank fail closed', () {
      expect(JsEnvPolicy.looksSecret(null), isTrue);
      expect(JsEnvPolicy.looksSecret(''), isTrue);
      expect(JsEnvPolicy.looksSecret('   '), isTrue);
    });
  });
}

void _defineDefaultAllowedTests() {
  group('defaultAllowed', () {
    test('contains every declared non-secret name', () {
      for (final name in PropertyNames.all) {
        if (JsEnvPolicy.looksSecret(name)) {
          expect(JsEnvPolicy.defaultAllowed, isNot(contains(name)));
        } else {
          expect(JsEnvPolicy.defaultAllowed, contains(name), reason: name);
        }
      }
    });

    test('readable configuration names are present', () {
      expect(
        JsEnvPolicy.defaultAllowed,
        containsAll(['ADO_PROJECT', 'DEFAULT_TRACKER', 'OPENAI_MAX_TOKENS']),
      );
      expect(JsEnvPolicy.defaultAllowed, contains('JS_ENV_ALLOWLIST'));
    });

    test('contains no secret name', () {
      for (final name in JsEnvPolicy.defaultAllowed) {
        expect(JsEnvPolicy.looksSecret(name), isFalse, reason: name);
      }
    });
  });
}

void _defineAllowlistTests() {
  group('projectAllowed / rejectedFromAllowlist', () {
    test('accepts names, drops secret-looking ones', () {
      const raw = 'MY_SETTING, jira_api_token ,OTHER_VAR';
      expect(JsEnvPolicy.projectAllowed(raw), {'MY_SETTING', 'OTHER_VAR'});
      expect(JsEnvPolicy.rejectedFromAllowlist(raw), {'JIRA_API_TOKEN'});
    });

    test('null or invalid entries are ignored', () {
      expect(JsEnvPolicy.projectAllowed(null), isEmpty);
      expect(JsEnvPolicy.projectAllowed('1BAD,a-b'), isEmpty);
      expect(JsEnvPolicy.rejectedFromAllowlist(null), isEmpty);
    });
  });

  group('decide', () {
    test('invalid names are rejected', () {
      expect(JsEnvPolicy.decide(null, null), EnvDecision.invalidName);
      expect(JsEnvPolicy.decide('', null), EnvDecision.invalidName);
      expect(JsEnvPolicy.decide('1ABC', null), EnvDecision.invalidName);
      expect(JsEnvPolicy.decide('A-B', null), EnvDecision.invalidName);
    });

    test('secret wins over any allowlist', () {
      expect(
        JsEnvPolicy.decide('JIRA_API_TOKEN', 'JIRA_API_TOKEN'),
        EnvDecision.secret,
      );
    });

    test(
      'default and project-allowlisted names are allowed, case-insensitive',
      () {
        expect(JsEnvPolicy.decide('ado_project', null), EnvDecision.allowed);
        expect(
          JsEnvPolicy.decide('custom_one', 'CUSTOM_ONE'),
          EnvDecision.allowed,
        );
      },
    );

    test('unknown names are not allowlisted', () {
      expect(
        JsEnvPolicy.decide('RANDOM_THING', null),
        EnvDecision.notAllowlisted,
      );
    });
  });
}
