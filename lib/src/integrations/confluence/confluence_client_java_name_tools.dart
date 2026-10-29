part of 'confluence_client.dart';

/// Java-named tool methods of [ConfluenceClient] from the frozen gap
/// snapshot (gh-191): title lookups, find-or-create, children-by-name,
/// attachments/profile/search lookups, URL resolution.
///
/// NOTE: extension members are statically dispatched — subclasses/test spies
/// cannot override these methods; extend the client class instead.
extension ConfluenceJavaNameTools on ConfluenceClient {
  /// `confluence_content_by_title` — GET `content?title=&expand=…` in the
  /// configured default space (Java `contentByTitleInDefaultSpace`).
  ///
  /// Returns the full listing response; [format] `md`/`markdown` converts
  /// every result's storage body to Markdown in place.
  Future<Map<String, dynamic>> contentByTitle(
    String title, [
    String? format,
    String? space,
  ]) async =>
      contentByTitleAndSpace(title, _effectiveSpace(space), format);

  /// `confluence_content_by_title_and_space` — GET
  /// `content?title=&spaceKey=&expand=…` (Java `content`).
  ///
  /// Under `CONFLUENCE_API_VERSION=v2` uses
  /// `GET /wiki/api/v2/pages?title=&spaceId=&body-format=storage`: v2 filters
  /// by numeric space id (resolved from the key via [spaceIdFromKey]) and the
  /// `{"results":[…]}` envelope is v1-compatible. Required for granular/scoped
  /// tokens. Java parity: `Confluence.content`.
  Future<Map<String, dynamic>> contentByTitleAndSpace(
    String title,
    String space, [
    String? format,
  ]) async {
    final body = _http.isApiV2
        ? await _http.getV2(
            'pages',
            queryParams: await _titleQueryV2(title, space),
          )
        : await _http.get('content', queryParams: {
            'expand': 'body.storage,body.export_view,ancestors,version',
            'title': title,
            if (space.isNotEmpty) 'spaceKey': space,
          });
    final decoded = jsonDecode(body) as Map<String, dynamic>;
    ConfluenceClient._applyFormat(_resultList(decoded), format);
    return decoded;
  }

  /// Builds the v2 title-lookup query (Java `content` v2 branch): filters by
  /// the numeric space id when a [space] key is given, storage bodies
  /// requested via `body-format`.
  Future<Map<String, dynamic>> _titleQueryV2(String title, String space) async {
    return {
      'title': title,
      if (space.isNotEmpty) 'spaceId': await spaceIdFromKey(space),
      'body-format': _kStorage,
    };
  }

  /// `confluence_find_content` — first match by title (in [space] or the
  /// configured default space), or `null` (Java `findContent`).
  Future<Map<String, dynamic>?> findContent(
    String title, {
    String? space,
    String? format,
  }) async {
    final listing =
        await contentByTitleAndSpace(title, _effectiveSpace(space), null);
    final contents = _resultList(listing);
    if (contents.isEmpty) return null;
    ConfluenceClient._applyFormat([contents.first], format);
    return contents.first;
  }

  /// `confluence_find_or_create` — find by title in the default space or
  /// create under [parentId] (Java `findOrCreate`).
  Future<Map<String, dynamic>> findOrCreate(
    String title,
    String parentId,
    String body,
  ) async {
    final space = _effectiveSpace(null);
    final existing = await findContent(title, space: space);
    return existing ?? createPage(space, title, body, parentId: parentId);
  }

  /// `confluence_get_children_by_name` — children of the page found by
  /// title in [spaceKey] (Java `getChildrenOfContentByName`).
  Future<List<Map<String, dynamic>>> getChildrenByName(
    String spaceKey,
    String contentName, [
    String? format,
  ]) async {
    final parent = await findContent(contentName, space: spaceKey);
    if (parent == null) {
      throw StateError('Content not found: $contentName');
    }
    final children = await getContentChildren(parent['id'] as String);
    ConfluenceClient._applyFormat(children, format);
    return children;
  }

  /// `confluence_get_content_attachments` — GET
  /// `content/{contentId}/child/attachment` (Java `getContentAttachments`).
  ///
  /// Routes through [getPageAttachments], which switches to the v2
  /// `pages/{id}/attachments` endpoint under the v2 flag.
  Future<List<Map<String, dynamic>>> getContentAttachments(String contentId) =>
      getPageAttachments(contentId);

  /// `confluence_get_current_user_profile` — GET `user/current`.
  Future<Map<String, dynamic>> getCurrentUserProfile() async {
    final body = await _http.get('user/current');
    return jsonDecode(body) as Map<String, dynamic>;
  }

  /// `confluence_get_user_profile_by_id` — GET `user?accountId={userId}`.
  Future<Map<String, dynamic>> getUserProfileById(String userId) async {
    final body = await _http.get('user', queryParams: {'accountId': userId});
    return jsonDecode(body) as Map<String, dynamic>;
  }

  /// `confluence_search_content_by_text` — CQL `(title ~ … OR text ~ …)`
  /// search with the Java expand list (Java `searchContentByText`; the
  /// GraphQL fast path is not ported).
  ///
  /// Intentionally v1-only even when `CONFLUENCE_API_VERSION=v2`: the v2 API
  /// exposes no public CQL search endpoint usable with granular/scoped tokens
  /// (same for the user-profile endpoints), so search stays on the legacy
  /// path regardless of the flag. Known limitation mirrored from Java #592.
  Future<List<Map<String, dynamic>>> searchContentByText(
    String query, [
    int? limit,
  ]) =>
      _getList(
        'content/search',
        queryParams: {
          'cql': buildConfluenceTextSearchCql(query, defaultSpace),
          'limit': '${limit ?? 20}',
          'expand': 'title,body.excerpt,history,space,body.storage',
        },
      );

  /// Resolves [space] with fallback to [defaultSpace]; throws [StateError]
  /// when neither is non-empty.
  String _effectiveSpace(String? space) {
    final candidate =
        (space != null && space.trim().isNotEmpty) ? space : defaultSpace;
    if (candidate == null || candidate.trim().isEmpty) {
      throw StateError('Default space not set');
    }
    return candidate.trim();
  }

  /// `confluence_update_page_with_history` — [updatePage] whose bumped
  /// version message is [historyComment] (Java tool of the same name).
  Future<Map<String, dynamic>> updatePageWithHistory({
    required String contentId,
    required String title,
    required String parentId,
    required String body,
    required String space,
    required String historyComment,
  }) =>
      updatePage(contentId, title, parentId, body, space, historyComment);

  /// `confluence_contents_by_urls` — resolve each URL to its content,
  /// skipping failures like Java (`contentsByUrls`).
  Future<List<Map<String, dynamic>>> contentsByUrls(
    List<String> urlStrings, [
    String? format,
  ]) async {
    final contents = <Map<String, dynamic>>[];
    for (final url in urlStrings) {
      if (url.isEmpty) continue;
      try {
        final content = await contentByUrl(url);
        if (content != null) contents.add(content);
      } on Object {
        continue; // Java logs and continues on per-URL failures.
      }
    }
    ConfluenceClient._applyFormat(contents, format);
    return contents;
  }

  /// `contentByUrl` — resolves a Confluence page URL to its content object
  /// (Java `contentByUrl`): `/spaces/{s}/pages/{id}[/title]` direct ids,
  /// `/display/{s}/{title}` lookups, `/wiki/x/{key}` and `/l/…` short
  /// links resolved through their 3xx Location. Returns `null` for unknown
  /// URL shapes.
  Future<Map<String, dynamic>?> contentByUrl(String urlString) async {
    final parsed = Uri.tryParse(urlString);
    if (parsed == null) return null;
    final ref = await _resolveRef(parsed);
    if (ref is ConfluencePageIdRef) return getPageById(ref.id);
    if (ref is ConfluenceDisplayRef) {
      final listing = await contentByTitleAndSpace(ref.title, ref.space);
      final contents = _resultList(listing);
      return contents.isEmpty ? null : contents.first;
    }
    return null;
  }

  /// Resolves [uri] through short-link redirect hops (max 5, Java parity):
  /// each 3xx `Location` is followed and re-classified until a direct
  /// page-id / display ref (or an unknown shape) remains. Returns `null`
  /// when a hop fails or the hop budget is exhausted.
  Future<ConfluencePageRef?> _resolveRef(Uri uri) async {
    var current = uri;
    var ref = resolveConfluencePageUrl(current);
    var hops = 0;
    while (ref is ConfluenceRedirectRef && hops < 5) {
      hops++;
      final location = await _resolveRedirect(current);
      if (location == null) return null;
      final next = Uri.tryParse(location);
      if (next == null) return null;
      current = next;
      ref = resolveConfluencePageUrl(current);
    }
    return ref is ConfluenceRedirectRef ? null : ref;
  }

  /// Follows one 3xx hop for [uri], returning the `Location` URL, or `null`
  /// when the response is not a redirect (dio follows redirects by default;
  /// this disables that to mirror Java `resolveRedirect`).
  ///
  /// The probe travels authenticated (instances with anonymous access
  /// disabled answer 302 → login otherwise) and any non-redirect outcome —
  /// including a thrown 4xx/5xx — degrades to `null` so one dead short link
  /// never aborts a whole `downloadPages` call.
  Future<String?> _resolveRedirect(Uri uri) async {
    try {
      final response = await _http.dio.getUri<dynamic>(
        uri,
        options: Options(
          followRedirects: false,
          validateStatus: (_) => true,
          headers: _http.headers,
        ),
      );
      final location = response.headers.value('location');
      return (response.statusCode != null &&
              response.statusCode! >= 300 &&
              response.statusCode! < 400 &&
              location != null)
          ? location
          : null;
    } on DioException {
      return null;
    }
  }

  /// `confluence_get_page_inline_comments` — GET
  /// `pages/{pageId}/inline-comments?body-format=storage[&limit=…]` via v2 API
  /// (Java `Confluence.getPageInlineComments`).
  Future<Map<String, dynamic>> getPageInlineComments(
    String pageId, [
    int? limit,
  ]) async {
    final body = await _http.getV2(
      'pages/$pageId/inline-comments',
      queryParams: {
        'body-format': _kStorage,
        if (limit != null && limit > 0) 'limit': '$limit',
      },
    );
    return jsonDecode(body) as Map<String, dynamic>;
  }

  /// `confluence_reply_to_inline_comment` — POST `inline-comments` via v2 API
  /// (Java `Confluence.replyToInlineComment`).
  Future<Map<String, dynamic>> replyToInlineComment(
    String pageId,
    String commentId,
    String text,
  ) async {
    final body = await _http.postV2(
      'inline-comments',
      body: jsonEncode({
        'parentCommentId': commentId,
        'body': {
          'representation': _kStorage,
          'value': prepareConfluenceInlineCommentBody(text),
        },
      }),
    );
    return jsonDecode(body) as Map<String, dynamic>;
  }
}
