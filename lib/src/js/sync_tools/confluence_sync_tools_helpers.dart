part of 'confluence_sync_tools.dart';

/// Shared low-level helpers of the Confluence sync executors: blocking HTTP
/// tails, request-payload builders, and the storage→Markdown response
/// formatting shared by the read/write handlers.

/// GETs [url] with the resolved config's auth headers and returns the body
/// verbatim (the shared tail of the read-only handlers).
String _syncGetBody(_Conf config, String url) =>
    syncBodyOrError(SyncHttpClient.get(url, headers: config.headers));

/// The local [path] as a `Directory`, `null` when it does not exist (the
/// shared guard of the directory-consuming handlers).
Directory? _existingDir(String path) {
  final dir = Directory(path);
  return dir.existsSync() ? dir : null;
}

/// GETs `content/{suffix}` with the resolved config's auth headers.
SyncHttpResponse _contentGet(_Conf config, String suffix) =>
    SyncHttpClient.get('${config.baseUrl}/content/$suffix',
        headers: config.headers);

/// GETs one page by id (Java `contentById`, v2-aware): v2
/// `pages/{id}?body-format=storage`, v1 `content/{id}?expand=…`.
SyncHttpResponse _pageByIdResponse(_Conf config, String id) => _isApiV2(config)
    ? SyncHttpClient.get('${_baseUrlV2(config)}/pages/$id?body-format=storage',
        headers: config.headers)
    : _contentGet(config, '$id?expand=$_contentExpand');

/// GETs the child page list of [id] (Java `getChildrenOfContentById`,
/// v2-aware): v2 `pages?parent-id=…&limit=100&body-format=storage` (the
/// v2 response carries the bodies without an expand param), v1
/// `content/{id}/child/page?limit=100&expand=…`.
SyncHttpResponse _childrenResponse(_Conf config, String id) => _isApiV2(config)
    ? SyncHttpClient.get(
        '${_baseUrlV2(config)}/pages?parent-id=$id'
        '&limit=100&body-format=storage',
        headers: config.headers)
    : _contentGet(config, '$id/child/page?limit=100&expand=$_contentExpand');

/// The attachment-listing URL of page [id] (Java `getContentAttachments`,
/// v2-aware): v2 `pages/{id}/attachments`, v1
/// `content/{id}/child/attachment`. Shared by [_attachmentsResponse] and
/// the parallel downloader's listing jobs.
String _attachmentsUrl(_Conf config, String id) => _isApiV2(config)
    ? '${_baseUrlV2(config)}/pages/$id/attachments'
    : '${config.baseUrl}/content/$id/child/attachment';

/// GETs the attachment listing of page [id] (Java `getContentAttachments`,
/// v2-aware).
SyncHttpResponse _attachmentsResponse(_Conf config, String id) =>
    SyncHttpClient.get(_attachmentsUrl(config, id), headers: config.headers);

/// Resolves a Confluence space key to the numeric id required by the v2
/// API via `GET /wiki/api/v2/spaces?keys=…` (Java `spaceIdFromKey`).
///
/// Returns `null` when the key is unknown or the matched space carries no
/// `id`; callers surface the failure with the Java message.
String? _spaceIdFromKey(_Conf config, String spaceKey) {
  final resp = SyncHttpClient.get(
    '${_baseUrlV2(config)}/spaces?keys='
    '${Uri.encodeQueryComponent(spaceKey)}',
    headers: config.headers,
  );
  final results = _childrenResults(syncBodyOrError(resp));
  if (results == null || results.isEmpty) return null;
  return results.first['id']?.toString();
}

/// Builds the `content` request payload shared by page create/update
/// (Java wire format: [id]/version keys appear only when given).
Map<String, dynamic> _contentPayload({
  String? id,
  required String title,
  required String parentId,
  required String body,
  required String space,
  Map<String, dynamic>? version,
}) =>
    {
      if (id != null) 'id': id,
      'type': 'page',
      'title': title,
      'ancestors': [
        {'id': parentId},
      ],
      'space': {'key': space},
      if (version != null) 'version': version,
      'body': {
        'storage': {'value': body, 'representation': 'storage'},
      },
    };

/// Builds the v2 page creation payload (Java `createPage` v2 branch):
/// numeric `spaceId`, explicit `current` status, and the storage body
/// under `body.value`. [parentId] is omitted when empty — the v2 API
/// rejects an empty parent id with a 400 (v1 omits `ancestors` the same
/// way, so both versions agree on the "no parent" input).
Map<String, dynamic> _pagePayloadV2(
  String spaceId,
  String title,
  String parentId,
  String body,
) =>
    {
      'spaceId': spaceId,
      'status': 'current',
      'title': title,
      if (parentId.isNotEmpty) 'parentId': parentId,
      'body': {'representation': 'storage', 'value': body},
    };

/// Builds the v2 page update payload (Java `updatePage` v2 branch): no
/// ancestors/space, explicit `current` status, and the bumped version
/// carrying the history comment.
Map<String, dynamic> _updatePayloadV2(
  String contentId,
  String title,
  String body,
  int version,
  String historyComment,
) =>
    {
      'id': contentId,
      'status': 'current',
      'title': title,
      'body': {'representation': 'storage', 'value': body},
      'version': {'number': version, 'message': historyComment},
    };

/// The syncErr message of a failed v2 space resolution (Java
/// `spaceIdFromKey` IOException text).
String _spaceNotFound(String spaceKey) =>
    'Confluence space not found by key: $spaceKey';

/// Reads the current version: v2 GETs `pages/{id}`, v1 expands `version`
/// on `content/{id}` (Java `updatePage`, v2-aware).
SyncHttpResponse _versionResponse(_Conf config, String contentId) =>
    SyncHttpClient.get(
      _isApiV2(config)
          ? '${_baseUrlV2(config)}/pages/$contentId'
          : '${config.baseUrl}/content/$contentId?expand=version',
      headers: config.headers,
    );

/// Reads `version.number` from a `?expand=version` response; `null` when
/// the response failed or carries no numeric version.
int? _versionNumberOf(SyncHttpResponse resp) {
  if (!resp.isOk) return null;
  final decoded = syncTryDecode(resp.body);
  if (decoded is! Map) return null;
  final version = decoded['version'];
  if (version is Map && version['number'] is num) {
    return (version['number'] as num).toInt();
  }
  return null;
}

/// The `results` page list of a children response; `null` when the body is
/// not a results object.
List<Map<String, dynamic>>? _childrenResults(String body) {
  final decoded = syncTryDecode(body);
  if (decoded is! Map || decoded['results'] is! List) return null;
  return (decoded['results'] as List)
      .whereType<Map>()
      .map(Map<String, dynamic>.from)
      .toList();
}

/// Whether [format] requests Markdown conversion (Java `isMarkdownFormat`).
bool _isMarkdownFormat(dynamic format) {
  final f = format?.toString().toLowerCase() ?? '';
  return f == 'md' || f == 'markdown';
}

/// Applies the Java `applyFormat` contract to a JSON response body string:
/// converts `body.storage.value` to Markdown when requested.
String _applyFormat(String body, dynamic format) {
  if (!_isMarkdownFormat(format)) return body;
  final decoded = syncTryDecode(body);
  if (decoded is! Map<String, dynamic>) return body;
  _convertStorageToMarkdown(decoded);
  return jsonEncode(decoded);
}

/// Converts one content object's storage body to Markdown, in place.
void _convertStorageToMarkdown(Map<String, dynamic> content) {
  final body = content['body'];
  if (body is! Map) return;
  final storage = body['storage'];
  if (storage is! Map || storage['value'] is! String) return;
  body.remove('export_view'); // large, redundant once Markdown is returned
  storage['value'] = confluenceStorageToMarkdown(storage['value'] as String);
  storage['representation'] = 'markdown';
}

/// GETs inline comments for [pageId] via the v2 API
/// (`{baseUrlV2}/pages/{pageId}/inline-comments?body-format=storage[&limit=…]`).
SyncHttpResponse _inlineCommentsResponse(
  _Conf config,
  String pageId, [
  int? limit,
]) {
  final limitParam = limit != null && limit > 0 ? '&limit=$limit' : '';
  return SyncHttpClient.get(
    '${_baseUrlV2(config)}/pages/$pageId/inline-comments'
    '?body-format=storage$limitParam',
    headers: config.headers,
  );
}

typedef _ResolvedConfluenceLink = ({ConfluencePageRef ref, String url});

/// Resolves [urlString] to its content object (Java `contentByUrl`), or
/// `null` when the URL is malformed or the fetch fails.
Map<String, dynamic>? _contentFromUrl(_Conf config, String urlString) {
  final uri = Uri.tryParse(urlString);
  if (uri == null) return null;
  final resolved = _resolveShortLink(config, urlString, uri);
  if (resolved == null) return null;
  final (:ref, url: _) = resolved;
  if (ref is ConfluencePageIdRef) {
    final decoded =
        syncTryDecode(syncBodyOrError(_pageByIdResponse(config, ref.id)));
    return decoded is Map<String, dynamic> ? decoded : null;
  }
  if (ref is ConfluenceDisplayRef) {
    final list = _contentList(
      _titleAndSpaceResponse(config, ref.title, ref.space),
    );
    return list.isEmpty ? null : list.first;
  }
  return null;
}

/// Follows up to five 3xx hops for short links (`/l/…`, `/wiki/x/…`;
/// curl never follows redirects), returning the final URL ref and the
/// URL that produced it. Returns `null` when a hop fails or points at
/// nothing parseable.
_ResolvedConfluenceLink? _resolveShortLink(
  _Conf config,
  String urlString,
  Uri uri,
) {
  var ref = resolveConfluencePageUrl(uri);
  var current = urlString;
  for (var hops = 0; hops < 5; hops++) {
    if (ref is! ConfluenceRedirectRef) break;
    final resp = SyncHttpClient.get(current, headers: config.headers);
    final location = resp.headers.entries
        .where((e) => e.key.toLowerCase() == 'location')
        .map((e) => e.value)
        .firstOrNull;
    if (location == null || !resp.isRedirect) return null;
    final next = Uri.tryParse(location);
    if (next == null) return null;
    current = location;
    ref = resolveConfluencePageUrl(next);
  }
  return (ref: ref, url: current);
}
