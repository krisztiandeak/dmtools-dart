import 'dart:convert';
import 'dart:io';

import 'package:dmtools/dmtools.dart';
import 'package:test/test.dart';

/// Unit tests for [PropertyReader] and the [PropertyReaderGetters] extension.
///
/// The static overrides mechanism (highest priority in the resolution chain)
/// is used to inject controlled values, avoiding the need to manipulate OS
/// environment variables or write `.env` files.
late PropertyReader reader;

void main() {
  setUpAll(() => PropertyReader.testIsolation = true);
  tearDownAll(() {
    PropertyReader.testIsolation = false;
    PropertyReader.testEnvironment.clear();
  });
  setUp(() {
    PropertyReader.setOverrides({}); // start clean
    reader = PropertyReader();
  });

  tearDown(PropertyReader.clearOverrides);

  _testOverrides();
  _testZoneOverrides();
  _testGetValue();
  _testResolutionOrder();
  _testJiraTokens();
  _testJiraDefaults();
  _testConfluenceAuth();
  _testGeminiFallback();
  _testBedrockDialFallback();
  _testFigmaFallback();
  _testRangeClamping();
  _testDefaultValues();
  _testBedrockBasePath();
  _testIntegerParsing();
  _testStoryPointsAutoDetect();
  _testCsvSetParsing();
  _testResetForTesting();
  _testResolveEnvVariables();
}

void _testOverrides() {
  group('override mechanism', () {
    test('setOverrides + getOverrides returns the supplied map', () {
      PropertyReader.setOverrides({'FOO': 'bar', 'BAZ': 'qux'});
      expect(PropertyReader.getOverrides(), {'FOO': 'bar', 'BAZ': 'qux'});
    });

    test('getOverrides returns an empty map before any overrides are set', () {
      PropertyReader.clearOverrides();
      expect(PropertyReader.getOverrides(), isEmpty);
    });

    test('clearOverrides makes getOverrides return an empty map', () {
      PropertyReader.setOverrides({'A': '1'});
      expect(PropertyReader.getOverrides(), isNotEmpty);
      PropertyReader.clearOverrides();
      expect(PropertyReader.getOverrides(), isEmpty);
    });

    test('getValue returns the override value when set', () {
      PropertyReader.setOverrides({'MY_KEY': 'overridden'});
      expect(reader.getValue('MY_KEY'), 'overridden');
    });

    test('override value wins over everything else (including OS env)', () {
      // PATH is present in every realistic OS environment.
      const envPath = String.fromEnvironment('PATH');
      // Sanity: PATH should exist in Platform.environment at runtime.
      // We assert that the override wins regardless.
      PropertyReader.setOverrides({'PATH': '/custom/path'});
      expect(reader.getValue('PATH'), '/custom/path');
      expect(envPath, isNot('/custom/path'));
    });

    test('returned override map is unmodifiable', () {
      PropertyReader.setOverrides({'K': 'V'});
      final overrides = PropertyReader.getOverrides();
      expect(() => overrides['X'] = 'Y', throwsUnsupportedError);
    });
  });
}

void _testZoneOverrides() {
  group('runWithOverrides (zone-scoped overrides)', () {
    test('getOverrides returns the zone map inside the body, across awaits',
        () async {
      PropertyReader.setOverrides({'STATIC_KEY': 'static'});
      String? before;
      String? after;
      await PropertyReader.runWithOverrides({'ZONE_KEY': 'zoned'}, () async {
        before = PropertyReader.getOverrides()['ZONE_KEY'];
        await Future.delayed(const Duration(milliseconds: 10));
        after = PropertyReader.getOverrides()['ZONE_KEY'];
      });
      // The zone map is visible for the whole body, across the await, and
      // wins over the static map (STATIC_KEY is not part of it).
      expect(before, 'zoned');
      expect(after, 'zoned');
      expect(PropertyReader.getOverrides(), {'STATIC_KEY': 'static'});
    });

    test('concurrent bodies each see their own map across awaits', () async {
      final firstSeen = <String>[];
      final secondSeen = <String>[];
      final first = PropertyReader.runWithOverrides({'WHO': 'first'}, () async {
        await Future.delayed(const Duration(milliseconds: 20));
        firstSeen.add(PropertyReader.getOverrides()['WHO'] ?? 'none');
        await Future.delayed(const Duration(milliseconds: 20));
        firstSeen.add(PropertyReader.getOverrides()['WHO'] ?? 'none');
      });
      final second = PropertyReader.runWithOverrides(
        {'WHO': 'second'},
        () async {
          await Future.delayed(const Duration(milliseconds: 20));
          secondSeen.add(PropertyReader.getOverrides()['WHO'] ?? 'none');
          await Future.delayed(const Duration(milliseconds: 20));
          secondSeen.add(PropertyReader.getOverrides()['WHO'] ?? 'none');
        },
      );
      await Future.wait([first, second]);
      expect(firstSeen, everyElement('first'));
      expect(secondSeen, everyElement('second'));
    });

    test('static map is untouched after runWithOverrides completes', () async {
      PropertyReader.setOverrides({'STATIC_KEY': 'static'});
      await PropertyReader.runWithOverrides({'ZONE_KEY': 'zoned'}, () async {
        expect(PropertyReader.getOverrides(), {'ZONE_KEY': 'zoned'});
      });
      // Outside the zone the static map is exactly what setOverrides left.
      expect(PropertyReader.getOverrides(), {'STATIC_KEY': 'static'});
      // setOverrides still works after a zone-scoped run.
      PropertyReader.setOverrides({'NEW_KEY': 'new-value'});
      expect(PropertyReader.getOverrides(), {'NEW_KEY': 'new-value'});
    });
  });
}

void _testGetValue() {
  group('getValue / getValueWithDefault', () {
    test('getValue returns null for a key absent from overrides and env', () {
      expect(reader.getValue('THIS_KEY_DOES_NOT_EXIST_ANYWHERE'), isNull);
    });

    test('getValueWithDefault returns default for an absent key', () {
      expect(
        reader.getValueWithDefault('THIS_KEY_DOES_NOT_EXIST_ANYWHERE', 'fb'),
        'fb',
      );
    });

    test('getValueWithDefault returns default when value is empty string', () {
      PropertyReader.setOverrides({'EMPTY_KEY': ''});
      expect(reader.getValue('EMPTY_KEY'), '');
      expect(reader.getValueWithDefault('EMPTY_KEY', 'fallback'), 'fallback');
    });

    test('getValueWithDefault returns the real value when non-empty', () {
      PropertyReader.setOverrides({'PRESENT_KEY': 'hello'});
      expect(reader.getValueWithDefault('PRESENT_KEY', 'fallback'), 'hello');
    });
  });
}

void _testResolutionOrder() {
  group('resolution order', () {
    test('override beats Platform.environment for PATH', () {
      PropertyReader.setOverrides({'PATH': '/winner'});
      expect(reader.getValue('PATH'), '/winner');
    });

    test('override beats Platform.environment for HOME', () {
      PropertyReader.setOverrides({'HOME': '/fake/home'});
      expect(reader.getValue('HOME'), '/fake/home');
    });
  });
}

void _testJiraTokens() {
  group('Jira login token', () {
    test('getJiraBasePath returns null when not configured', () {
      expect(reader.getJiraBasePath(), isNull);
    });

    test('getJiraLoginPassToken returns base64(email:token) when both set', () {
      PropertyReader.setOverrides({
        'JIRA_EMAIL': 'user@example.com',
        'JIRA_API_TOKEN': 'abc123',
      });
      final token = reader.getJiraLoginPassToken();
      expect(token, isNotNull);
      final decoded = utf8.decode(base64Decode(token!));
      expect(decoded, 'user@example.com:abc123');
    });

    test('getJiraLoginPassToken trims email and token before encoding', () {
      PropertyReader.setOverrides({
        'JIRA_EMAIL': '  user@example.com  ',
        'JIRA_API_TOKEN': '  abc123  ',
      });
      final decoded =
          utf8.decode(base64Decode(reader.getJiraLoginPassToken()!));
      expect(decoded, 'user@example.com:abc123');
    });

    test('getJiraLoginPassToken falls back to JIRA_LOGIN_PASS_TOKEN', () {
      PropertyReader.setOverrides({'JIRA_LOGIN_PASS_TOKEN': 'raw-token'});
      expect(reader.getJiraLoginPassToken(), 'raw-token');
    });

    test('getJiraLoginPassToken returns null when neither is set', () {
      expect(reader.getJiraLoginPassToken(), isNull);
    });

    test(
      'getJiraLoginPassToken falls back when only email is set (no token)',
      () {
        PropertyReader.setOverrides({
          'JIRA_EMAIL': 'user@example.com',
          'JIRA_LOGIN_PASS_TOKEN': 'fallback',
        });
        expect(reader.getJiraLoginPassToken(), 'fallback');
      },
    );

    test('getJiraMaxSearchResults parses a valid integer', () {
      PropertyReader.setOverrides({'JIRA_MAX_SEARCH_RESULTS': '500'});
      expect(reader.getJiraMaxSearchResults(), 500);
    });

    test('getJiraMaxSearchResults falls back to -1 on invalid input', () {
      PropertyReader.setOverrides({'JIRA_MAX_SEARCH_RESULTS': 'not-a-number'});
      expect(reader.getJiraMaxSearchResults(), -1);
    });
  });
}

void _testJiraDefaults() {
  group('Jira defaults', () {
    test('getJiraExtraFieldsProject returns TS by default', () {
      expect(reader.getJiraExtraFieldsProject(), 'TS');
    });

    test('isJiraTransformCustomFieldsToNames returns true by default', () {
      expect(reader.isJiraTransformCustomFieldsToNames(), isTrue);
    });

    test('getJiraMaxSearchResults returns -1 by default', () {
      expect(reader.getJiraMaxSearchResults(), -1);
    });

    test('getJiraIssueIgnorePrefixes returns empty set by default', () {
      expect(reader.getJiraIssueIgnorePrefixes(), isEmpty);
    });

    test('getJiraExtraFields returns null by default', () {
      expect(reader.getJiraExtraFields(), isNull);
    });
  });
}

void _testConfluenceAuth() {
  group('Confluence auth chain', () {
    test('getConfluenceAuthType returns Basic by default', () {
      expect(reader.getConfluenceAuthType(), 'Basic');
    });

    test('Bearer auth with email/token returns the raw token', () {
      PropertyReader.setOverrides({
        'CONFLUENCE_AUTH_TYPE': 'Bearer',
        'CONFLUENCE_EMAIL': 'user@example.com',
        'CONFLUENCE_API_TOKEN': 'raw-token',
      });
      expect(reader.getConfluenceLoginPassToken(), 'raw-token');
    });

    test('Basic auth with email/token returns base64(email:token)', () {
      PropertyReader.setOverrides({
        'CONFLUENCE_AUTH_TYPE': 'Basic',
        'CONFLUENCE_EMAIL': 'user@example.com',
        'CONFLUENCE_API_TOKEN': 'secret',
      });
      final token = reader.getConfluenceLoginPassToken()!;
      final decoded = utf8.decode(base64Decode(token));
      expect(decoded, 'user@example.com:secret');
    });

    test(
      'Basic auth is the default, so email/token yields base64 without setting '
      'CONFLUENCE_AUTH_TYPE',
      () {
        PropertyReader.setOverrides({
          'CONFLUENCE_EMAIL': 'a@b.com',
          'CONFLUENCE_API_TOKEN': 'tok',
        });
        final decoded = utf8.decode(
          base64Decode(reader.getConfluenceLoginPassToken()!),
        );
        expect(decoded, 'a@b.com:tok');
      },
    );

    test('only CONFLUENCE_LOGIN_PASS_TOKEN set returns that value', () {
      PropertyReader.setOverrides({'CONFLUENCE_LOGIN_PASS_TOKEN': 'prebuilt'});
      expect(reader.getConfluenceLoginPassToken(), 'prebuilt');
    });

    test('returns null when no confluence credentials are configured', () {
      expect(reader.getConfluenceLoginPassToken(), isNull);
    });
  });
}

void _testGeminiFallback() {
  group('Gemini fallback chains', () {
    test('getGeminiDefaultModel — GEMINI_MODEL takes priority', () {
      PropertyReader.setOverrides({
        'GEMINI_MODEL': 'gemini-1.5-pro',
        'GEMINI_DEFAULT_MODEL': 'gemini-1.0',
      });
      expect(reader.getGeminiDefaultModel(), 'gemini-1.5-pro');
    });

    test('getGeminiDefaultModel — falls back to GEMINI_DEFAULT_MODEL', () {
      PropertyReader.setOverrides({'GEMINI_DEFAULT_MODEL': 'gemini-1.0'});
      expect(reader.getGeminiDefaultModel(), 'gemini-1.0');
    });

    test(
      'getGeminiDefaultModel — \$-prefixed value is treated as placeholder',
      () {
        PropertyReader.setOverrides({
          'GEMINI_MODEL': '\$PLACEHOLDER',
          'GEMINI_DEFAULT_MODEL': 'gemini-real',
        });
        expect(reader.getGeminiDefaultModel(), 'gemini-real');
      },
    );

    test('getGeminiDefaultModel — returns null when neither is set', () {
      expect(reader.getGeminiDefaultModel(), isNull);
    });

    test(
      'getGeminiDefaultModel — both placeholder returns null even if default '
      'is also placeholder',
      () {
        PropertyReader.setOverrides({
          'GEMINI_MODEL': '\$X',
          'GEMINI_DEFAULT_MODEL': '\$Y',
        });
        expect(reader.getGeminiDefaultModel(), isNull);
      },
    );
  });
}

void _testBedrockDialFallback() {
  group('Bedrock and DIAL fallback chains', () {
    test('getBedrockBearerToken — AWS_BEARER_TOKEN_BEDROCK first', () {
      PropertyReader.setOverrides({
        'AWS_BEARER_TOKEN_BEDROCK': 'primary',
        'BEDROCK_BEARER_TOKEN': 'secondary',
      });
      expect(reader.getBedrockBearerToken(), 'primary');
    });

    test('getBedrockBearerToken — BEDROCK_BEARER_TOKEN fallback', () {
      PropertyReader.setOverrides({'BEDROCK_BEARER_TOKEN': 'secondary'});
      expect(reader.getBedrockBearerToken(), 'secondary');
    });

    test('getBedrockBearerToken — \$-prefixed primary is skipped', () {
      PropertyReader.setOverrides({
        'AWS_BEARER_TOKEN_BEDROCK': '\$placeholder',
        'BEDROCK_BEARER_TOKEN': 'real',
      });
      expect(reader.getBedrockBearerToken(), 'real');
    });

    test('getBedrockBearerToken — returns null when neither set', () {
      expect(reader.getBedrockBearerToken(), isNull);
    });

    test('getDialBathPath — DIAL_BASE_PATH first', () {
      PropertyReader.setOverrides({
        'DIAL_BASE_PATH': 'https://dial.example.com',
        'DIAL_BATH_PATH': 'https://legacy.example.com',
      });
      expect(reader.getDialBathPath(), 'https://dial.example.com');
    });

    test('getDialBathPath — DIAL_BATH_PATH fallback', () {
      PropertyReader.setOverrides(
          {'DIAL_BATH_PATH': 'https://legacy.example.com'});
      expect(reader.getDialBathPath(), 'https://legacy.example.com');
    });
  });
}

void _testFigmaFallback() {
  group('Figma fallback chains', () {
    test('getFigmaOAuth2Scopes — FIGMA_SCOPE first', () {
      PropertyReader.setOverrides({
        'FIGMA_SCOPE': 'file_read',
        'FIGMA_OAUTH_SCOPES': 'legacy_scope',
      });
      expect(reader.getFigmaOAuth2Scopes(), 'file_read');
    });

    test('getFigmaOAuth2Scopes — FIGMA_OAUTH_SCOPES fallback', () {
      PropertyReader.setOverrides({'FIGMA_OAUTH_SCOPES': 'legacy_scope'});
      expect(reader.getFigmaOAuth2Scopes(), 'legacy_scope');
    });

    test('getFigmaOAuth2Scopes — empty FIGMA_SCOPE falls back', () {
      PropertyReader.setOverrides({
        'FIGMA_SCOPE': '   ',
        'FIGMA_OAUTH_SCOPES': 'legacy_scope',
      });
      expect(reader.getFigmaOAuth2Scopes(), 'legacy_scope');
    });
  });
}

void _testRangeClamping() {
  group('range clamping', () {
    test('getBedrockTemperature defaults to 1.0', () {
      expect(reader.getBedrockTemperature(), 1.0);
    });

    test('getBedrockTemperature returns value within [0.0, 1.0]', () {
      PropertyReader.setOverrides({'BEDROCK_TEMPERATURE': '0.5'});
      expect(reader.getBedrockTemperature(), 0.5);
    });

    test('getBedrockTemperature clamps negative to 1.0', () {
      PropertyReader.setOverrides({'BEDROCK_TEMPERATURE': '-0.5'});
      expect(reader.getBedrockTemperature(), 1.0);
    });

    test('getBedrockTemperature clamps >1.0 to 1.0', () {
      PropertyReader.setOverrides({'BEDROCK_TEMPERATURE': '2.0'});
      expect(reader.getBedrockTemperature(), 1.0);
    });

    test('getBedrockTemperature returns 1.0 on invalid input', () {
      PropertyReader.setOverrides({'BEDROCK_TEMPERATURE': 'hot'});
      expect(reader.getBedrockTemperature(), 1.0);
    });

    test('getOpenAITemperature defaults to -1', () {
      expect(reader.getOpenAITemperature(), -1);
    });

    test('getOpenAITemperature allows negative values', () {
      PropertyReader.setOverrides({'OPENAI_TEMPERATURE': '-0.5'});
      expect(reader.getOpenAITemperature(), -0.5);
    });

    test('getOpenAITemperature returns value within [0.0, 2.0]', () {
      PropertyReader.setOverrides({'OPENAI_TEMPERATURE': '0.7'});
      expect(reader.getOpenAITemperature(), 0.7);
    });

    test('getOpenAITemperature clamps >2.0 to 2.0', () {
      PropertyReader.setOverrides({'OPENAI_TEMPERATURE': '3.0'});
      expect(reader.getOpenAITemperature(), 2.0);
    });

    test('getOpenAITemperature returns -1 on invalid input', () {
      PropertyReader.setOverrides({'OPENAI_TEMPERATURE': 'warm'});
      expect(reader.getOpenAITemperature(), -1);
    });
  });
}

void _testDefaultValues() {
  group('default values', () {
    test('getGithubBasePath returns the GitHub API URL by default', () {
      expect(reader.getGithubBasePath(), 'https://api.github.com');
    });

    test('getAdoBasePath returns the Azure DevOps URL by default', () {
      expect(reader.getAdoBasePath(), 'https://dev.azure.com');
    });

    test('getOllamaBasePath returns localhost default', () {
      expect(reader.getOllamaBasePath(), 'http://localhost:11434');
    });

    test('getOpenAIBasePath returns the chat completions endpoint', () {
      expect(
        reader.getOpenAIBasePath(),
        'https://api.openai.com/v1/chat/completions',
      );
    });

    test('getAnthropicBasePath returns the messages endpoint', () {
      expect(
        reader.getAnthropicBasePath(),
        'https://api.anthropic.com/v1/messages',
      );
    });

    test('getTeamsTenantId returns common by default', () {
      expect(reader.getTeamsTenantId(), 'common');
    });

    test('getTeamsAuthMethod returns device by default', () {
      expect(reader.getTeamsAuthMethod(), 'device');
    });

    test('getTestRailDefaultFormat returns html by default', () {
      expect(reader.getTestRailDefaultFormat(), 'html');
    });

    test('getBitriseBasePath returns the Bitrise API URL by default', () {
      expect(reader.getBitriseBasePath(), 'https://api.bitrise.io/v0.1');
    });

    test('getJenkinsBasePath returns localhost default', () {
      expect(reader.getJenkinsBasePath(), 'http://localhost:8080');
    });

    test('defaults are overridable', () {
      PropertyReader.setOverrides(
          {'JENKINS_BASE_PATH': 'https://ci.example.com'});
      expect(reader.getJenkinsBasePath(), 'https://ci.example.com');
    });
  });
}

void _testBedrockBasePath() {
  group('Bedrock derived base path', () {
    test('getBedrockBasePath returns BEDROCK_BASE_PATH when set', () {
      PropertyReader.setOverrides({
        'BEDROCK_BASE_PATH': 'https://custom.bedrock.example.com',
      });
      expect(reader.getBedrockBasePath(), 'https://custom.bedrock.example.com');
    });

    test('getBedrockBasePath constructs URL from BEDROCK_REGION', () {
      PropertyReader.setOverrides({'BEDROCK_REGION': 'us-east-1'});
      expect(
        reader.getBedrockBasePath(),
        'https://bedrock-runtime.us-east-1.amazonaws.com',
      );
    });

    test('getBedrockBasePath returns null when neither is set', () {
      expect(reader.getBedrockBasePath(), isNull);
    });

    test('getBedrockBasePath prefers explicit path over region', () {
      PropertyReader.setOverrides({
        'BEDROCK_BASE_PATH': 'https://explicit.example.com',
        'BEDROCK_REGION': 'eu-west-1',
      });
      expect(reader.getBedrockBasePath(), 'https://explicit.example.com');
    });
  });
}

void _testIntegerParsing() {
  group('integer parsing', () {
    test('getOllamaNumCtx defaults to 16384', () {
      expect(reader.getOllamaNumCtx(), 16384);
    });

    test('getOllamaNumCtx parses a valid integer', () {
      PropertyReader.setOverrides({'OLLAMA_NUM_CTX': '8192'});
      expect(reader.getOllamaNumCtx(), 8192);
    });

    test('getOllamaNumCtx falls back on invalid input', () {
      PropertyReader.setOverrides({'OLLAMA_NUM_CTX': 'huge'});
      expect(reader.getOllamaNumCtx(), 16384);
    });

    test('getAiRetryAmount defaults to 3', () {
      expect(reader.getAiRetryAmount(), 3);
    });

    test('getAiRetryAmount parses a valid integer', () {
      PropertyReader.setOverrides({'AI_RETRY_AMOUNT': '5'});
      expect(reader.getAiRetryAmount(), 5);
    });

    test('getOpenAIMaxTokens defaults to 4096', () {
      expect(reader.getOpenAIMaxTokens(), 4096);
    });

    test('getOpenAIMaxTokens parses a valid integer', () {
      PropertyReader.setOverrides({'OPENAI_MAX_TOKENS': '8192'});
      expect(reader.getOpenAIMaxTokens(), 8192);
    });

    test('getBedrockMaxTokens defaults to 4096', () {
      expect(reader.getBedrockMaxTokens(), 4096);
    });

    test('getBedrockMaxTokens returns 4096 for values < 1', () {
      PropertyReader.setOverrides({'BEDROCK_MAX_TOKENS': '0'});
      expect(reader.getBedrockMaxTokens(), 4096);
      PropertyReader.setOverrides({'BEDROCK_MAX_TOKENS': '-5'});
      expect(reader.getBedrockMaxTokens(), 4096);
    });

    test('getBedrockMaxTokens returns valid positive value', () {
      PropertyReader.setOverrides({'BEDROCK_MAX_TOKENS': '2048'});
      expect(reader.getBedrockMaxTokens(), 2048);
    });
  });
}

void _testStoryPointsAutoDetect() {
  group('story points auto-detect', () {
    test('explicit DEFAULT_TICKET_STORY_POINTS_FIELD_NAMES wins', () {
      PropertyReader.setOverrides({
        'DEFAULT_TICKET_STORY_POINTS_FIELD_NAMES': 'SP,Story Points',
        'JIRA_EXTRA_FIELDS': 'summary,Story Points',
      });
      expect(
        reader.getDefaultTicketStoryPointsFieldHumanNames(),
        ['SP', 'Story Points'],
      );
    });

    test('auto-detect from JIRA_EXTRA_FIELDS containing "Story Points"', () {
      PropertyReader.setOverrides({
        'JIRA_EXTRA_FIELDS': 'summary,status,Story Points,customfield_10001',
      });
      expect(
        reader.getDefaultTicketStoryPointsFieldHumanNames(),
        ['Story Points'],
      );
    });

    test('auto-detect is case-insensitive', () {
      PropertyReader.setOverrides({
        'JIRA_EXTRA_FIELDS': 'summary,story points estimate',
      });
      expect(
        reader.getDefaultTicketStoryPointsFieldHumanNames(),
        ['story points estimate'],
      );
    });

    test('returns null when neither is set', () {
      expect(reader.getDefaultTicketStoryPointsFieldHumanNames(), isNull);
    });

    test('returns null when JIRA_EXTRA_FIELDS has no story-point fields', () {
      PropertyReader.setOverrides({'JIRA_EXTRA_FIELDS': 'summary,status'});
      expect(reader.getDefaultTicketStoryPointsFieldHumanNames(), isNull);
    });
  });
}

void _testCsvSetParsing() {
  group('CSV / set parsing', () {
    test('getJiraExtraFields splits comma-separated values into a list', () {
      PropertyReader.setOverrides(
          {'JIRA_EXTRA_FIELDS': 'summary,status,labels'});
      expect(reader.getJiraExtraFields(), ['summary', 'status', 'labels']);
    });

    test('getJiraIssueIgnorePrefixes returns upper-case set', () {
      PropertyReader.setOverrides(
          {'JIRA_ISSUE_IGNORE_PREFIXES': 'abc,def,ghi'});
      expect(reader.getJiraIssueIgnorePrefixes(), {'ABC', 'DEF', 'GHI'});
    });

    test('getJiraIssueIgnorePrefixes is case-insensitive (upper-cases)', () {
      PropertyReader.setOverrides({'JIRA_ISSUE_IGNORE_PREFIXES': 'Abc,DEF'});
      expect(reader.getJiraIssueIgnorePrefixes(), {'ABC', 'DEF'});
    });

    test('getJiraIssueIgnorePrefixes trims whitespace', () {
      PropertyReader.setOverrides({
        'JIRA_ISSUE_IGNORE_PREFIXES': '  abc  ,  def  ',
      });
      expect(reader.getJiraIssueIgnorePrefixes(), {'ABC', 'DEF'});
    });

    test('getAIAttachmentAllowedExtensions returns lower-case set', () {
      PropertyReader.setOverrides({
        'AI_ATTACHMENT_ALLOWED_EXTENSIONS': 'PNG,JPG,PDF',
      });
      expect(
        reader.getAIAttachmentAllowedExtensions(),
        {'png', 'jpg', 'pdf'},
      );
    });

    test('getAIAttachmentAllowedExtensions trims and lower-cases', () {
      PropertyReader.setOverrides({
        'AI_ATTACHMENT_ALLOWED_EXTENSIONS': '  PNG  ,  jpg  ',
      });
      expect(reader.getAIAttachmentAllowedExtensions(), {'png', 'jpg'});
    });

    test('getAIAttachmentAllowedExtensions returns empty set by default', () {
      expect(reader.getAIAttachmentAllowedExtensions(), isEmpty);
    });
  });
}

void _testResetForTesting() {
  group('resetForTesting', () {
    test('clears cached state so overrides set after reset work correctly', () {
      PropertyReader.setOverrides({'RESET_KEY': 'first'});
      // Trigger env-file loading and instance-level caching.
      expect(reader.getValue('RESET_KEY'), 'first');

      reader.resetForTesting();

      // New overrides should be reflected after the cache is cleared.
      PropertyReader.setOverrides({'RESET_KEY': 'second'});
      expect(reader.getValue('RESET_KEY'), 'second');
    });

    test('allows the reader to be reused after reset', () {
      PropertyReader.setOverrides({'A': '1'});
      expect(reader.getValue('A'), '1');
      reader.resetForTesting();
      expect(reader.getValue('A'), '1');
    });
  });
}

void _testResolveEnvVariables() {
  group('resolveEnvVariables', () {
    tearDown(() => PropertyReader.testEnvironment.clear());

    test('interpolates \$VAR and \${VAR} from environment and leaves unset',
        () {
      PropertyReader.testEnvironment['ENV_VAR_DEV_QUEUE'] = '[{"p":"copilot"}]';
      PropertyReader.testEnvironment['HOST'] = 'example.com';
      PropertyReader.setOverrides({
        'FA_PROVIDERS_QUEUE': r'$ENV_VAR_DEV_QUEUE',
        'URL': r'https://${HOST}/api/$UNSET_TOKEN',
        'LITERAL': 'github',
      });
      expect(
        PropertyReader.getOverrides()['FA_PROVIDERS_QUEUE'],
        '[{"p":"copilot"}]',
      );
      expect(
        PropertyReader.getOverrides()['URL'],
        r'https://example.com/api/$UNSET_TOKEN',
      );
      expect(
        PropertyReader.lastUnresolvedWarnings,
        contains(
          'Warning: unresolved environment variable \$UNSET_TOKEN in URL',
        ),
      );
      expect(PropertyReader.getOverrides()['LITERAL'], 'github');
    });

    test('resolves from extraEnv, sibling overrides, and basePath dmtools.env',
        () {
      final tmp = Directory.systemTemp.createTempSync('prop_resolve_test');
      try {
        File('${tmp.path}/dmtools.env')
            .writeAsStringSync('FROM_FILE=file-val\n');
        final resolved = PropertyReader.resolveEnvVariables(
          {
            'SIBLING_SRC': 'sibling-val',
            'USE_SIBLING': r'$SIBLING_SRC',
            'USE_EXTRA': r'${FROM_EXTRA}',
            'USE_FILE': r'$FROM_FILE',
            'SELF_REF': r'$SELF_REF',
          },
          extraEnv: {'FROM_EXTRA': 'extra-val'},
          basePath: tmp.path,
        );
        expect(resolved['USE_SIBLING'], 'sibling-val');
        expect(resolved['USE_EXTRA'], 'extra-val');
        expect(resolved['USE_FILE'], 'file-val');
        expect(resolved['SELF_REF'], r'$SELF_REF');
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });
  });
}
