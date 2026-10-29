/// Attachment-downloading tests for TicketInputContextBuilder.
library;

import 'dart:convert';
import 'dart:io';

import 'package:dmtools/dmtools.dart';
import 'package:test/test.dart';

import '../js/echo_server_helper.dart';

void main() {
  jiraAttachmentsTests();
  adoAttachmentsTests();
  attachmentSkipAllTests();
  attachmentSkipVideoTests();
  attachmentResilienceTests();
  authHeadersResolutionTests();
  httpDownloaderTests();
  httpRedirectTests();
}

void jiraAttachmentsTests() {
  group('TicketInputContextBuilder — Jira attachments', () {
    test('downloads Jira fields.attachment and sanitizes filenames', () {
      final tmp = _createTempDir();
      final requestedUrls = <String>[];
      try {
        final builder = TicketInputContextBuilder(
          tmp.path,
          attachmentDownloader: (url) {
            requestedUrls.add(url);
            return utf8.encode('content-for-$url');
          },
        );
        builder.build('PROJ-1', ticketData: {
          'key': 'PROJ-1',
          'fields': {
            'summary': 'Bug with logs',
            'attachment': [
              {
                'filename': 'screenshot.png',
                'content': 'https://jira.example.com/secure/attachment/1/s.png',
              },
              {
                'name': r'sub/dir\charles.har',
                'url': 'https://jira.example.com/secure/attachment/2/c.har',
              },
            ],
          },
        });
        expect(requestedUrls, hasLength(2));
        final dir = '${tmp.path}/input/PROJ-1';
        expect(
          File('$dir/screenshot.png').readAsStringSync(),
          'content-for-https://jira.example.com/secure/attachment/1/s.png',
        );
        expect(
          File('$dir/sub_dir_charles.har').readAsStringSync(),
          'content-for-https://jira.example.com/secure/attachment/2/c.har',
        );
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });
  });
}

void adoAttachmentsTests() {
  group('TicketInputContextBuilder — ADO attachments', () {
    test('downloads ADO AttachedFile relations and embedded HTML images', () {
      final tmp = _createTempDir();
      try {
        final builder = TicketInputContextBuilder(
          tmp.path,
          attachmentDownloader: (url) => utf8.encode('ado:$url'),
        );
        builder.build('99', ticketData: _adoTicketWithAttachments());
        final dir = '${tmp.path}/input/99';
        expect(File('$dir/trace.log').existsSync(), isTrue);
        expect(File('$dir/from_query.png').existsSync(), isTrue);
        expect(File('$dir/fallback-id').existsSync(), isTrue);
        expect(File('$dir/inline.png').existsSync(), isTrue);
        expect(File('$dir/attachment_emb-42.png').existsSync(), isTrue);
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });
  });
}

void attachmentSkipAllTests() {
  group('TicketInputContextBuilder — skipAllAttachments', () {
    test('skips all attachments when skipAllAttachments or !includeAttachments',
        () {
      final tmp = _createTempDir();
      var calls = 0;
      try {
        final builder = TicketInputContextBuilder(
          tmp.path,
          attachmentDownloader: (_) {
            calls++;
            return [1, 2, 3];
          },
        );
        final ticket = {
          'key': 'PROJ-1',
          'fields': {
            'attachment': [
              {'filename': 'a.png', 'content': 'https://example.com/a.png'},
            ],
          },
        };
        builder.build('P-1', ticketData: ticket, skipAllAttachments: true);
        builder.build('P-2', ticketData: ticket, includeAttachments: false);
        expect(calls, 0);
        expect(File('${tmp.path}/input/P-1/a.png').existsSync(), isFalse);
        expect(File('${tmp.path}/input/P-2/a.png').existsSync(), isFalse);
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });
  });
}

void attachmentSkipVideoTests() {
  group('TicketInputContextBuilder — skipVideoAttachments', () {
    test('skips video files when skipVideoAttachments is true', () {
      final tmp = _createTempDir();
      try {
        final builder = TicketInputContextBuilder(
          tmp.path,
          skipVideoAttachments: true,
          attachmentDownloader: (_) => [42],
        );
        builder.build('PROJ-1', ticketData: {
          'key': 'PROJ-1',
          'fields': {
            'attachment': [
              {'filename': 'demo.MP4', 'content': 'https://example.com/1'},
              {'filename': 'clip.mov', 'content': 'https://example.com/2'},
              {'filename': 'screen.png', 'content': 'https://example.com/3'},
            ],
          },
        });
        final dir = '${tmp.path}/input/PROJ-1';
        expect(File('$dir/demo.MP4').existsSync(), isFalse);
        expect(File('$dir/clip.mov').existsSync(), isFalse);
        expect(File('$dir/screen.png').existsSync(), isTrue);
        expect(TicketInputContextBuilder.isVideoFile(null), isFalse);
        expect(TicketInputContextBuilder.isVideoFile('a.webm'), isTrue);
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });
  });
}

void attachmentResilienceTests() {
  group('TicketInputContextBuilder — error resilience', () {
    test('continues when an attachment download throws or returns null', () {
      final tmp = _createTempDir();
      try {
        final builder = TicketInputContextBuilder(
          tmp.path,
          attachmentDownloader: (url) {
            if (url.contains('throw')) throw StateError('network down');
            if (url.contains('null')) return null;
            return utf8.encode('ok');
          },
        );
        builder.build('PROJ-1', ticketData: {
          'key': 'PROJ-1',
          'attachments': [
            {'name': 'bad1.png', 'url': 'https://example.com/throw'},
            {'name': 'bad2.png', 'url': 'https://example.com/null'},
            {'name': '', 'url': 'https://example.com/empty'},
            {'name': 'good.png', 'url': 'https://example.com/good'},
          ],
        });
        final dir = '${tmp.path}/input/PROJ-1';
        expect(File('$dir/bad1.png').existsSync(), isFalse);
        expect(File('$dir/bad2.png').existsSync(), isFalse);
        expect(File('$dir/good.png').readAsStringSync(), 'ok');
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });
  });
}

void authHeadersResolutionTests() {
  group('TicketInputContextBuilder.resolveAuthHeadersForUrl', () {
    test('resolves Jira and ADO auth headers for matching hosts', () async {
      await PropertyReader.runWithOverrides(
        {
          'JIRA_BASE_PATH': 'https://jira.acme.com',
          'JIRA_LOGIN_PASS_TOKEN': 'jtok',
          'JIRA_AUTH_TYPE': 'Bearer',
          'ADO_PAT_TOKEN': 'adopat',
        },
        () async {
          final reader = PropertyReader();
          final jiraHeaders =
              TicketInputContextBuilder.resolveAuthHeadersForUrl(
            'https://jira.acme.com/secure/attachment/1/a.png',
            reader,
          );
          expect(jiraHeaders?['Authorization'], 'Bearer jtok');
          expect(jiraHeaders?['X-Atlassian-Token'], 'nocheck');

          final adoHeaders = TicketInputContextBuilder.resolveAuthHeadersForUrl(
            'https://dev.azure.com/org/proj/_apis/wit/attachments/1',
            reader,
          );
          expect(
            adoHeaders?['Authorization'],
            'Basic ${base64Encode(utf8.encode(':adopat'))}',
          );

          final other = TicketInputContextBuilder.resolveAuthHeadersForUrl(
            'https://unrelated.example.org/file.png',
            reader,
          );
          expect(other, isNull);
        },
      );
    });
  });
}

void httpDownloaderTests() {
  group('TicketInputContextBuilder — HTTP downloader', () {
    test('default HTTP downloader fetches 200 and skips 404', () async {
      if (!hasPython3()) return;
      final server = EchoServer();
      await server.start();
      final tmp = _createTempDir();
      try {
        final base = 'http://127.0.0.1:${server.port}';
        TicketInputContextBuilder(tmp.path).build('PROJ-HTTP', ticketData: {
          'key': 'PROJ-HTTP',
          'fields': {
            'attachment': [
              {
                'filename': 'shot.png',
                'content': '$base/download/attachments/1/shot.png',
              },
              {
                'filename': 'missing.html',
                'content': '$base/dt-html/missing',
              },
            ],
          },
        });
        final dir = '${tmp.path}/input/PROJ-HTTP';
        expect(File('$dir/shot.png').readAsStringSync(), 'PNG-fixture-bytes');
        expect(File('$dir/missing.html').existsSync(), isFalse);
      } finally {
        server.stop();
        tmp.deleteSync(recursive: true);
      }
    });
  });
}

void httpRedirectTests() {
  group('TicketInputContextBuilder — Jira Cloud 303 redirect (gh-461)', () {
    test('follows 303 redirect to media CDN without leaking Jira Basic auth',
        () async {
      if (!hasPython3()) return;
      final jiraServer = EchoServer();
      final mediaServer = EchoServer();
      await jiraServer.start();
      await mediaServer.start();
      final tmp = _createTempDir();
      try {
        final jiraBase = 'http://127.0.0.1:${jiraServer.port}';
        final mediaTarget = Uri.encodeQueryComponent(
          'http://127.0.0.1:${mediaServer.port}/media/file/1/binary',
        );
        await PropertyReader.runWithOverrides(
          {
            'JIRA_BASE_PATH': jiraBase,
            'JIRA_LOGIN_PASS_TOKEN': 'dXNlcjp0b2s=',
          },
          () async {
            TicketInputContextBuilder(
              tmp.path,
              propertyReader: PropertyReader(basePath: tmp.path),
            ).build('MAPC-8190', ticketData: {
              'key': 'MAPC-8190',
              'fields': {
                'attachment': [
                  {
                    'filename': 'screenshot.png',
                    'content':
                        '$jiraBase/rest/api/2/attachment/content/10001?to=$mediaTarget',
                  },
                ],
              },
            });
          },
          basePath: tmp.path,
        );
        final dir = '${tmp.path}/input/MAPC-8190';
        expect(
          File('$dir/screenshot.png').readAsStringSync(),
          'CDN-binary-bytes',
        );
      } finally {
        jiraServer.stop();
        mediaServer.stop();
        tmp.deleteSync(recursive: true);
      }
    });
  });
}

Map<String, dynamic> _adoTicketWithAttachments() => {
      'id': 99,
      'fields': {
        'System.Title': 'ADO bug',
        'System.Description': '<p>See <img src="https://dev.azure.com/o/p/'
            '_apis/wit/attachments/1?fileName=inline.png&amp;download=true">'
            ' and <img src="https://dev.azure.com/o/p/_apis/wit/attachments/'
            'emb-42?api-version=7.0"></p>',
      },
      'relations': [
        {
          'rel': 'System.LinkTypes.Hierarchy-Reverse',
          'url': 'https://dev.azure.com/o/p/_apis/wit/workItems/1',
        },
        {
          'rel': 'AttachedFile',
          'url': 'https://dev.azure.com/o/p/_apis/wit/attachments/a1',
          'attributes': {'name': 'trace.log'},
        },
        {
          'rel': 'AttachedFile',
          'url': 'https://dev.azure.com/o/p/_apis/wit/attachments/a2'
              '?fileName=from_query.png',
        },
        {
          'rel': 'AttachedFile',
          'url': 'https://dev.azure.com/o/p/_apis/wit/attachments/fallback-id'
              '?api-version=7.0',
        },
      ],
    };

Directory _createTempDir() =>
    Directory.systemTemp.createTempSync('ticket_att_test_');
