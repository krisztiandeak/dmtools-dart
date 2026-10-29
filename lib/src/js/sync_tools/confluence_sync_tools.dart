/// Synchronous Confluence tool executors for the JS tool bridge.
///
/// Public counterpart of the dispatcher's private Confluence section: each
/// handler resolves its config from [PropertyReader], performs blocking HTTP
/// via [SyncHttpClient] (curl subprocess — safe inside QuickJS callbacks),
/// and returns a JSON result string. Tool names, parameters, and URL shapes
/// port the Java `Confluence.java` `@MCPTool` methods; the three legacy
/// handlers (`confluence_search`, `confluence_get_page`,
/// `confluence_create_page`) move here unchanged from the dispatcher so it
/// can drop its private section.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../../config/property_names.dart';
import '../../config/property_reader.dart';
import '../../config/property_reader_getters.dart';
import '../../integrations/confluence/confluence_markdown.dart';
import '../../integrations/confluence/confluence_page_url.dart';
import '../../integrations/confluence/markdown_confluence_sync.dart';
import '../sync_http_client.dart';
import '../sync_parallel.dart';
import 'sync_request_helpers.dart';

part 'confluence_sync_page_ops.dart';
part 'confluence_sync_downloader.dart';
part 'confluence_sync_worker.dart';
part 'confluence_sync_tools_helpers.dart';
part 'confluence_sync_resolvers.dart';

/// Confluence executors: `confluence_*` tool name → JSON result.
class ConfluenceSyncTools {
  final PropertyReader _reader;

  /// Creates Confluence tooling reading config from [reader].
  ConfluenceSyncTools(this._reader);

  /// Tool executors; config is resolved inside each handler.
  Map<String, String Function(Map<String, dynamic> args)> get handlers => {
        'confluence_search': _search,
        'confluence_get_page': _getPage,
        'confluence_create_page': _createPage,
        'confluence_update_page': _updatePage,
        'confluence_content_by_id': _contentById,
        'confluence_get_children_by_id': _getChildrenById,
        'confluence_sync_markdown_directory': _syncMarkdownDirectory,
        'confluence_content_by_title': _contentByTitle,
        'confluence_content_by_title_and_space': _contentByTitleAndSpace,
        'confluence_contents_by_urls': _contentsByUrls,
        'confluence_download_pages': _downloadPages,
        'confluence_find_content': _findContent,
        'confluence_find_content_by_title_and_space':
            _findContentByTitleAndSpace,
        'confluence_find_or_create': _findOrCreate,
        'confluence_get_children_by_name': _getChildrenByName,
        'confluence_get_content_attachments': _getContentAttachments,
        'confluence_get_current_user_profile': _getCurrentUserProfile,
        'confluence_get_user_profile_by_id': _getUserProfileById,
        'confluence_search_content_by_text': _searchContentByText,
        'confluence_update_page_with_history': _updatePageWithHistory,
        'confluence_upload_attachment': _uploadAttachment,
        'confluence_upload_attachments': _uploadAttachments,
        'confluence_get_page_inline_comments': _getPageInlineComments,
        'confluence_reply_to_inline_comment': _replyToInlineComment,
      };

  /// Dispatches a Confluence tool call, mirroring the dispatcher's errors.
  String dispatch(String toolName, Map<String, dynamic> args) {
    final fn = handlers[toolName];
    if (fn == null) return syncErr('Unsupported Confluence tool: $toolName');
    return fn(args);
  }

  /// Builds Confluence config, or `null` when base path / auth is missing.
  ///
  /// Mirrors the dispatcher section this class replaces: `{authType} {token}`
  /// Authorization and the `/wiki/rest/api` suffix (the sync-path convention;
  /// the async [ConfluenceHttpClient] appends only `/rest/api`).
  _Conf? _config() {
    final basePath = _reader.getConfluenceBasePath();
    if (basePath == null || basePath.isEmpty) return null;
    final token = _reader.getConfluenceLoginPassToken();
    if (token == null || token.isEmpty) return null;
    final authType = _reader.getConfluenceAuthType();
    return (
      rootUrl: basePath,
      baseUrl: '$basePath/wiki/rest/api',
      headers: {
        'Authorization': '$authType $token',
        'Accept': syncJsonContentType,
        'Content-Type': syncJsonContentType,
      },
      apiVersion: _reader.getConfluenceApiVersion(),
      attachmentRetryBaseDelayMs:
          _reader.getConfluenceAttachmentRetryBaseDelayMs(),
    );
  }

  /// `confluence_search` — GET `content/search?cql={cql}`.
  String _search(Map<String, dynamic> args) {
    return syncWithConfig(_config(), _notConfiguredError, (config) {
      final cql = Uri.encodeQueryComponent(syncAsStr(args['cql']));
      return _syncGetBody(config, '${config.baseUrl}/content/search?cql=$cql');
    });
  }

  /// `confluence_get_page` — GET `content?spaceKey=&title=&expand=body.storage`.
  String _getPage(Map<String, dynamic> args) {
    return syncWithConfig(_config(), _notConfiguredError, (config) {
      final spaceKey = Uri.encodeQueryComponent(syncAsStr(args['spaceKey']));
      final title = Uri.encodeQueryComponent(syncAsStr(args['title']));
      return _syncGetBody(
        config,
        '${config.baseUrl}/content?spaceKey=$spaceKey&title=$title'
        '&expand=body.storage',
      );
    });
  }

  /// `confluence_create_page` — POST `content` with the storage-format page
  /// (Java `createPage`; `ancestors` included when `parentId` is given).
  ///
  /// Under `CONFLUENCE_API_VERSION=v2` resolves the space key to its
  /// numeric id and POSTs `/wiki/api/v2/pages` (required for
  /// granular/scoped tokens).
  String _createPage(Map<String, dynamic> args) {
    return syncWithConfig(_config(), _notConfiguredError, (config) {
      if (_isApiV2(config)) return _createPageV2(config, args);
      return syncBodyOrError(SyncHttpClient.post(
        '${config.baseUrl}/content',
        headers: config.headers,
        body: jsonEncode(_pagePayload(args)),
      ));
    });
  }

  /// The v2 `confluence_create_page` tail: resolves the space key via the
  /// v2 spaces endpoint, then POSTs the v2 pages payload.
  String _createPageV2(_Conf config, Map<String, dynamic> args) {
    final space = syncAsStr(args['space']);
    final spaceId = _spaceIdFromKey(config, space);
    if (spaceId == null) return syncErr(_spaceNotFound(space));
    return syncBodyOrError(SyncHttpClient.post(
      '${_baseUrlV2(config)}/pages',
      headers: config.headers,
      body: jsonEncode(_pagePayloadV2(
        spaceId,
        syncAsStr(args['title']),
        syncAsStr(args['parentId'] ?? args['parentPageId']),
        syncAsStr(args['body']),
      )),
    ));
  }

  /// `confluence_update_page` — PUT `content/{contentId}` with a bumped
  /// version (Java `updatePage`: fetch current version, +1, ancestors, space).
  String _updatePage(Map<String, dynamic> args) {
    return syncWithConfig(_config(), _notConfiguredError, (config) {
      return _updateWithVersion(config, args);
    });
  }

  /// `confluence_content_by_id` — GET `content/{id}` with the standard
  /// expand list (v1), or `pages/{id}?body-format=storage` (v2; required for
  /// granular/scoped tokens). The v2 response is shape-compatible (`id`,
  /// `title`, `body.storage.value`).
  String _contentById(Map<String, dynamic> args) {
    return syncWithConfig(_config(), _notConfiguredError, (config) {
      final id = syncAsStr(args['contentId']);
      if (_isApiV2(config)) {
        final body = syncBodyOrError(_pageByIdResponse(config, id));
        return _applyFormat(body, args['format']);
      }
      final body = syncBodyOrError(
        _contentGet(config, '$id?expand=$_contentExpand'),
      );
      return _applyFormat(body, args['format']);
    });
  }

  /// `confluence_get_children_by_id` — GET
  /// `content/{contentId}/child/page?limit=100&expand=…`, returning the
  /// `results` array (Java returns the content list, not the wrapper).
  String _getChildrenById(Map<String, dynamic> args) {
    return syncWithConfig(_config(), _notConfiguredError, (config) {
      return _childrenPayload(config, syncAsStr(args['contentId']), args);
    });
  }

  /// The shared `get_children_*` tail: fetches the child page list of
  /// [id], validates the envelope, applies `format=md`, and encodes.
  String _childrenPayload(_Conf config, String id, Map<String, dynamic> args) {
    final format = syncAsStr(args['format']);
    // v2: GET /wiki/api/v2/pages?parent-id={id} (granular/scoped tokens).
    // The v2 list response carries the same `results` array shape.
    final results =
        _childrenResults(syncBodyOrError(_childrenResponse(config, id)));
    if (results == null) {
      return syncErr('Unexpected children response for $id');
    }
    if (_isMarkdownFormat(format)) {
      for (final content in results) {
        _convertStorageToMarkdown(content);
      }
    }
    return jsonEncode(results);
  }

  /// `confluence_sync_markdown_directory` — mirrors a local Markdown tree
  /// into a Confluence page subtree (Java `syncMarkdownDirectory`).
  String _syncMarkdownDirectory(Map<String, dynamic> args) {
    return syncWithConfig(_config(), _notConfiguredError, (config) {
      final directory = syncAsStr(args['directory']);
      final dir = _existingDir(directory);
      if (dir == null) {
        return syncErr('Directory not found: $directory');
      }
      final engine = MarkdownConfluenceSync(
        _SyncConfluenceAttachments(config),
        _SyncConfluencePageOps(config),
      );
      return engine.syncDirectory(
        dir,
        syncAsStr(args['parentId']),
        syncAsStr(args['space']),
        args['deleteOrphans'] == true || args['deleteOrphans'] == 'true',
        syncAsStr(args['attachmentsDir']).isEmpty
            ? null
            : syncAsStr(args['attachmentsDir']),
      );
    });
  }

  /// `confluence_content_by_title` — GET `content?title=&expand=…` in the
  /// configured default space (Java `contentByTitleInDefaultSpace`).
  String _contentByTitle(Map<String, dynamic> args) {
    return syncWithConfig(_config(), _notConfiguredError, (config) {
      final space = _effectiveSpace(args['space']);
      if (space == null) return syncErr(_defaultSpaceRequired);
      return _titleAndSpaceContent(config, args, space);
    });
  }

  /// `confluence_content_by_title_and_space` — GET
  /// `content?title=&spaceKey=&expand=…` (Java `content`).
  String _contentByTitleAndSpace(Map<String, dynamic> args) {
    return syncWithConfig(_config(), _notConfiguredError, (config) {
      return _titleAndSpaceContent(config, args, syncAsStr(args['space']));
    });
  }

  /// `confluence_find_content` — first match by title in the default space
  /// or JSON `null` (Java `findContentInDefaultSpace`).
  String _findContent(Map<String, dynamic> args) {
    return syncWithConfig(_config(), _notConfiguredError, (config) {
      final space = _effectiveSpace(args['space']);
      if (space == null) return syncErr(_defaultSpaceRequired);
      return _firstContent(config, args, space);
    });
  }

  /// `confluence_find_content_by_title_and_space` — first match by title in
  /// [ConfluenceSyncTools] space or JSON `null` (Java `findContent`).
  String _findContentByTitleAndSpace(Map<String, dynamic> args) {
    return syncWithConfig(_config(), _notConfiguredError, (config) {
      return _firstContent(config, args, syncAsStr(args['space']));
    });
  }

  /// `confluence_find_or_create` — find by title in the default space or
  /// create under [parentId] (Java `findOrCreate`).
  String _findOrCreate(Map<String, dynamic> args) {
    return syncWithConfig(_config(), _notConfiguredError, (config) {
      final space = _defaultSpace();
      if (space == null) return syncErr(_defaultSpaceRequired);
      final existing = _contentList(
        _titleAndSpaceResponse(config, syncAsStr(args['title']), space),
      );
      if (existing.isNotEmpty) return jsonEncode(existing.first);
      if (_isApiV2(config))
        return _createPageV2(config, {...args, 'space': space});
      return syncBodyOrError(SyncHttpClient.post(
        '${config.baseUrl}/content',
        headers: config.headers,
        body: jsonEncode(_pagePayload(args)..['space'] = {'key': space}),
      ));
    });
  }

  /// `confluence_get_children_by_name` — children of the page found by
  /// title in [spaceKey] (Java `getChildrenOfContentByName`).
  String _getChildrenByName(Map<String, dynamic> args) {
    return syncWithConfig(_config(), _notConfiguredError, (config) {
      final found = _contentList(_titleAndSpaceResponse(
        config,
        syncAsStr(args['contentName']),
        syncAsStr(args['spaceKey']),
      ));
      if (found.isEmpty) {
        return syncErr('Content not found: ${syncAsStr(args['contentName'])}');
      }
      return _childrenPayload(
          config, found.first['id']?.toString() ?? '', args);
    });
  }

  /// `confluence_get_content_attachments` — GET
  /// `content/{contentId}/child/attachment` (v1) or
  /// `/wiki/api/v2/pages/{contentId}/attachments` (v2), returning the
  /// `results` array.
  String _getContentAttachments(Map<String, dynamic> args) {
    return syncWithConfig(_config(), _notConfiguredError, (config) {
      final id = syncAsStr(args['contentId']);
      final results =
          _childrenResults(syncBodyOrError(_attachmentsResponse(config, id)));
      if (results == null) {
        return syncErr('Unexpected attachments response for $id');
      }
      return jsonEncode(results);
    });
  }

  /// `confluence_get_current_user_profile` — GET `user/current`.
  String _getCurrentUserProfile(Map<String, dynamic> args) {
    return syncWithConfig(_config(), _notConfiguredError, (config) {
      return _syncGetBody(config, '${config.baseUrl}/user/current');
    });
  }

  /// `confluence_get_user_profile_by_id` — GET `user?accountId={userId}`.
  String _getUserProfileById(Map<String, dynamic> args) {
    return syncWithConfig(_config(), _notConfiguredError, (config) {
      return syncBodyOrError(SyncHttpClient.get(
        '${config.baseUrl}/user?accountId='
        '${Uri.encodeQueryComponent(syncAsStr(args['userId']))}',
        headers: config.headers,
      ));
    });
  }

  /// `confluence_search_content_by_text` — CQL `(title ~ … OR text ~ …)`
  /// search (Java `searchContentByText`; the GraphQL fast path is not
  /// ported — Dart always uses the REST search).
  String _searchContentByText(Map<String, dynamic> args) {
    return syncWithConfig(_config(), _notConfiguredError, (config) {
      final query = syncAsStr(args['query']);
      final limit = args['limit'] is num
          ? (args['limit'] as num).toInt()
          : (int.tryParse(syncAsStr(args['limit'])) ?? 20);
      final cql = Uri.encodeQueryComponent(
        buildConfluenceTextSearchCql(query, _defaultSpace()),
      );
      final resp = SyncHttpClient.get(
        '${config.baseUrl}/content/search?cql=$cql'
        '&limit=$limit'
        '&expand=${Uri.encodeQueryComponent(_searchExpand)}',
        headers: config.headers,
      );
      final body = syncBodyOrError(resp);
      final decoded = syncTryDecode(body);
      if (decoded is Map && decoded['results'] is List) {
        return jsonEncode(decoded['results']);
      }
      return body;
    });
  }

  /// `confluence_contents_by_urls` — resolve each URL to content
  /// concurrently (gh-348, Java `ConfluenceParallel` parity), skipping
  /// failures like Java (`logger.error` + continue).
  String _contentsByUrls(Map<String, dynamic> args) {
    return syncWithConfig(_config(), _notConfiguredError, (config) {
      final urls = <String>[
        for (final url in _stringList(args['urlStrings']))
          if (url.isNotEmpty) url,
      ];
      final resolved = _runConfluenceParallel(_resolveJobs(config, urls));
      final contents = <Map<String, dynamic>>[
        for (final content in resolved)
          if (content != null) Map<String, dynamic>.from(content),
      ];
      return jsonEncode(_applyFormatToList(contents, args['format']));
    });
  }

  /// `confluence_update_page_with_history` — like [ConfluenceSyncTools]
  /// update but the bumped version carries [historyComment] as its message
  /// (Java `confluence_update_page_with_history`).
  String _updatePageWithHistory(Map<String, dynamic> args) {
    return syncWithConfig(_config(), _notConfiguredError, (config) {
      return _updateWithVersion(
        config,
        args,
        historyComment: syncAsStr(args['historyComment']),
      );
    });
  }

  /// The shared `update_page*` tail: bumps the current version of the page
  /// and PUTs the merged payload (Java `updatePage`; the history-comment
  /// variant adds `version.message`).
  ///
  /// Under `CONFLUENCE_API_VERSION=v2` reads the version via
  /// `GET /wiki/api/v2/pages/{id}` and PUTs `/wiki/api/v2/pages/{id}` with
  /// the v2 payload (no ancestors/space, explicit `current` status) —
  /// required for granular/scoped tokens.
  String _updateWithVersion(
    _Conf config,
    Map<String, dynamic> args, {
    String historyComment = '',
  }) {
    final contentId = syncAsStr(args['contentId']);
    final version = _currentVersion(config, contentId);
    if (version == null) {
      return syncErr('Failed to fetch version for $contentId');
    }
    if (_isApiV2(config)) {
      return syncBodyOrError(SyncHttpClient.put(
        '${_baseUrlV2(config)}/pages/$contentId',
        headers: config.headers,
        body: jsonEncode(_updatePayloadV2(
          contentId,
          syncAsStr(args['title']),
          syncAsStr(args['body']),
          version + 1,
          historyComment,
        )),
      ));
    }
    return syncBodyOrError(SyncHttpClient.put(
      '${config.baseUrl}/content/$contentId',
      headers: config.headers,
      body: jsonEncode(
        _updatePayload(args, contentId, version + 1,
            historyComment: historyComment),
      ),
    ));
  }

  /// `confluence_upload_attachment` — multipart upload of one file with the
  /// skip-existing / overwrite policy (Java `AttachmentHelper`).
  String _uploadAttachment(Map<String, dynamic> args) {
    return syncWithConfig(_config(), _notConfiguredError, (config) {
      final file = File(syncAsStr(args['file']));
      if (!file.existsSync()) {
        return syncErr('File not found: ${file.path}');
      }
      final result = _SyncConfluenceAttachments(config).uploadWithPolicy(
        file,
        syncAsStr(args['contentId']),
        _flagOrFalse(args['updateIfExists']),
      );
      return jsonEncode(result);
    });
  }

  /// `confluence_upload_attachments` — upload every file in [directory]
  /// with the same policy; returns a JSON summary.
  String _uploadAttachments(Map<String, dynamic> args) {
    return syncWithConfig(_config(), _notConfiguredError, (config) {
      final dir = Directory(syncAsStr(args['directory']));
      if (!dir.existsSync()) {
        return syncErr('Directory not found: ${dir.path}');
      }
      final updateIfExists = _flagOrFalse(args['updateIfExists']);
      final helper = _SyncConfluenceAttachments(config);
      final uploaded = <String>[];
      final skipped = <String>[];
      final failed = <String>[];
      for (final entry in dir.listSync()) {
        if (entry is! File) continue;
        try {
          final result = helper.uploadWithPolicy(
            entry,
            syncAsStr(args['contentId']),
            updateIfExists,
          );
          final bucket = result['status'] == 'skipped'
              ? skipped
              : result['status'] == 'failed'
                  ? failed
                  : uploaded;
          bucket.add(entry.uri.pathSegments.last);
        } on StateError {
          failed.add(entry.uri.pathSegments.last);
        }
      }
      return jsonEncode({
        'uploaded': uploaded,
        'skipped': skipped,
        'failed': failed,
      });
    });
  }

  /// `confluence_download_pages` — download pages (+ attachments) reached
  /// from [urlStrings] up to [depth] child-page levels, converted to
  /// Markdown (Java `ConfluencePageDownloader`; link-graph walking is
  /// limited to child pages).
  String _downloadPages(Map<String, dynamic> args) {
    return syncWithConfig(_config(), _notConfiguredError, (config) {
      final urls = _stringList(args['urlStrings']);
      final outputPath = syncAsStr(args['outputPath']);
      final depth = args['depth'] is num
          ? (args['depth'] as num).toInt()
          : (int.tryParse(syncAsStr(args['depth'])) ?? 1);
      final downloadAttachments = args['downloadAttachments'] == null ||
          args['downloadAttachments'] == true ||
          args['downloadAttachments'] == 'true';
      final includeComments =
          args['includeComments'] == true || args['includeComments'] == 'true';
      final downloader = _PageDownloader(
        config,
        Directory(outputPath),
        downloadAttachments,
        includeComments: includeComments,
        defaultSpace: _defaultSpace(),
      );
      final written = downloader.download(urls, depth);
      return 'Downloaded $written Confluence page(s) to $outputPath';
    });
  }

  /// `confluence_get_page_inline_comments` — GET
  /// `{baseUrlV2}/pages/{pageId}/inline-comments?body-format=storage[&limit=…]`
  /// (Java `Confluence.getPageInlineComments`).
  String _getPageInlineComments(Map<String, dynamic> args) {
    return syncWithConfig(_config(), _notConfiguredError, (config) {
      final pageId = syncAsStr(args['pageId']);
      final limit = args['limit'] is num
          ? (args['limit'] as num).toInt()
          : int.tryParse(syncAsStr(args['limit']));
      return syncBodyOrError(_inlineCommentsResponse(config, pageId, limit));
    });
  }

  /// `confluence_reply_to_inline_comment` — POST `{baseUrlV2}/inline-comments`
  /// with storage-formatted paragraph body (Java `Confluence.replyToInlineComment`).
  String _replyToInlineComment(Map<String, dynamic> args) {
    return syncWithConfig(_config(), _notConfiguredError, (config) {
      final commentId = syncAsStr(args['commentId']);
      final body = prepareConfluenceInlineCommentBody(syncAsStr(args['body']));
      return syncBodyOrError(SyncHttpClient.post(
        '${_baseUrlV2(config)}/inline-comments',
        headers: config.headers,
        body: jsonEncode({
          'parentCommentId': commentId,
          'body': {'representation': 'storage', 'value': body},
        }),
      ));
    });
  }

  /// The `CONFLUENCE_DEFAULT_SPACE` config value; `null` when unset or blank.
  String? _defaultSpace() {
    final space = _reader.getConfluenceDefaultSpace()?.trim();
    return (space == null || space.isEmpty) ? null : space;
  }

  /// Explicit [space] argument when non-empty, else [_defaultSpace].
  String? _effectiveSpace(dynamic space) {
    final explicit = syncAsStr(space).trim();
    return explicit.isNotEmpty ? explicit : _defaultSpace();
  }

  /// Builds the page creation payload (Java `createPage` wire format).
  Map<String, dynamic> _pagePayload(Map<String, dynamic> args) {
    final payload = <String, dynamic>{
      'type': 'page',
      'title': syncAsStr(args['title']),
      'space': {'key': syncAsStr(args['space'])},
      'body': {
        'storage': {
          'value': syncAsStr(args['body']),
          'representation': 'storage'
        },
      },
    };
    final parentId = syncAsStr(args['parentId'] ?? args['parentPageId']);
    if (parentId.isNotEmpty) {
      payload['ancestors'] = [
        {'id': parentId},
      ];
    }
    return payload;
  }

  /// Builds the page update payload (Java `updatePage` wire format).
  Map<String, dynamic> _updatePayload(
    Map<String, dynamic> args,
    String contentId,
    int version, {
    String historyComment = '',
  }) =>
      _contentPayload(
        id: contentId,
        title: syncAsStr(args['title']),
        parentId: syncAsStr(args['parentId']),
        body: syncAsStr(args['body']),
        space: syncAsStr(args['space']),
        version: {
          'number': version,
          if (historyComment.isNotEmpty) 'message': historyComment,
        },
      );

  /// Fetches the current version number of [contentId]; `null` on failure.
  int? _currentVersion(_Conf config, String contentId) =>
      _versionNumberOf(_versionResponse(config, contentId));
}

/// Resolved sync integration config: root site URL, REST base URL, auth
/// headers.
typedef _Conf = ({
  String rootUrl,
  String baseUrl,
  Map<String, String> headers,
  String apiVersion,
  int attachmentRetryBaseDelayMs,
});

/// Error payload returned when Confluence config is incomplete.
const _notConfiguredError = 'Confluence not configured';

/// The Java `contentById` expand list (full storage, export view,
/// ancestors, and version).
const _contentExpand = 'body.storage,body.export_view,ancestors,version';

/// The Java `searchContentByText` expand list.
const _searchExpand = 'title,body.excerpt,history,space,body.storage';

/// Error when a default-space tool runs without `CONFLUENCE_DEFAULT_SPACE`
/// (Java `IllegalStateException`).
const _defaultSpaceRequired = 'Default space not set';

/// True when v2 content endpoints are in use (`CONFLUENCE_API_VERSION=v2`).
/// Granular/scoped tokens require the v2 API; legacy v1 content endpoints
/// 401 under them. Java parity: `Confluence.isApiV2`.
bool _isApiV2(_Conf config) => config.apiVersion.toLowerCase() == 'v2';

/// Confluence v2 REST base URL: `{siteRoot}/wiki/api/v2`.
///
/// [rootUrl] may already end with `/wiki` (direct site URL) or omit it (the
/// granular-token gateway `https://api.atlassian.com/ex/confluence/{id}`).
/// Normalize so `/wiki` appears exactly once. Java parity: `Confluence.pathV2`.
String _baseUrlV2(_Conf config) {
  final root = config.rootUrl.endsWith('/wiki')
      ? config.rootUrl.substring(0, config.rootUrl.length - '/wiki'.length)
      : config.rootUrl;
  return '$root/wiki/api/v2';
}

/// GETs `content?expand=…&title=…[&spaceKey=…]` (Java `content(title,
/// space)`; the spaceKey param is dropped for an empty space).
///
/// Under `CONFLUENCE_API_VERSION=v2` queries
/// `/wiki/api/v2/pages?title=…&spaceId=…&body-format=storage` instead —
/// v2 filters by numeric space id resolved from the key via the spaces
/// endpoint (Java `spaceIdFromKey`; a resolution failure throws, matching
/// the Java IOException). Required for granular/scoped tokens.
SyncHttpResponse _titleAndSpaceResponse(
  _Conf config,
  String title,
  String space,
) {
  if (_isApiV2(config)) {
    final url = StringBuffer('${_baseUrlV2(config)}/pages?title='
        '${Uri.encodeQueryComponent(title)}');
    if (space.isNotEmpty) {
      final spaceId = _spaceIdFromKey(config, space);
      if (spaceId == null) throw StateError(_spaceNotFound(space));
      url.write('&spaceId=$spaceId');
    }
    url.write('&body-format=storage');
    return SyncHttpClient.get(url.toString(), headers: config.headers);
  }
  return SyncHttpClient.get(
    '${config.baseUrl}/content?expand=${Uri.encodeQueryComponent(_contentExpand)}'
    '&title=${Uri.encodeQueryComponent(title)}'
    '${space.isEmpty ? '' : '&spaceKey=${Uri.encodeQueryComponent(space)}'}',
    headers: config.headers,
  );
}

/// The content objects of a title/space listing.
List<Map<String, dynamic>> _contentList(SyncHttpResponse resp) {
  final decoded = syncTryDecode(syncBodyOrError(resp));
  final results = decoded is Map ? decoded['results'] : decoded;
  if (results is! List) return const [];
  return results
      .whereType<Map>()
      .map(Map<String, dynamic>.from)
      .toList(growable: false);
}

/// Runs the Java `applyFormat` contract over the `confluence_content…`
/// listing: converts each result's storage body when [format] asks for
/// Markdown and returns the re-encoded JSON.
///
/// The response is the full `ContentResult` listing object (`{"results":
/// […], "start", "limit", "size"}`) — Java's MCP layer serializes the
/// `ContentResult` JSONModel verbatim, and the async/MCP surface must stay
/// shape-identical with this sync port.
String _titleAndSpaceContent(
    _Conf config, Map<String, dynamic> args, String space) {
  final resp = _titleAndSpaceResponse(config, syncAsStr(args['title']), space);
  final decoded = syncTryDecode(syncBodyOrError(resp));
  if (decoded is! Map<String, dynamic>) {
    return syncErr('Unexpected content listing response');
  }
  final results = decoded['results'];
  if (results is List) {
    decoded['results'] = _applyFormatToList(
      results.whereType<Map>().map(Map<String, dynamic>.from).toList(),
      args['format'],
    );
  }
  return jsonEncode(decoded);
}

/// The first content of a title/space listing, JSON `null` when none.
String _firstContent(
  _Conf config,
  Map<String, dynamic> args,
  String space,
) {
  final list = _applyFormatToList(
    _contentList(
      _titleAndSpaceResponse(config, syncAsStr(args['title']), space),
    ),
    args['format'],
  );
  return jsonEncode(list.isEmpty ? null : list.first);
}

/// Applies the Java `applyFormat` contract to a content list, in place.
List<Map<String, dynamic>> _applyFormatToList(
  List<Map<String, dynamic>> contents,
  dynamic format,
) {
  if (_isMarkdownFormat(format)) {
    for (final content in contents) {
      _convertStorageToMarkdown(content);
    }
  }
  return contents;
}

/// Coerces an array-ish arg into a string list.
List<String> _stringList(dynamic value) {
  if (value is List) return value.map(syncAsStr).toList();
  final single = syncAsStr(value);
  return single.isEmpty ? const [] : [single];
}

/// Reads a boolean flag that may arrive as bool or string.
bool _flagOrFalse(dynamic value) =>
    value == true || value == 'true' || value == 'True';
