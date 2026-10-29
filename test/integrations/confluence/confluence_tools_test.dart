import 'package:dmtools/dmtools.dart';
import 'package:test/test.dart';

import 'confluence_test_support.dart';

/// Tests for the [confluenceTools] catalog and [ConfluenceToolExecutor]
/// dispatch.
void main() {
  tearDown(PropertyReader.clearOverrides);
  toolCatalogTests();
  executorDispatchTests();
  downloadAttachmentDispatchTests();
}

/// Looks up a registered tool by name.
ToolDefinition toolNamed(String name) =>
    confluenceTools().firstWhere((t) => t.name == name);

/// Catalog shape: tool count, order, integration, params.
void toolCatalogTests() {
  group('confluenceTools catalog', () {
    final tools = confluenceTools();

    test('registers all tools in declaration order', () {
      expect(tools.map((t) => t.name), _expectedToolOrder);
    });

    test('every tool belongs to the confluence integration', () {
      expect(tools.every((t) => t.integration == 'confluence'), isTrue);
    });
  });

  test('confluence_get_page requires spaceKey and title', () {
    final tool = toolNamed('confluence_get_page');
    expect(tool.params.map((p) => p.name), ['spaceKey', 'title']);
    expect(tool.params.every((p) => p.required), isTrue);
  });

  test('confluence_create_page requires spaceKey, title, body', () {
    final tool = toolNamed('confluence_create_page');
    expect(tool.params.map((p) => p.name), ['spaceKey', 'title', 'body']);
    expect(tool.params.every((p) => p.required), isTrue);
  });

  test('confluence_update_page requires contentId/title/parentId/body/space',
      () {
    final tool = toolNamed('confluence_update_page');
    expect(tool.params.map((p) => p.name),
        ['contentId', 'title', 'parentId', 'body', 'space']);
    expect(tool.params.every((p) => p.required), isTrue);
  });

  test('confluence_search requires cql', () {
    final tool = toolNamed('confluence_search');
    expect(tool.category, 'search');
    expect(tool.params.single.name, 'cql');
    expect(tool.params.single.required, isTrue);
  });
}

/// [ConfluenceToolExecutor.execute] routes each tool name to the right client
/// call.
void executorDispatchTests() {
  group('ConfluenceToolExecutor.execute', () {
    setUp(() {
      _spy = _SpyConfluenceClient(mockHttp((o) => '{}').http);
      _executor = ConfluenceToolExecutor(_spy);
    });

    _executorPageDispatchTests();
    _executorReadDispatchTests();
  });
}

/// Shared fixtures for the executor dispatch groups.
late _SpyConfluenceClient _spy;
late ConfluenceToolExecutor _executor;

/// Page create/update routing tests.
void _executorPageDispatchTests() {
  test('routes confluence_test to testConnection', () async {
    await _executor.execute('confluence_test', {});
    expect(_spy.calls, ['testConnection']);
  });

  test('routes confluence_get_page with spaceKey and title', () async {
    await _executor.execute('confluence_get_page', {
      'spaceKey': 'ENG',
      'title': 'Doc',
    });
    expect(_spy.calls, ['getPage:ENG:Doc']);
  });

  test('routes confluence_create_page with spaceKey, title, body', () async {
    await _executor.execute('confluence_create_page', {
      'spaceKey': 'ENG',
      'title': 'New',
      'body': '<p>hi</p>',
    });
    expect(_spy.calls, ['createPage:ENG:New:<p>hi</p>']);
  });

  test(
      'routes confluence_update_page with contentId/title/parentId/body/'
      'space', () async {
    await _executor.execute('confluence_update_page', {
      'contentId': '42',
      'title': 'Up',
      'parentId': '7',
      'body': '<p>up</p>',
      'space': 'ENG',
    });
    expect(_spy.calls, ['updatePage:42:Up:7:<p>up</p>:ENG']);
  });
}

/// Search/content read routing tests.
void _executorReadDispatchTests() {
  test('routes confluence_search with cql', () async {
    await _executor.execute('confluence_search', {'cql': 'type = page'});
    expect(_spy.calls, ['search:type = page']);
  });

  test('routes confluence_content_by_id with contentId', () async {
    await _executor.execute('confluence_content_by_id', {'contentId': '42'});
    expect(_spy.calls, ['getPageById:42']);
  });

  test('routes confluence_get_children_by_id with contentId', () async {
    await _executor
        .execute('confluence_get_children_by_id', {'contentId': '42'});
    expect(_spy.calls, ['getContentChildren:42']);
  });

  test('throws ArgumentError for an unknown tool', () {
    expect(
        () => _executor.execute('confluence_no_such', {}), throwsArgumentError);
  });
}

/// Download-attachment dispatch through [ConfluenceToolExecutor.execute].
void downloadAttachmentDispatchTests() {
  group('ConfluenceToolExecutor.execute (download attachment)', () {
    late _SpyConfluenceClient spy;
    late ConfluenceToolExecutor executor;

    setUp(() {
      spy = _SpyConfluenceClient(mockHttp((o) => '{}').http);
      executor = ConfluenceToolExecutor(spy);
    });

    test('routes confluence_download_attachment with pageId and attachmentId',
        () async {
      await executor.execute('confluence_download_attachment', {
        'pageId': '42',
        'attachmentId': 'att-1',
      });
      expect(spy.calls, ['downloadAttachment:42:att-1']);
    });
  });
}

/// Records every dispatched call then delegates to the real client logic.
class _SpyConfluenceClient extends ConfluenceClient {
  _SpyConfluenceClient(super.http);

  final List<String> calls = [];

  @override
  Future<Map<String, dynamic>> testConnection() {
    calls.add('testConnection');
    return super.testConnection();
  }

  @override
  Future<Map<String, dynamic>?> getPage(String spaceKey, String title) {
    calls.add('getPage:$spaceKey:$title');
    return super.getPage(spaceKey, title);
  }

  @override
  Future<Map<String, dynamic>> createPage(
    String spaceKey,
    String title,
    String body, {
    String? parentId,
  }) {
    calls.add('createPage:$spaceKey:$title:$body');
    return super.createPage(spaceKey, title, body, parentId: parentId);
  }

  @override
  Future<Map<String, dynamic>> updatePage(
    String contentId,
    String title,
    String parentId,
    String body,
    String space, [
    String historyComment = '',
  ]) {
    calls.add('updatePage:$contentId:$title:$parentId:$body:$space');
    return super.updatePage(
      contentId,
      title,
      parentId,
      body,
      space,
      historyComment,
    );
  }

  @override
  Future<List<Map<String, dynamic>>> search(String query) {
    calls.add('search:$query');
    return super.search(query);
  }

  @override
  Future<String> downloadAttachment(String pageId, String attachmentId) {
    calls.add('downloadAttachment:$pageId:$attachmentId');
    return super.downloadAttachment(pageId, attachmentId);
  }

  @override
  Future<Map<String, dynamic>> getPageById(String id) {
    calls.add('getPageById:$id');
    return super.getPageById(id);
  }

  @override
  Future<List<Map<String, dynamic>>> getContentChildren(String id) {
    calls.add('getContentChildren:$id');
    return super.getContentChildren(id);
  }
}

/// The full tool catalog in declaration order.
const _expectedToolOrder = [
  'confluence_test',
  'confluence_get_page',
  'confluence_get_page_by_id',
  'confluence_create_page',
  'confluence_update_page',
  'confluence_delete_page',
  'confluence_search',
  'confluence_get_spaces',
  'confluence_get_space_by_key',
  'confluence_update_space',
  'confluence_get_space_content',
  'confluence_create_space',
  'confluence_add_label',
  'confluence_get_labels',
  'confluence_get_page_attachments',
  'confluence_download_attachment',
  'confluence_get_blog_posts',
  'confluence_get_content_children',
  'confluence_move_page',
  'confluence_get_page_history',
  'confluence_archive_page',
  'confluence_restore_page',
  'confluence_get_permissions',
  'confluence_add_permission',
  'confluence_get_page_properties',
  'confluence_set_page_property',
  'confluence_get_group_members',
  'confluence_get_user_by_key',
  'confluence_get_watchers',
  'confluence_content_by_id',
  'confluence_get_children_by_id',
  'confluence_sync_markdown_directory',
  // gh-191: the Java-named gap-snapshot tools.
  'confluence_content_by_title',
  'confluence_content_by_title_and_space',
  'confluence_contents_by_urls',
  'confluence_download_pages',
  'confluence_find_content',
  'confluence_find_content_by_title_and_space',
  'confluence_find_or_create',
  'confluence_get_children_by_name',
  'confluence_get_content_attachments',
  'confluence_get_page_inline_comments',
  'confluence_reply_to_inline_comment',
  'confluence_get_current_user_profile',
  'confluence_get_user_profile_by_id',
  'confluence_search_content_by_text',
  'confluence_update_page_with_history',
  'confluence_upload_attachment',
  'confluence_upload_attachments',
];
