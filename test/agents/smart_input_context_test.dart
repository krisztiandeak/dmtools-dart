/// Unit tests for [InputContextConfig], [SourceCapabilities],
/// [TicketReferenceExtractor], [TicketSmartSources], and smart input context
/// building across Confluence, Figma, Jira, GitHub Issues, and Azure DevOps.
library;

import 'dart:convert';
import 'dart:io';

import 'package:dmtools/dmtools.dart';
import 'package:test/test.dart';

import '../js/echo_server_helper.dart';

void main() {
  setUpAll(() => PropertyReader.testIsolation = true);
  tearDownAll(() {
    PropertyReader.testIsolation = false;
    PropertyReader.testEnvironment.clear();
  });

  tearDown(PropertyReader.clearOverrides);

  inputContextConfigTests();
  sourceCapabilitiesTests();
  referenceUrlExtractorTests();
  referenceTicketExtractorTests();
  smartContextConfluenceTests();
  smartContextFigmaTests();
  smartContextLinkedTicketTests();
  smartContextJobWiringTests();
  parallelInputConfigTests();
  parallelInputResilienceTests();
  parallelInputExecutionTests();
}

void inputContextConfigTests() {
  group('InputContextConfig', () {
    test('parses plain ticket string input', () {
      final cfg = InputContextConfig.fromJson({'input': 'PROJ-42'});
      expect(cfg.ticket, 'PROJ-42');
      expect(cfg.smart, isTrue);
      expect(cfg.depth, 1);
      expect(cfg.includeLinkedTickets, isTrue);
      expect(cfg.isSourceEnabled('confluence'), isTrue);
      expect(cfg.isSourceEnabled('figma'), isTrue);
    });

    test('parses structured input map and sources whitelist', () {
      final cfg = InputContextConfig.fromJson({
        'input': {
          'ticket': 'PROJ-99',
          'jql': 'project = PROJ',
          'smart': true,
          'sources': ['confluence'],
          'depth': 2,
          'includeComments': false,
          'includeAttachments': false,
          'skipVideoAttachments': true,
          'skipAllAttachments': true,
          'ignoreClonedByRelationship': false,
          'confluenceDepth': 3,
          'confluenceAttachments': false,
          'includeConfluenceComments': false,
          'includeParentConfluence': false,
        },
      });
      expect(cfg.ticket, 'PROJ-99');
      expect(cfg.jql, 'project = PROJ');
      expect(cfg.depth, 2);
      expect(cfg.includeComments, isFalse);
      expect(cfg.includeAttachments, isFalse);
      expect(cfg.skipVideoAttachments, isTrue);
      expect(cfg.skipAllAttachments, isTrue);
      expect(cfg.ignoreClonedByRelationship, isFalse);
      expect(cfg.confluenceDepth, 3);
      expect(cfg.confluenceAttachments, isFalse);
      expect(cfg.includeConfluenceComments, isFalse);
      expect(cfg.includeParentConfluence, isFalse);
      expect(cfg.isSourceEnabled('Confluence'), isTrue);
      expect(cfg.isSourceEnabled('figma'), isFalse);
    });

    test('smart=false disables all smart sources', () {
      final cfg = InputContextConfig.fromJson({
        'input': {'smart': 'false', 'sources': 'confluence,figma'},
      });
      expect(cfg.smart, isFalse);
      expect(cfg.isSourceEnabled('confluence'), isFalse);
    });
  });
}

void sourceCapabilitiesTests() {
  group('SourceCapabilities', () {
    test('reports false when integrations have no secrets configured', () {
      PropertyReader.setOverrides({});
      final caps = SourceCapabilities(PropertyReader());
      expect(caps.isConfluenceConfigured, isFalse);
      expect(caps.isFigmaConfigured, isFalse);
      expect(caps.isJiraConfigured, isFalse);
      expect(caps.isGithubConfigured, isFalse);
      expect(caps.isAdoConfigured, isFalse);
    });

    test('reports true when secrets are present in PropertyReader', () {
      PropertyReader.setOverrides({
        'CONFLUENCE_BASE_PATH': 'https://acme.atlassian.net/wiki',
        'CONFLUENCE_LOGIN_PASS_TOKEN': 'c-tok',
        'FIGMA_TOKEN': 'f-tok',
        'JIRA_BASE_PATH': 'https://acme.atlassian.net',
        'JIRA_LOGIN_PASS_TOKEN': 'j-tok',
        'SOURCE_GITHUB_TOKEN': 'gh-tok',
        'ADO_ORGANIZATION': 'org',
        'ADO_PROJECT': 'proj',
        'ADO_PAT_TOKEN': 'ado-tok',
      });
      final caps = SourceCapabilities(PropertyReader());
      expect(caps.isConfluenceConfigured, isTrue);
      expect(caps.isFigmaConfigured, isTrue);
      expect(caps.isJiraConfigured, isTrue);
      expect(caps.isGithubConfigured, isTrue);
      expect(caps.isAdoConfigured, isTrue);
    });

    test('supports oauth/fallback tokens for Figma and GitHub', () {
      PropertyReader.setOverrides({
        'FIGMA_OAUTH_ACCESS_TOKEN': 'oauth-fig',
        'GITHUB_TOKEN': 'gh-actions-tok',
      });
      final caps = SourceCapabilities(PropertyReader());
      expect(caps.isFigmaConfigured, isTrue);
      expect(caps.isGithubConfigured, isTrue);
    });
  });
}

void referenceUrlExtractorTests() {
  group('TicketReferenceExtractor URLs', () {
    test('extracts Confluence URLs matching configured base domain', () {
      final urls = TicketReferenceExtractor.extractConfluenceUrls(
        'https://acme.atlassian.net/wiki',
        'See https://acme.atlassian.net/wiki/spaces/ENG/pages/777/Hi?a=1&amp;b=2) '
            'and [short|https://acme.atlassian.net/wiki/x/AB12] '
            'ignore https://other.atlassian.net/wiki/spaces/ENG/pages/1/No',
      );
      expect(urls, [
        'https://acme.atlassian.net/wiki/spaces/ENG/pages/777/Hi?a=1&b=2',
        'https://acme.atlassian.net/wiki/x/AB12',
      ]);
    });

    test('extracts and cleans Figma URLs, stripping t query parameter', () {
      final urls = TicketReferenceExtractor.extractFigmaUrls(
        'Design: [link](https://www.figma.com/design/abc123XYZ/My-App?node-id=1-2&t=deadbeef) '
        'and https://figma.com/file/def456/Spec]. Invalid: https://figma.com/ pricing',
      );
      expect(urls, [
        'https://www.figma.com/design/abc123XYZ/My-App?node-id=1-2',
        'https://figma.com/file/def456/Spec',
      ]);
    });
  });
}

void referenceTicketExtractorTests() {
  group('TicketReferenceExtractor tickets', () {
    test('extracts Jira keys with ignore and allowed prefix filters', () {
      const text = 'Relates to PROJ-10, EXT-20, and SKIP-30.';
      expect(
        TicketReferenceExtractor.extractJiraKeys(
          text,
          ignorePrefixes: {'SKIP'},
        ),
        ['PROJ-10', 'EXT-20'],
      );
      expect(
        TicketReferenceExtractor.extractJiraKeys(
          text,
          allowedPrefixes: {'PROJ'},
        ),
        ['PROJ-10'],
      );
    });

    test('extracts GitHub issue references and inline attachments', () {
      const text = 'See owner/repo#15, https://github.com/org/app/issues/22, '
          '#7, GH-8, and ![shot.png](https://github.com/user-attachments/assets/uuid-1) '
          '<img src="https://user-images.githubusercontent.com/1/2/diagram.svg">';
      expect(
        TicketReferenceExtractor.extractGithubIssueKeys(
          text,
          defaultRepo: 'my/repo',
        ),
        ['owner/repo#15', 'org/app#22', 'my/repo#7', 'my/repo#8'],
      );
      final atts =
          TicketReferenceExtractor.extractGithubInlineAttachments(text);
      expect(atts.map((a) => a.name).toList(), ['shot.png', 'diagram.svg']);
    });

    test('extracts ADO work item references', () {
      const text =
          'Fixes AB#104 and https://dev.azure.com/org/proj/_workitems/edit/205)';
      expect(
        TicketReferenceExtractor.extractAdoWorkItemIds(text),
        ['104', '205'],
      );
    });
  });
}

void smartContextConfluenceTests() {
  test('downloads Confluence pages + inline comments + attachments', () async {
    final server = EchoServer();
    await server.start();
    addTearDown(server.stop);
    final base = 'http://127.0.0.1:${server.port}';
    PropertyReader.setOverrides({
      'CONFLUENCE_BASE_PATH': '$base/wiki',
      'CONFLUENCE_LOGIN_PASS_TOKEN': 'conf-token',
      'CONFLUENCE_AUTH_TYPE': 'Basic',
      'CONFLUENCE_DEFAULT_SPACE': 'ENG',
    });
    final tmp = Directory.systemTemp.createTempSync('dmtools_smart_conf_');
    addTearDown(() => tmp.deleteSync(recursive: true));

    final ticket = {
      'key': 'PROJ-1',
      'fields': {
        'summary': 'Confluence spec',
        'description':
            'Spec at $base/wiki/spaces/ENG/pages/777/Hi and $base/wiki/spaces/DOCS/pages/888/Main',
      },
    };
    final path = TicketInputContextBuilder(tmp.path).build(
      'PROJ-1',
      ticketData: ticket,
      config: InputContextConfig()..confluenceDepth = 2,
    );
    expect(File('$path/confluence/Hi Page.md').existsSync(), isTrue);
    expect(File('$path/confluence/Child Page.md').existsSync(), isTrue);
    expect(File('$path/confluence/Source.md').existsSync(), isTrue);
    expect(File('$path/confluence/Hi Page-comments.md').existsSync(), isTrue);
    expect(
      File('$path/confluence/Hi Page-comments.md').readAsStringSync(),
      contains('Needs clarification'),
    );
    expect(
      File('$path/confluence/Hi Page-attachments/shot.png').existsSync(),
      isTrue,
    );
  });
}

void smartContextFigmaTests() {
  test('skips Confluence and Figma when their secrets are not configured', () {
    PropertyReader.setOverrides({});
    final tmp = Directory.systemTemp.createTempSync('dmtools_smart_unconf_');
    addTearDown(() => tmp.deleteSync(recursive: true));

    final ticket = {
      'key': 'PROJ-2',
      'fields': {
        'summary': 'Unconfigured sources',
        'description': 'Spec https://acme.atlassian.net/wiki/x/AB12 '
            'and https://www.figma.com/design/abc123/Design?node-id=1-2',
      },
    };
    final path = TicketInputContextBuilder(tmp.path).build(
      'PROJ-2',
      ticketData: ticket,
    );
    expect(Directory('$path/confluence').existsSync(), isFalse);
    expect(Directory('$path/figma').existsSync(), isFalse);
  });

  test('downloads Figma structure, layers, text, comments, and preview image',
      () async {
    final server = EchoServer();
    await server.start();
    addTearDown(server.stop);
    final base = 'http://127.0.0.1:${server.port}';
    PropertyReader.setOverrides({
      'FIGMA_BASE_PATH': '$base/figdl/v1',
      'FIGMA_TOKEN': 'fig-secret',
    });
    final tmp = Directory.systemTemp.createTempSync('dmtools_smart_figma_');
    addTearDown(() => tmp.deleteSync(recursive: true));

    final ticket = {
      'key': 'PROJ-3',
      'fields': {
        'summary': 'Figma spec',
        'description':
            'UI: https://www.figma.com/design/fileKey1/App?node-id=1-2',
      },
    };
    final path = TicketInputContextBuilder(tmp.path).build(
      'PROJ-3',
      ticketData: ticket,
    );
    final figmaDir = Directory('$path/figma');
    expect(figmaDir.existsSync(), isTrue);
    expect(
      File('${figmaDir.path}/design_fileKey1_1-2_structure.json').existsSync(),
      isTrue,
    );
    expect(
      File('${figmaDir.path}/design_fileKey1_1-2.png').existsSync(),
      isTrue,
    );
  });
}

void smartContextLinkedTicketTests() {
  test('fetches linked tickets and GitHub inline attachments when configured',
      () async {
    final server = EchoServer();
    await server.start();
    addTearDown(server.stop);
    final base = 'http://127.0.0.1:${server.port}';
    PropertyReader.setOverrides({
      'JIRA_BASE_PATH': base,
      'JIRA_LOGIN_PASS_TOKEN': 'jira-tok',
      'SOURCE_GITHUB_TOKEN': 'gh-tok',
      'SOURCE_GITHUB_BASE_PATH': base,
      'GITHUB_REPOSITORY': 'acme/app',
      'ADO_BASE_PATH': base,
      'ADO_ORGANIZATION': 'org',
      'ADO_PROJECT': 'proj',
      'ADO_PAT_TOKEN': 'ado-tok',
    });
    final tmp = Directory.systemTemp.createTempSync('dmtools_smart_links_');
    addTearDown(() => tmp.deleteSync(recursive: true));

    final ticket = _buildSampleTicketWithLinks();
    final builder = TicketInputContextBuilder(
      tmp.path,
      attachmentDownloader: (_) => utf8.encode('img-bytes'),
    );
    final path = builder.build(
      'PROJ-10',
      ticketData: ticket,
      config: InputContextConfig(depth: 1),
    );
    expect(File('$path/screen.png').existsSync(), isTrue);
    expect(Directory('${tmp.path}/input/PROJ-999').existsSync(), isFalse);
    expect(File('${tmp.path}/input/PROJ-20/ticket.json').existsSync(), isTrue);
    expect(File('${tmp.path}/input/PROJ-30/ticket.json').existsSync(), isTrue);
    expect(File('${tmp.path}/input/gh-42/ticket.json').existsSync(), isTrue);
    expect(File('${tmp.path}/input/55/ticket.json').existsSync(), isTrue);
    expect(
      TicketInputContextBuilder.resolveAuthHeadersForUrl(
        'https://github.com/user-attachments/assets/abc',
        PropertyReader(),
      ),
      {'Authorization': 'Bearer gh-tok'},
    );
  });
}

Map<String, dynamic> _buildSampleTicketWithLinks() => {
      'key': 'PROJ-10',
      'fields': {
        'summary': 'Main ticket',
        'description': 'See PROJ-20, #42, and AB#55.\n'
            '![screen.png](https://github.com/user-attachments/assets/abc)',
        'issuelinks': [
          {
            'type': {'name': 'Cloners', 'inward': 'is cloned by'},
            'inwardIssue': {'key': 'PROJ-999'},
          },
          {
            'type': {'name': 'Relates', 'inward': 'relates to'},
            'outwardIssue': {'key': 'PROJ-30'},
          },
        ],
      },
      'relations': [
        {
          'rel': 'System.LinkTypes.Hierarchy-Forward',
          'url': 'https://dev.azure.com/org/proj/_apis/wit/workItems/66',
        },
      ],
    };

void smartContextJobWiringTests() {
  test('CliAgent and TeammateJob resolve input.ticket automatically', () async {
    final server = EchoServer();
    await server.start();
    addTearDown(server.stop);
    final base = 'http://127.0.0.1:${server.port}';
    PropertyReader.setOverrides({
      'JIRA_BASE_PATH': base,
      'JIRA_LOGIN_PASS_TOKEN': 'jira-tok',
    });
    final tmp = Directory.systemTemp.createTempSync('dmtools_cli_input_');
    addTearDown(() => tmp.deleteSync(recursive: true));

    final params = CliAgentParams.fromJson({
      'input': {'ticket': 'PROJ-55', 'depth': 0},
      'cliCommands': ['echo done'],
      'cleanupInputFolder': false,
      'workingDirectory': tmp.path,
    });
    expect(params.contextId, 'PROJ-55');
    final agentResult = await CliAgent(
      params: params,
      workingDirectory: tmp.path,
    ).run();
    expect(agentResult['success'], isTrue);
    expect(File('${tmp.path}/input/PROJ-55/ticket.json').existsSync(), isTrue);

    final teammateResult = await TeammateJob(
      params: {
        'input': 'PROJ-77',
        'cliCommands': ['echo teammate'],
        'cleanupInputFolder': false,
        'workingDirectory': tmp.path,
      },
      workingDirectory: tmp.path,
    ).run();
    expect(teammateResult['success'], isTrue);
    expect(File('${tmp.path}/input/PROJ-77/ticket.json').existsSync(), isTrue);
  });
}

void parallelInputConfigTests() {
  group('InputContextParallel config & PropertyReader', () {
    test('parses clientConcurrency, parallelClients, and overrides', () {
      expect(clampInputClientConcurrency(0), 1);
      expect(clampInputClientConcurrency(99), maxInputClientConcurrency);
      final cfg = InputContextConfig.fromJson({
        'input': {
          'ticket': 'PROJ-1',
          'parallelClients': false,
          'clientConcurrency': 4,
          'figmaConcurrency': 2,
          'attachmentsConcurrency': 5,
        },
      });
      expect(cfg.parallelClients, isFalse);
      expect(cfg.clientConcurrency, 4);
      expect(cfg.concurrencyFor('figma'), 2);
      expect(cfg.concurrencyFor('attachments'), 5);
      expect(cfg.concurrencyFor('tickets'), 4);
      _verifyPropertyReaderConcurrencyGetters(cfg);
      final child = cfg.forLinkedTicket();
      expect(child.clientConcurrency, 4);
      expect(child.concurrencyFor('figma'), 2);
    });
  });
}

void _verifyPropertyReaderConcurrencyGetters(InputContextConfig cfg) {
  PropertyReader.setOverrides({
    'INPUT_TICKETS_CONCURRENCY': '6',
    'INPUT_CLIENT_CONCURRENCY': '5',
    'CONFLUENCE_PARALLELISM': '7',
    'INPUT_PARALLEL_CLIENTS': 'false',
    'INPUT_DOWNLOAD_RETRY_ATTEMPTS': '3',
    'INPUT_DOWNLOAD_RETRY_BASE_DELAY_MS': '200',
  });
  final reader = PropertyReader();
  expect(reader.isInputParallelClientsEnabled(), isFalse);
  expect(reader.getInputClientConcurrency(), 5);
  expect(reader.getInputConcurrencyForClient('tickets'), 6);
  expect(reader.getInputConcurrencyForClient('confluence'), 7);
  expect(reader.getInputDownloadRetryAttempts(), 3);
  expect(reader.getInputDownloadRetryBaseDelayMs(), 200);
  expect(cfg.concurrencyFor('tickets', reader), 6);
  expect(cfg.concurrencyFor('confluence', reader), 7);
  expect(cfg.concurrencyFor('jira', reader), 5);
  expect(InputContextConfig().isParallelClientsEnabled(reader), isFalse);
}

void parallelInputResilienceTests() {
  group('InputContextParallel resilience', () {
    test('downloadAttachmentBytesResilient retries 429/503 and stops on 404',
        () {
      final sleeps = <int>[];
      var calls = 0;
      final bytes = downloadAttachmentBytesResilient(
        'https://jira.example.com/secure/attachment/1/spec.txt',
        PropertyReader(),
        baseDelayMs: 100,
        sleepFn: sleeps.add,
        httpGet: (_, __) => switch (++calls) {
          1 => SyncHttpResponse(429, 'rate limit', {'Retry-After': '1'}),
          2 => SyncHttpResponse(503, 'unavailable'),
          _ => SyncHttpResponse(200, 'ok-payload'),
        },
      );
      expect(utf8.decode(bytes!), 'ok-payload');
      expect(calls, 3);
      expect(sleeps.first, 1000);
      final notFound = downloadAttachmentBytesResilient(
        'https://jira.example.com/secure/attachment/1/missing.txt',
        PropertyReader(),
        httpGet: (_, __) => SyncHttpResponse(404, 'not found'),
      );
      expect(notFound, isNull);
    });
  });
}

void parallelInputExecutionTests() {
  group('InputContextParallel execution', () {
    test('runInputContextWorkerJob and runBoundedClientJobs execute inline',
        () async {
      final server = EchoServer();
      await server.start();
      addTearDown(server.stop);
      final base = 'http://127.0.0.1:${server.port}';
      _configureAllIntegrations(base);
      final tmp = Directory.systemTemp.createTempSync('dmtools_par_jobs_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      Directory('${tmp.path}/figma').createSync(recursive: true);
      final res = runBoundedClientJobs(
        _buildSampleParallelJobs(base, tmp.path),
        pool: InputContextParallelPools.attachmentsPool(3),
        maxConcurrency: 3,
      );
      expect(res.length, 4);
      expect(res[0]?['ok'], isTrue);
      expect(res[1]?['key'], 'PROJ-20');
      expect(res[2]?['ok'], isTrue);
      expect(res[3]?['ok'], isTrue);
    });

    test('bootAll and parallel pools execute ticket context build end-to-end',
        () async {
      final server = EchoServer();
      await server.start();
      addTearDown(server.stop);
      addTearDown(InputContextParallelPools.disposeAll);
      final base = 'http://127.0.0.1:${server.port}';
      _configureAllIntegrations(base);
      await InputContextParallelPools.bootAll(PropertyReader());
      final tmp = Directory.systemTemp.createTempSync('dmtools_par_e2e_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final ticket = _buildParallelE2eTicket(base);
      final path = TicketInputContextBuilder(tmp.path).build(
        'PROJ-100',
        ticketData: ticket,
        config: InputContextConfig(depth: 1),
      );
      expect(File('$path/att1.txt').existsSync(), isTrue);
      expect(File('$path/att2.txt').existsSync(), isTrue);
      expect(Directory('$path/confluence').existsSync(), isTrue);
      expect(Directory('$path/figma').existsSync(), isTrue);
      expect(
          File('${tmp.path}/input/PROJ-20/ticket.json').existsSync(), isTrue);
      expect(
          File('${tmp.path}/input/PROJ-30/ticket.json').existsSync(), isTrue);
    });
  });
}

void _configureAllIntegrations(String base) {
  PropertyReader.setOverrides({
    'JIRA_BASE_PATH': base,
    'JIRA_LOGIN_PASS_TOKEN': 'jira-tok',
    'CONFLUENCE_BASE_PATH': base,
    'CONFLUENCE_LOGIN_PASS_TOKEN': 'conf-tok',
    'FIGMA_BASE_PATH': '$base/figdl/v1',
    'FIGMA_TOKEN': 'fig-tok',
    'INPUT_CLIENT_CONCURRENCY': '2',
    'CONFLUENCE_PARALLELISM': '2',
  });
}

List<SyncParallelJob> _buildSampleParallelJobs(String base, String dir) {
  final overrides = capturePropertyOverrides();
  return <SyncParallelJob>[
    SyncParallelJob(
      index: 0,
      kind: kInputJobAttachmentDownload,
      args: {
        'url': '$base/secure/attachment/1/a.txt',
        'outPath': '$dir/a.txt',
        'overrides': overrides,
      },
    ),
    SyncParallelJob(
      index: 1,
      kind: kInputJobFetchTicket,
      args: {'key': 'PROJ-20', 'overrides': overrides},
    ),
    SyncParallelJob(
      index: 2,
      kind: kInputJobFigmaRef,
      args: {
        'figmaDir': '$dir/figma',
        'url': 'https://www.figma.com/design/fileKey1/App?node-id=1-2',
        'index': 1,
        'includeComments': true,
        'includeAttachments': false,
        'overrides': overrides,
      },
    ),
    SyncParallelJob(
      index: 3,
      kind: kInputJobConfluenceLane,
      args: {
        'urls': ['$base/wiki/spaces/ENG/pages/777/Hi'],
        'outDir': '$dir/confluence',
        'depth': 1,
        'downloadAttachments': false,
        'includeComments': false,
        'overrides': overrides,
      },
    ),
  ];
}

Map<String, dynamic> _buildParallelE2eTicket(String base) => {
      'key': 'PROJ-100',
      'fields': {
        'summary': 'Parallel ticket',
        'description': 'Doc: $base/wiki/spaces/ENG/pages/777/Hi '
            'UI1: https://www.figma.com/design/fileKey1/App?node-id=1-2 '
            'UI2: https://www.figma.com/design/fileKey2/App?node-id=3-4 '
            'Links: PROJ-20 and PROJ-30',
        'attachment': [
          {
            'filename': 'att1.txt',
            'content': '$base/secure/attachment/1/a.txt'
          },
          {
            'filename': 'att2.txt',
            'content': '$base/secure/attachment/2/b.txt'
          },
        ],
      },
    };
