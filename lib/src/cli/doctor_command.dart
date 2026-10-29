/// Configuration presence check — Dart port of Java `ConfigDoctor.diagnose()`.
///
/// Phase 2 scope: verifies that the environment variables required by each
/// integration are present via [PropertyReader] (overrides → `dmtools.env`
/// → OS env). Connectivity tests arrive with the
/// Phase 3 integration ports; the report says so in its closing note.
library;

import '../config/property_reader.dart';
import '../config/property_reader_ai_getters.dart';
import '../config/property_reader_getters.dart';

/// Outcome of a single integration check: names and what is missing.
class _IntegrationCheck {
  const _IntegrationCheck(this.name, this.displayName, this.missing);

  /// Lowercase integration key used in the report (`jira`, `ado`, ...).
  final String name;

  /// Human-readable integration name (`Jira`, `ADO`, ...).
  final String displayName;

  /// Required variables that are absent (empty when configured).
  final List<String> missing;

  bool get configured => missing.isEmpty;
}

/// Checks configuration presence for every DMTools integration.
class DoctorCommand {
  /// Creates a doctor command.
  ///
  /// [reader] backs every lookup; production code omits it so values load
  /// from the current working directory resolution chain.
  DoctorCommand({PropertyReader? reader})
      : _reader = reader ?? PropertyReader();

  final PropertyReader _reader;

  /// Integrations whose requirements are plain all-of variable lists.
  ///
  /// Presence is checked through the raw resolution chain
  /// ([PropertyReader.getValue] — the same chain every extension getter
  /// uses) so getters with defaults cannot mask an unset variable. The
  /// auth-chain integrations (jira, confluence, figma, ai, teams) use
  /// dedicated methods backed by the extension getters instead.
  static const Map<String, (String, List<String>)> _simpleChecks = {
    'github': ('GitHub', ['SOURCE_GITHUB_TOKEN']),
    'gitlab': ('GitLab', ['GITLAB_TOKEN']),
    'bitbucket': ('Bitbucket', ['BITBUCKET_TOKEN']),
    'ado': ('ADO', ['ADO_ORGANIZATION', 'ADO_PROJECT', 'ADO_PAT_TOKEN']),
    'rally': ('Rally', ['RALLY_TOKEN', 'RALLY_PATH']),
    'testrail': (
      'TestRail',
      ['TESTRAIL_BASE_PATH', 'TESTRAIL_USERNAME', 'TESTRAIL_API_KEY'],
    ),
    'bitrise': ('Bitrise', ['BITRISE_TOKEN']),
    'xray': (
      'Xray',
      ['XRAY_CLIENT_ID', 'XRAY_CLIENT_SECRET', 'XRAY_BASE_PATH'],
    ),
    // dm.ai #570: raw base-path check — the getter defaults to
    // localhost:8080 and would never report the variable as missing.
    'jenkins': (
      'Jenkins',
      ['JENKINS_BASE_PATH', 'JENKINS_USER', 'JENKINS_API_TOKEN'],
    ),
    // SharePoint reuses the Teams (TEAMS_*) OAuth configuration.
    'sharepoint': (
      'SharePoint via Teams OAuth credentials',
      ['TEAMS_CLIENT_ID', 'TEAMS_TENANT_ID'],
    ),
  };

  /// Runs all checks and returns the full report text.
  String run() {
    final checks = _runChecks();
    final ready = checks.where((c) => c.configured).length;
    final buf = StringBuffer()
      ..writeln('DMTools Configuration Check')
      ..writeln('==========================')
      ..writeln('Integrations ready: $ready / ${checks.length}')
      ..writeln();
    for (final check in checks) {
      _writeCheck(buf, check);
    }
    buf
      ..writeln()
      ..write(_note);
    return buf.toString();
  }

  static const String _note =
      'Note: doctor checks configuration presence. Connectivity tests '
      'require Phase 3 integrations.';

  /// Registry integrations whose credentials are present in the local
  /// configuration — Java `ConfigDoctor.getConfiguredIntegrations()` parity
  /// (dm.ai #570). Presence of tokens/paths only: no network calls and no
  /// client construction. Used by `dmtools list` when
  /// `DMTOOLS_INTEGRATIONS` is unset, so the listing reflects what this
  /// machine can actually run (e.g. Jenkins tools show up exactly when
  /// `JENKINS_*` is configured).
  Set<String> configuredIntegrations() {
    final checks = <String, _IntegrationCheck>{
      for (final check in _runChecks()) check.name: check,
    };
    final integrations = <String>{..._alwaysAvailable};
    for (final entry in _configuredMapping.entries) {
      final ready = entry.value.every(
        (name) => checks[name]?.configured == true,
      );
      if (ready) integrations.addAll(entry.key);
    }
    return integrations;
  }

  /// Registry integrations that need no external credentials and are
  /// therefore always listable — Java `ALWAYS_AVAILABLE_INTEGRATIONS`.
  /// `teams_auth` stays: `teams_auth_start` is the bootstrap entry point
  /// used to obtain the Teams configuration itself. kb/mermaid are
  /// deliberately NOT here: their core tools are AI-driven, so they
  /// follow the `ai` readiness below.
  /// `scm`/`ci` are here too although they hold no credentials: their
  /// tools are the env-gated gh-339 alias families, registered only when
  /// `DEFAULT_SCM`/`DEFAULT_CI` resolve. Allowing the tags keeps those
  /// registered families visible under the config-detected list; an
  /// unresolved provider simply leaves the family unregistered.
  static const Set<String> _alwaysAvailable = {
    'cli',
    'env',
    'scm',
    'ci',
    'file',
    'other',
    'teams_auth',
  };

  /// Registry integration names → the doctor checks that must all pass.
  /// A single check maps to itself; compound readiness (xray needs jira,
  /// ai unlocks kb/mermaid, teams unlocks sharepoint) is expressed by
  /// listing every required check.
  static const Map<Set<String>, List<String>> _configuredMapping = {
    {'jira'}: ['jira'],
    // Xray tools run against the Jira host and need both credential sets.
    {'jira_xray'}: ['jira', 'xray'],
    {'confluence'}: ['confluence'],
    {'figma'}: ['figma'],
    {'github'}: ['github'],
    {'gitlab'}: ['gitlab'],
    {'bitbucket'}: ['bitbucket'],
    {'ado'}: ['ado'],
    {'rally'}: ['rally'],
    {'testrail'}: ['testrail'],
    {'bitrise'}: ['bitrise'],
    {'jenkins'}: ['jenkins'],
    // kb and mermaid core tools are AI-driven (KB analysis agents,
    // mermaid_index_generate) — without an AI provider they have no
    // useful functionality, so they follow ai readiness.
    {'ai', 'kb', 'mermaid'}: ['ai'],
    // SharePoint reuses the Teams (TEAMS_*) OAuth configuration.
    {'teams', 'teams_auth', 'sharepoint'}: ['teams'],
  };

  void _writeCheck(StringBuffer buf, _IntegrationCheck check) {
    final state = check.configured ? 'configured' : 'incomplete';
    final mark = check.configured ? '✓' : '✗';
    buf.writeln(
      '$mark ${check.name} - ${check.displayName} authentication '
      '$state',
    );
    for (final variable in check.missing) {
      buf.writeln('    missing: $variable');
    }
  }

  List<_IntegrationCheck> _runChecks() => [
        _IntegrationCheck('jira', 'Jira', _jiraMissing()),
        _IntegrationCheck('confluence', 'Confluence', _confluenceMissing()),
        _IntegrationCheck('figma', 'Figma', _figmaMissing()),
        for (final entry in _simpleChecks.entries)
          _IntegrationCheck(
            entry.key,
            entry.value.$1,
            _missingRequired(entry.value.$2),
          ),
        _IntegrationCheck('ai', 'AI', _aiMissing()),
        _IntegrationCheck('teams', 'Teams', _teamsMissing()),
      ];

  // --- Auth-chain integrations ---

  List<String> _jiraMissing() {
    final missing = <String>[];
    _addIfAbsent(missing, 'JIRA_BASE_PATH', _reader.getJiraBasePath());
    if (!_present(_reader.getJiraLoginPassToken())) {
      _addIfAbsent(missing, 'JIRA_EMAIL', _reader.getJiraEmail());
      _addIfAbsent(missing, 'JIRA_API_TOKEN', _reader.getJiraApiToken());
    }
    return missing;
  }

  List<String> _confluenceMissing() {
    final missing = <String>[];
    _addIfAbsent(
      missing,
      'CONFLUENCE_BASE_PATH',
      _reader.getConfluenceBasePath(),
    );
    if (!_present(_reader.getConfluenceLoginPassToken())) {
      _addIfAbsent(missing, 'CONFLUENCE_EMAIL', _reader.getConfluenceEmail());
      _addIfAbsent(
        missing,
        'CONFLUENCE_API_TOKEN',
        _reader.getConfluenceApiToken(),
      );
    }
    return missing;
  }

  List<String> _figmaMissing() {
    final hasToken = _present(_reader.getFigmaApiKey());
    final hasOAuth = _present(_reader.getFigmaOAuth2AccessToken());
    if (hasToken || hasOAuth) return const [];
    return const ['FIGMA_TOKEN or FIGMA_OAUTH_ACCESS_TOKEN'];
  }

  List<String> _aiMissing() {
    final configured = [
      _present(_reader.getDialIApiKey()),
      _present(_reader.getGeminiApiKey()),
      _present(_reader.getOpenAIApiKey()),
      _present(_reader.getAnthropicModel()),
      _present(_reader.getBedrockModelId()),
      _present(_reader.getOllamaModel()),
    ];
    if (configured.contains(true)) return const [];
    return const [
      'DIAL_API_KEY, GEMINI_API_KEY, OPENAI_API_KEY, ANTHROPIC_MODEL, '
          'BEDROCK_MODEL_ID or OLLAMA_MODEL',
    ];
  }

  List<String> _teamsMissing() {
    final missing = <String>[];
    _addIfAbsent(missing, 'TEAMS_CLIENT_ID', _reader.getTeamsClientId());
    // Raw check: getTeamsTenantId() defaults to 'common' and would never
    // report the variable as missing.
    _addIfAbsent(
      missing,
      'TEAMS_TENANT_ID',
      _reader.getValue('TEAMS_TENANT_ID'),
    );
    return missing;
  }

  // --- Helpers ---

  List<String> _missingRequired(List<String> keys) {
    final missing = <String>[];
    for (final key in keys) {
      _addIfAbsent(missing, key, _reader.getValue(key));
    }
    return missing;
  }

  static bool _present(String? value) =>
      value != null && value.trim().isNotEmpty;

  static void _addIfAbsent(List<String> missing, String key, String? value) {
    if (!_present(value)) missing.add(key);
  }
}
