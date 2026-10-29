/// Unit tests for `dmtools list` integration filtering — Java
/// `McpCliHandler.getAvailableIntegrations` parity (dm.ai #570/#572):
/// `DMTOOLS_INTEGRATIONS` wins verbatim when set; when unset the list is
/// config-detected (doctor token presence) plus token-less integrations.
library;

import 'dart:convert';
import 'dart:io';

import 'package:dmtools/dmtools.dart';
import 'package:test/test.dart';

late Directory _tmp;
late List<String> _lines;
late CliDispatcher _dispatcher;

void main() {
  setUpAll(() => PropertyReader.testIsolation = true);
  tearDownAll(() {
    PropertyReader.testIsolation = false;
    PropertyReader.testEnvironment.clear();
  });
  setUp(() {
    _tmp = Directory.systemTemp.createTempSync('dmtools_cli_list_');
    PropertyReader.setOverrides({});
    _lines = [];
    _dispatcher = CliDispatcher(
      writer: _lines.add,
      propertyReader: PropertyReader(basePath: _tmp.path),
      isTty: () => false,
    );
  });

  tearDown(() {
    PropertyReader.clearOverrides();
    if (_tmp.existsSync()) _tmp.deleteSync(recursive: true);
  });

  _testConfigDetectedListing();
  _testConfluenceLoginPassTokenListing();
  _testScmCiVisibility();
  _testHelpSchema();
  _testListFilters();
}

void _testConfluenceLoginPassTokenListing() {
  group('list confluence detection', () {
    test('config-detected list includes confluence for LOGIN_PASS_TOKEN only',
        () async {
      _writeEnv('''
  CONFLUENCE_BASE_PATH=https://test.atlassian.net/wiki
  CONFLUENCE_AUTH_TYPE=Basic
  CONFLUENCE_LOGIN_PASS_TOKEN=prebuilt
  ''');
      expect(await _dispatcher.dispatch(['list']), 0);
      final confluence = _decodedTools()
          .where((t) => t['integration'] == 'confluence')
          .toList();
      expect(confluence, isNotEmpty);
      final names = confluence.map((t) => t['name'] as String).toSet();
      expect(names, contains('confluence_get_page'));
      expect(names, contains('confluence_test'));
    });
  });
}

void _testConfigDetectedListing() {
  group('list integration detection', () {
    test(
        'falls back to config-detected integrations when '
        'DMTOOLS_INTEGRATIONS is unset', () async {
      // With no override the list reflects what this machine can run —
      // token-less integrations only in a tokenless env.
      expect(await _dispatcher.dispatch(['list']), 0);
      final tools = _decodedTools();
      expect(tools, isNotEmpty);
      final integrations = tools.map((t) => t['integration'] as String).toSet();
      expect(
        integrations.difference(const {
          'cli',
          'env',
          'file',
          'other',
          'teams_auth',
        }),
        isEmpty,
      );
      expect(
        tools.map((t) => t['name'] as String),
        isNot(contains('jira_get_ticket')),
      );
    });

    _testJenkinsConfigDetection();

    test(
      'DMTOOLS_INTEGRATIONS still wins verbatim over config detection',
      () async {
        // Documented override: jenkins is fully configured, but an explicit
        // env subset hides it (dm.ai #570 verified behavior).
        _writeEnv('''
JENKINS_BASE_PATH=https://jenkins.example.com
JENKINS_USER=ci
JENKINS_API_TOKEN=tok
''');
        PropertyReader.setOverrides({'DMTOOLS_INTEGRATIONS': 'jira,cli'});
        expect(await _dispatcher.dispatch(['list']), 0);
        expect(_decodedTools().map((t) => t['integration'] as String).toSet(), {
          'jira',
          'cli',
        });
      },
    );
  });
}

void _testScmCiVisibility() {
  group('list gh-339 scm_/ci_ visibility', () {
    test(
        'alias families stay visible under config detection when '
        'DEFAULT_SCM/DEFAULT_CI resolve', () async {
      // Regression: 'scm'/'ci' are registry integration tags of the
      // env-gated gh-339 alias families, not doctor-checkable
      // integrations. Registration is already gated on DEFAULT_SCM /
      // DEFAULT_CI resolving, so the config-detected filter must allow
      // the tags — otherwise the registered families vanish from the
      // listing in exactly this ticket's scenario (env var unset).
      PropertyReader.setOverrides({
        'DEFAULT_SCM': 'github',
        'DEFAULT_CI': 'actions',
      });
      expect(await _dispatcher.dispatch(['list']), 0);
      final names = _decodedTools().map((t) => t['name'] as String);
      expect(names, contains('scm_list_prs'));
      expect(names, contains('ci_get_merge_state'));
    });

    test(
        'families stay absent when their default provider does not '
        'resolve', () async {
      // gh-339 semantics intact: no DEFAULT_SCM/DEFAULT_CI → the
      // families are not registered → absent from the list.
      expect(await _dispatcher.dispatch(['list']), 0);
      final names = _decodedTools().map((t) => t['name'] as String);
      expect(names.where((n) => n.startsWith('scm_')), isEmpty);
      expect(names.where((n) => n.startsWith('ci_')), isEmpty);
    });
  });
}

void _testHelpSchema() {
  group('list help schema', () {
    test(
        'a canonical tool schema is shown even when its integration is '
        'not configured', () async {
      // dm.ai #570: getToolSchema reads the FULL registry, so usage hints
      // keep working for tools outside the config-detected list.
      expect(await _dispatcher.dispatch(['jira_get_ticket', '--help']), 0);
      final result = jsonDecode(_lines.last) as Map<String, dynamic>;
      final names = (result['tools'] as List).cast<Map<String, dynamic>>().map(
            (t) => t['name'] as String,
          );
      expect(names, contains('jira_get_ticket'));
    });
  });
}

void _testListFilters() {
  group('list filters', () {
    test('filters the catalog by a case-insensitive substring', () async {
      // 'contents' appears in the file_read description but not its name;
      // file tools are token-less, so the filter matches regardless of
      // which integrations are configured (dm.ai #570 test note).
      expect(await _dispatcher.dispatch(['list', 'contents']), 0);
      final tools = _decodedTools(lastLineOnly: true);
      expect(tools, isNotEmpty);
      for (final t in tools) {
        final matches =
            (t['name'] as String).toLowerCase().contains('contents') ||
                (t['description'] as String).toLowerCase().contains('contents');
        expect(matches, isTrue);
      }
    });

    test('honors the DMTOOLS_INTEGRATIONS filter', () async {
      PropertyReader.setOverrides({'DMTOOLS_INTEGRATIONS': 'jira'});
      expect(await _dispatcher.dispatch(['list']), 0);
      final tools = _decodedTools();
      expect(tools, isNotEmpty);
      for (final t in tools) {
        expect(t['integration'], 'jira');
      }
    });
  });
}

/// Writes a `dmtools.env` into the dispatcher's base directory.
void _writeEnv(String content) =>
    File('${_tmp.path}/dmtools.env').writeAsStringSync(content);

/// Decodes the `tools` array of the last written JSON response. When
/// [lastLineOnly] is set only the final line is parsed (single-line
/// responses); otherwise every collected line is joined first
/// (multi-line pretty-printed responses).
List<Map<String, dynamic>> _decodedTools({bool lastLineOnly = false}) {
  final decoded = jsonDecode(
    lastLineOnly ? _lines.last : _lines.join('\n'),
  ) as Map<String, dynamic>;
  return (decoded['tools'] as List).cast<Map<String, dynamic>>();
}

void _testJenkinsConfigDetection() {
  test(
    'config-detected list includes jenkins once JENKINS_* is set',
    () async {
      _writeEnv('''
JENKINS_BASE_PATH=https://jenkins.example.com
JENKINS_USER=ci
JENKINS_API_TOKEN=tok
''');
      expect(await _dispatcher.dispatch(['list']), 0);
      final jenkins =
          _decodedTools().where((t) => t['integration'] == 'jenkins').toList();
      expect(jenkins, isNotEmpty);
      expect(
        jenkins.every((t) => (t['name'] as String).startsWith('jenkins_')),
        isTrue,
      );
    },
  );
}
