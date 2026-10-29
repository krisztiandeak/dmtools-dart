import 'dart:convert';
import 'dart:io';

import 'package:dmtools/src/config/property_reader.dart';
import 'package:dmtools/src/js/sync_tools/confluence_sync_tools.dart';
import 'package:test/test.dart';

import '../echo_server_helper.dart';

/// Shared per-test fixtures, (re)assigned by `main`'s `setUp`.
late EchoServer server;
late ConfluenceSyncTools tools;

/// Tests for the 15 Java-named Confluence tools ported under gh-191
/// (Java `Confluence.java` @MCPTool parity: `content_by_title…`,
/// `find_content…`, `find_or_create`, `get_children_by_name`,
/// `get_content_attachments`, user profiles, `search_content_by_text`,
/// `update_page_with_history`, `contents_by_urls`, uploads, and
/// `download_pages`).
///
/// Runs against the shared Python echo server — the Dart event loop is
/// frozen during `Process.runSync('curl', …)`, so the server must be a
/// separate process.
void main() {
  setUpAll(() => PropertyReader.testIsolation = true);
  tearDownAll(() {
    PropertyReader.testIsolation = false;
    PropertyReader.testEnvironment.clear();
  });

  setUp(() async {
    server = EchoServer();
    await server.start();
    PropertyReader.setOverrides({
      'CONFLUENCE_BASE_PATH': 'http://127.0.0.1:${server.port}',
      'CONFLUENCE_LOGIN_PASS_TOKEN': 'conf-token',
      'CONFLUENCE_AUTH_TYPE': 'Basic',
      'CONFLUENCE_DEFAULT_SPACE': 'ENG',
    });
    tools = ConfluenceSyncTools(PropertyReader());
  });

  tearDown(() {
    PropertyReader.clearOverrides();
    server.stop();
  });

  contentByTitleTests();
  findToolTests();
  findOrCreateChildrenTests();
  profileToolTests();
  searchToolTests();
  searchSpaceClauseTests();
  updateToolTests();
  contentsByUrlsTests();
  contentsByUrlsMarkdownTests();
  uploadAttachmentToolTests();
  uploadAttachmentsToolTests();
  downloadPagesToolTests();
  downloadPagesResolverTests();
  downloadPagesAttachmentsTests();
  inlineCommentToolTests();
}

void contentByTitleTests() {
  group('confluence title/find tools', () {
    test('content_by_title lists in the default space with format', () {
      final result =
          tools.dispatch('confluence_content_by_title', {'title': 'Docs'});
      // Java serializes the ContentResult JSONModel verbatim — the full
      // listing object, shape-identical with the async/MCP surface.
      final listing = jsonDecode(result) as Map;
      final results = listing['results'] as List;
      expect(results, hasLength(2));
      expect(results.first['id'], '801');
      expect(listing.containsKey('results'), isTrue);
    });

    test('content_by_title requires the default space', () {
      PropertyReader.setOverrides({
        'CONFLUENCE_BASE_PATH': 'http://127.0.0.1:${server.port}',
        'CONFLUENCE_LOGIN_PASS_TOKEN': 'conf-token',
        'CONFLUENCE_AUTH_TYPE': 'Basic',
      });
      expect(
        jsonDecode(
            tools.dispatch('confluence_content_by_title', {'title': 'Docs'})),
        {'error': 'Default space not set'},
      );
    });

    test('content_by_title falls back to default space when space is empty',
        () {
      final listing = jsonDecode(tools.dispatch(
        'confluence_content_by_title',
        {'title': 'Docs', 'space': ''},
      )) as Map;
      expect(listing['results'], hasLength(2));
    });

    test('content_by_title prefers explicit space over default space', () {
      final listing = jsonDecode(tools.dispatch(
        'confluence_content_by_title',
        {'title': 'Docs', 'space': 'DEV'},
      )) as Map;
      expect(listing['results'], hasLength(2));
    });

    test('content_by_title_and_space lists by title in a space', () {
      final listing = jsonDecode(tools.dispatch(
        'confluence_content_by_title_and_space',
        {'title': 'Docs', 'space': 'DEV'},
      )) as Map;
      final results = listing['results'] as List;
      expect(results, hasLength(2));
      expect(results.first['id'], '801');
    });
  });
}

void findToolTests() {
  group('confluence title/find tools', () {
    test('find_content returns the first match', () {
      final result =
          tools.dispatch('confluence_find_content', {'title': 'Docs'});
      expect(jsonDecode(result)['id'], '801');
    });

    test('find_content converts to markdown on request', () {
      final result = tools.dispatch(
          'confluence_find_content', {'title': 'Docs', 'format': 'md'});
      expect(jsonDecode(result)['body']['storage']['value'], 'found');
    });

    test('find_content falls back to default space when space is empty', () {
      final result = tools.dispatch(
        'confluence_find_content',
        {'title': 'Docs', 'space': ' '},
      );
      expect(jsonDecode(result)['id'], '801');
    });

    test('find_content prefers explicit space over default space', () {
      final result = tools.dispatch(
        'confluence_find_content',
        {'title': 'Docs', 'space': 'DEV'},
      );
      expect(jsonDecode(result)['id'], '801');
    });

    test('find_content requires the default space when unconfigured', () {
      PropertyReader.setOverrides({
        'CONFLUENCE_BASE_PATH': 'http://127.0.0.1:${server.port}',
        'CONFLUENCE_LOGIN_PASS_TOKEN': 'conf-token',
        'CONFLUENCE_AUTH_TYPE': 'Basic',
        'CONFLUENCE_DEFAULT_SPACE': '',
      });
      expect(
        jsonDecode(
            tools.dispatch('confluence_find_content', {'title': 'Docs'})),
        {'error': 'Default space not set'},
      );
    });

    test('find_content_by_title_and_space returns null when empty', () {
      final result = tools.dispatch(
        'confluence_find_content_by_title_and_space',
        {'title': 'Nope', 'space': 'ENG'},
      );
      expect(jsonDecode(result), isNull);
    });
  });
}

void findOrCreateChildrenTests() {
  group('confluence title/find tools', () {
    test('find_or_create returns the existing page without creating', () {
      final body = jsonDecode(tools.dispatch(
        'confluence_find_or_create',
        {'title': 'Docs', 'parentId': '7', 'body': '<p>new</p>'},
      )) as Map;
      expect(body['id'], '801');
    });

    test('find_or_create creates in the default space when not found', () {
      final body = jsonDecode(tools.dispatch(
        'confluence_find_or_create',
        {'title': 'Nope', 'parentId': '7', 'body': '<p>new</p>'},
      )) as Map;
      expect(body['method'], 'POST');
      expect(body['path'], '/wiki/rest/api/content');
      final payload = jsonDecode(body['body'] as String);
      expect(payload['space']['key'], 'ENG');
      expect(payload['ancestors'], [
        {'id': '7'},
      ]);
    });

    test('get_children_by_name resolves the parent then lists children', () {
      final results = jsonDecode(tools.dispatch(
        'confluence_get_children_by_name',
        {'spaceKey': 'ENG', 'contentName': 'Parent'},
      )) as List;
      expect(results, hasLength(1));
      expect(results.single['id'], '902');
      expect(results.single['title'], 'Child Page');
    });

    test('get_children_by_name errors when the parent is not found', () {
      expect(
        jsonDecode(tools.dispatch('confluence_get_children_by_name',
            {'spaceKey': 'ENG', 'contentName': 'Ghost'})),
        {'error': 'Content not found: Ghost'},
      );
    });
  });
}

void profileToolTests() {
  group('confluence profile and search tools', () {
    test('get_content_attachments returns the results array', () {
      final results = jsonDecode(tools.dispatch(
          'confluence_get_content_attachments', {'contentId': '42'})) as List;
      expect(results, hasLength(3));
      expect(results.first['id'], 'a1');
    });

    test('get_current_user_profile GETs user/current', () {
      final body =
          jsonDecode(tools.dispatch('confluence_get_current_user_profile', {}))
              as Map;
      expect(body['method'], 'GET');
      expect(body['path'], '/wiki/rest/api/user/current');
    });

    test('get_user_profile_by_id encodes the accountId', () {
      final body = jsonDecode(tools.dispatch(
        'confluence_get_user_profile_by_id',
        {'userId': '1234:abc'},
      )) as Map;
      // Encoded like every other query built here — raw '&'/'#'/spaces in
      // an accountId would break or mutate the query string.
      expect(body['path'], '/wiki/rest/api/user?accountId=1234%3Aabc');
    });

    test('get_user_profile_by_id keeps query-safe accountIds readable', () {
      final body = jsonDecode(tools.dispatch(
        'confluence_get_user_profile_by_id',
        {'userId': '1234-abc-def'},
      )) as Map;
      expect(body['path'], '/wiki/rest/api/user?accountId=1234-abc-def');
    });
  });
}

void searchToolTests() {
  group('confluence profile and search tools', () {
    test('search_content_by_text scopes CQL to default space when configured',
        () {
      final body = jsonDecode(tools.dispatch(
          'confluence_search_content_by_text', {'query': 'docs'})) as Map;
      expect(body['path'], startsWith('/wiki/rest/api/content/search?'));
      expect(
        body['path'],
        contains(
          'cql=${Uri.encodeQueryComponent('(title ~ "docs" OR text ~ "docs") AND space = "ENG" ORDER BY lastModified ASC')}',
        ),
      );
      expect(body['path'], contains('limit=20'));
      expect(
        body['path'],
        contains('expand=title%2Cbody.excerpt%2Chistory%2Cspace'),
      );
    });

    test(
        'search_content_by_text omits space filter when default space is unset',
        () {
      PropertyReader.setOverrides({
        'CONFLUENCE_BASE_PATH': 'http://127.0.0.1:${server.port}',
        'CONFLUENCE_LOGIN_PASS_TOKEN': 'conf-token',
        'CONFLUENCE_AUTH_TYPE': 'Basic',
      });
      final body = jsonDecode(tools.dispatch(
          'confluence_search_content_by_text', {'query': 'docs'})) as Map;
      expect(
        body['path'],
        contains(
          'cql=${Uri.encodeQueryComponent('(title ~ "docs" OR text ~ "docs") ORDER BY lastModified ASC')}',
        ),
      );
    });
  });
}

void searchSpaceClauseTests() {
  group('confluence search space clause and limit tools', () {
    test(
        'search_content_by_text skips default space when query has space clause',
        () {
      final body = jsonDecode(tools.dispatch(
        'confluence_search_content_by_text',
        {'query': 'docs AND space = "DEV"'},
      )) as Map;
      expect(
        body['path'],
        contains(
          'cql=${Uri.encodeQueryComponent('(title ~ "docs AND space = "DEV"" OR text ~ "docs AND space = "DEV"") ORDER BY lastModified ASC')}',
        ),
      );
    });

    test('search_content_by_text unwraps results when present', () {
      // The title-listing fixture answers any expand with
      // body.storage,body.export_view — but content/search carries its own
      // expand (title,body.excerpt,...), so the search route keeps the bare
      // echo and the handler passes the raw body through.
      final body = jsonDecode(tools.dispatch(
        'confluence_search_content_by_text',
        {'query': 'docs', 'limit': 5},
      )) as Map;
      expect(body['method'], 'GET');
      expect(body['path'], contains('limit=5'));
    });
  });
}

void updateToolTests() {
  group('confluence update/URL/upload tools', () {
    test('update_page_with_history PUTs version+1 with the comment', () {
      final body =
          jsonDecode(tools.dispatch('confluence_update_page_with_history', {
        'contentId': '555',
        'title': 'Up',
        'parentId': '7',
        'body': '<p>up</p>',
        'space': 'ENG',
        'historyComment': 'gh-191 update',
      })) as Map;
      expect(body['method'], 'PUT');
      expect(body['path'], '/wiki/rest/api/content/555');
      final payload = jsonDecode(body['body'] as String);
      expect(payload['version']['number'], 4);
      expect(payload['version']['message'], 'gh-191 update');
    });

    test('update_page_with_history surfaces the version-fetch failure', () {
      expect(
        jsonDecode(tools.dispatch('confluence_update_page_with_history', {
          'contentId': '404',
          'title': 'Up',
          'parentId': '7',
          'body': '<p>up</p>',
          'space': 'ENG',
          'historyComment': 'x',
        })),
        {'error': 'Failed to fetch version for 404'},
      );
    });
  });
}

void contentsByUrlsTests() {
  group('confluence update/URL/upload tools', () {
    test('contents_by_urls resolves ids and skips failures', () {
      final base = 'http://127.0.0.1:${server.port}';
      final results = jsonDecode(tools.dispatch('confluence_contents_by_urls', {
        'urlStrings': [
          '$base/wiki/spaces/ENG/pages/777/Hi',
          '$base/l/redirect-me',
          '$base/definitely-not-a-page-url',
          '',
        ],
      })) as List;
      // The direct page URL and the /l/ short link both resolve to 777;
      // the unknown URL is skipped like Java (logger.error + continue).
      expect(results, hasLength(2));
      expect(results.first['id'], '777');
    });

    test('contents_by_urls resolves display URLs via title+space', () {
      final base = 'http://127.0.0.1:${server.port}';
      final results = jsonDecode(tools.dispatch('confluence_contents_by_urls', {
        'urlStrings': ['$base/wiki/display/ENG/Hi'],
      })) as List;
      // The /display/{space}/{title} shape routes through the title+space
      // lookup (Java contentByUrl display-ref branch) and returns the page
      // the server lists for that title.
      expect(results, hasLength(1));
      expect(results.single['id'], '801');
      expect(results.single['title'], 'Found Page');
    });

    test('contents_by_urls follows chained short links', () {
      final base = 'http://127.0.0.1:${server.port}';
      final results = jsonDecode(tools.dispatch('confluence_contents_by_urls', {
        'urlStrings': ['$base/l/chain'],
      })) as List;
      // /l/chain → /dt-redir2 → page 777: each hop must be requested at
      // its own URL, not the original one re-fetched five times.
      expect(results, hasLength(1));
      expect(results.single['id'], '777');
    });

    test('contents_by_urls skips a dead short link without aborting', () {
      final base = 'http://127.0.0.1:${server.port}';
      final results = jsonDecode(tools.dispatch('confluence_contents_by_urls', {
        'urlStrings': [
          '$base/l/dead',
          '$base/wiki/spaces/ENG/pages/777/Hi',
        ],
      })) as List;
      // The 404 short link degrades to a skip (like Java logging +
      // continuing); the healthy URL still resolves.
      expect(results, hasLength(1));
      expect(results.single['id'], '777');
    });
  });
}

/// `confluence_contents_by_urls` Markdown conversion of the resolved pages.
void contentsByUrlsMarkdownTests() {
  group('confluence update/URL/upload tools', () {
    test('contents_by_urls converts storage on request', () {
      final base = 'http://127.0.0.1:${server.port}';
      final results = jsonDecode(tools.dispatch('confluence_contents_by_urls', {
        'urlStrings': ['$base/wiki/spaces/ENG/pages/777/Hi'],
        'format': 'md',
      })) as List;
      expect(results.single['body']['storage']['value'], 'hi');
    });
  });
}

void uploadAttachmentToolTests() {
  group('confluence update/URL/upload tools', () {
    test('upload_attachment skips an existing name by default', () {
      final dir = Directory.systemTemp.createTempSync('dmtools_upl_');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/exists.txt').writeAsStringSync('data');
      final result = jsonDecode(tools.dispatch('confluence_upload_attachment', {
        'contentId': '555',
        'file': '${dir.path}/exists.txt',
      })) as Map;
      expect(result['status'], 'skipped');
    });

    test('upload_attachment uploads a new file', () {
      final dir = Directory.systemTemp.createTempSync('dmtools_upl2_');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/fresh.txt').writeAsStringSync('data');
      final result = jsonDecode(tools.dispatch('confluence_upload_attachment', {
        'contentId': '555',
        'file': '${dir.path}/fresh.txt',
        'updateIfExists': true,
      })) as Map;
      expect(result['status'], 'created');
    });

    test('upload_attachment errors on a missing file', () {
      expect(
        jsonDecode(tools.dispatch('confluence_upload_attachment', {
          'contentId': '555',
          'file': '/nonexistent-dmtools/file.txt',
        })),
        {'error': 'File not found: /nonexistent-dmtools/file.txt'},
      );
    });
  });
}

void uploadAttachmentsToolTests() {
  group('confluence update/URL/upload tools', () {
    test('upload_attachments summarizes created and skipped files', () {
      final dir = Directory.systemTemp.createTempSync('dmtools_upls_');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/exists.txt').writeAsStringSync('a');
      File('${dir.path}/fresh.txt').writeAsStringSync('b');
      Directory('${dir.path}/sub').createSync(); // skipped: not a file
      final summary =
          jsonDecode(tools.dispatch('confluence_upload_attachments', {
        'contentId': '555',
        'directory': dir.path,
      })) as Map;
      expect(summary['skipped'], ['exists.txt']);
      expect(summary['uploaded'], ['fresh.txt']);
      expect(summary['failed'], isEmpty);
    });

    test('upload_attachments errors on a missing directory', () {
      expect(
        jsonDecode(tools.dispatch('confluence_upload_attachments', {
          'contentId': '555',
          'directory': '/nonexistent-dmtools-dir',
        })),
        {'error': 'Directory not found: /nonexistent-dmtools-dir'},
      );
    });
  });
}

void downloadPagesToolTests() {
  group('confluence update/URL/upload tools', () {
    test('download_pages writes markdown and follows children to depth', () {
      final out = Directory.systemTemp.createTempSync('dmtools_dl_');
      addTearDown(() => out.deleteSync(recursive: true));
      final base = 'http://127.0.0.1:${server.port}';
      final result = tools.dispatch('confluence_download_pages', {
        'urlStrings': ['$base/wiki/spaces/ENG/pages/777/Hi'],
        'outputPath': out.path,
        'depth': 2,
      });
      expect(result, 'Downloaded 2 Confluence page(s) to ${out.path}');
      expect(
        File('${out.path}/Hi Page.md').readAsStringSync(),
        'hi',
      );
      expect(
        File('${out.path}/Child Page.md').readAsStringSync(),
        'kid',
      );
    });
  });
}

/// gh-347: the downloader pipeline materializes excerpt includes (in the
/// page's own space) and resolves user mentions before converting.
void downloadPagesResolverTests() {
  group('confluence download_pages resolvers', () {
    test('download_pages inlines excerpt includes and resolves mentions', () {
      final out = Directory.systemTemp.createTempSync('dmtools_dl3_');
      addTearDown(() => out.deleteSync(recursive: true));
      final base = 'http://127.0.0.1:${server.port}';
      final result = tools.dispatch('confluence_download_pages', {
        'urlStrings': ['$base/wiki/spaces/DOCS/pages/888/Main_Page'],
        'outputPath': out.path,
        'depth': 1,
      });
      expect(result, 'Downloaded 1 Confluence page(s) to ${out.path}');
      final markdown = File('${out.path}/Main Page.md').readAsStringSync();
      // The excerpt-include macro was replaced by the table-excerpt body
      // of "Source", resolved in the page's space DOCS (Java 932e0db0).
      expect(markdown, contains('included-value'));
      expect(markdown, isNot(contains('excerpt-include')));
      // The user mention was resolved via the profile endpoint to
      // @Jane Roe (Java bb1b51e9).
      expect(markdown, contains('@Jane Roe'));
      expect(markdown, isNot(contains('ri:user')));
    });
  });
}

void downloadPagesAttachmentsTests() {
  group('confluence download_pages attachments', () {
    test('download_pages downloads attachments when asked', () {
      final out = Directory.systemTemp.createTempSync('dmtools_dl2_');
      addTearDown(() => out.deleteSync(recursive: true));
      final base = 'http://127.0.0.1:${server.port}';
      tools.dispatch('confluence_download_pages', {
        'urlStrings': ['$base/wiki/spaces/ENG/pages/777/Hi'],
        'outputPath': out.path,
        'depth': 1,
      });
      final bytes =
          File('${out.path}/Hi Page-attachments/shot.png').readAsBytesSync();
      expect(utf8.decode(bytes), 'PNG-fixture-bytes');
      // evil.txt points at an absolute URL on a foreign host (localhost vs
      // the configured 127.0.0.1) — `_links.download` is server-controlled
      // content, so the Confluence credentials must stay home.
      final evil =
          File('${out.path}/Hi Page-attachments/evil.txt').readAsStringSync();
      expect(evil, 'CLEAN');
    });
  });
}

void inlineCommentToolTests() {
  group('confluence inline comment tools', () {
    test('get_page_inline_comments fetches v2 inline comments', () {
      final raw = tools.dispatch('confluence_get_page_inline_comments', {
        'pageId': '777',
        'limit': 25,
      });
      final decoded = jsonDecode(raw) as Map;
      final results = decoded['results'] as List;
      expect(results, hasLength(1));
      expect(results.first['id'], 'ic-1');
    });

    test('reply_to_inline_comment posts storage-formatted reply', () {
      final raw = tools.dispatch('confluence_reply_to_inline_comment', {
        'pageId': '777',
        'commentId': 'ic-1',
        'body': 'Line 1 & <tag>\n\nLine 2',
      });
      final decoded = jsonDecode(raw) as Map;
      expect(decoded['method'], 'POST');
      expect(decoded['path'], '/wiki/api/v2/inline-comments');
      final sent = jsonDecode(decoded['body'] as String) as Map;
      expect(sent['parentCommentId'], 'ic-1');
      expect(
        sent['body']['value'],
        '<p>Line 1 &amp; &lt;tag&gt;</p>\n<p>Line 2</p>',
      );
    });
  });
}
