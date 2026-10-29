part of 'confluence_sync_tools.dart';

typedef _AttachmentPage = ({String contentId, String pageFolder});

/// Depth-first page downloader: writes each page as Markdown and
/// optionally mirrors its attachments, then recurses into child pages
/// down to [depth] levels (Java `ConfluencePageDownloader`, limited to
/// the child graph).
///
/// gh-348 (dm.ai d61a4abd / 8cbf550d parity):
/// - Seed URLs resolve concurrently (one `resolve` pool job each).
/// - Attachment work is collected during the page walk and drained
///   afterwards: listing fetches for all pages go out together, then
///   every attachment downloads concurrently with the transient-failure
///   retry schedule; results are written in listing order.
/// - A failed download never leaves a partial file behind.
class _PageDownloader {
  final _Conf _config;
  final Directory _output;
  final bool _downloadAttachments;
  final bool _includeComments;
  final String? _defaultSpace;
  final ConfluenceExcerptInliner _excerptInliner;
  final ConfluenceMentionResolver _mentionResolver;
  final Set<String> _processedIds = <String>{};
  final Set<String> _processedUrls = <String>{};

  static final RegExp _childrenMacroPattern = RegExp(
    r'<ac:structured-macro\b[^>]*\bac:name=["\x27]children["\x27]',
    caseSensitive: false,
  );

  static final RegExp _acLinkPagePattern = RegExp(
    r'<ac:link\b[^>]*>[\s\S]*?<ri:page\b([^>]*?)/?>[\s\S]*?</ac:link>',
    caseSensitive: false,
  );

  static final RegExp _titleAttrPattern = RegExp(
    r'\bri:content-title=["\x27]([^"\x27]+)["\x27]',
    caseSensitive: false,
  );

  static final RegExp _spaceAttrPattern = RegExp(
    r'\bri:space-key=["\x27]([^"\x27]+)["\x27]',
    caseSensitive: false,
  );

  /// Creates a downloader writing under [_output]; the excerpt-include
  /// inliner and mention resolver reuse one HTTP-backed client (Java
  /// `ConfluencePageDownloader`, dm.ai 932e0db0 / bb1b51e9).
  _PageDownloader(
    this._config,
    this._output,
    this._downloadAttachments, {
    bool includeComments = false,
    String? defaultSpace,
  })  : _includeComments = includeComments,
        _defaultSpace = defaultSpace,
        _excerptInliner = ConfluenceExcerptInliner(
          _SyncConfluenceResolverClient(_config),
        ),
        _mentionResolver = ConfluenceMentionResolver(
          _SyncConfluenceResolverClient(_config),
        );

  int _written = 0;

  /// Pages whose attachments still need downloading (content id + the
  /// sanitized page title used as its folder name).
  final List<_AttachmentPage> _attachmentPages = <_AttachmentPage>[];

  /// Downloads every seed [urls] subtree; returns the pages written.
  int download(List<String> urls, int depth) {
    for (final u in urls) {
      if (u.trim().isNotEmpty) _processedUrls.add(u.trim());
    }
    for (final content in _resolveSeeds(urls)) {
      if (content != null) _downloadPage(content, depth);
    }
    _downloadCollectedAttachments();
    return _written;
  }

  /// Resolves the non-empty seed [urls] to content objects concurrently
  /// (input order; `null` entries failed and are skipped like Java).
  List<Map<String, dynamic>?> _resolveSeeds(List<String> urls) {
    final candidates = <String>[
      for (final url in urls)
        if (url.trim().isNotEmpty) url,
    ];
    return _runConfluenceParallel(_resolveJobs(_config, candidates));
  }

  void _downloadPage(Map<String, dynamic> content, int depth) {
    final id = content['id']?.toString();
    if (id == null || id.isEmpty || !_processedIds.add(id)) return;
    final value = _storageValueOf(content);
    if (value == null) return;
    _output.createSync(recursive: true);
    final rawTitle = content['title']?.toString() ?? id;
    final fileName = _sanitize(rawTitle);
    File('${_output.path}/$fileName.md').writeAsStringSync(
      confluenceStorageToMarkdown(_resolvedBody(content, value)),
    );
    _written++;
    _recordExtrasAndRecurse(content, id, rawTitle, fileName, value, depth);
  }

  String? _storageValueOf(Map<String, dynamic> content) {
    final body = content['body'];
    final storage =
        body is Map ? body['storage'] as Map<String, dynamic>? : null;
    final value = storage?['value'];
    return value is String ? value : null;
  }

  void _recordExtrasAndRecurse(
    Map<String, dynamic> content,
    String id,
    String rawTitle,
    String fileName,
    String value,
    int depth,
  ) {
    if (_includeComments) {
      _writeInlineComments(id, rawTitle, fileName);
    }
    if (_downloadAttachments) {
      _attachmentPages.add((contentId: id, pageFolder: fileName));
    }
    if (depth > 1) {
      for (final child in _discoverRelatedPages(content, id, value)) {
        _downloadPage(child, depth - 1);
      }
    }
  }

  /// Discovers child pages, external Confluence URLs in [storage], and
  /// internal `<ac:link><ri:page …/></ac:link>` references (Java
  /// `ConfluencePageDownloader.discoverRelatedPages`).
  List<Map<String, dynamic>> _discoverRelatedPages(
    Map<String, dynamic> page,
    String pageId,
    String storage,
  ) {
    final related = <Map<String, dynamic>>[];
    final children = _childrenResults(
      syncBodyOrError(_childrenResponse(_config, pageId)),
    );
    if (children != null) related.addAll(children);
    related.addAll(_resolveBodyConfluenceUrls(storage));
    related.addAll(
      _resolveInternalPageLinks(storage, confluenceSpaceKeyOf(page)),
    );
    return related;
  }

  List<Map<String, dynamic>> _resolveBodyConfluenceUrls(String storage) {
    final urls = _extractBodyUrls(storage);
    if (urls.isEmpty) return const [];
    final resolved = _runConfluenceParallel(_resolveJobs(_config, urls));
    return [
      for (final item in resolved)
        if (item != null) item,
    ];
  }

  List<String> _extractBodyUrls(String storage) {
    final root = _config.rootUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (root.isEmpty) return const [];
    final wikiIdx = root.lastIndexOf('/wiki');
    final domain = wikiIdx >= 0 ? root.substring(0, wikiIdx) : root;
    if (domain.isEmpty) return const [];
    final pattern = RegExp(
      '${RegExp.escape(domain)}/(?:wiki/|l/cp/|spaces/|pages/|display/|x/)[^"\\s|\\]\\\\<>)\x27]+',
    );
    final found = <String>[];
    for (final m in pattern.allMatches(storage)) {
      final raw = m.group(0)!.replaceAll('&amp;', '&');
      if (!_childrenMacroPattern.hasMatch(raw) && _processedUrls.add(raw)) {
        found.add(raw);
      }
    }
    return found;
  }

  List<Map<String, dynamic>> _resolveInternalPageLinks(
    String storage,
    String? pageSpaceKey,
  ) {
    final results = <Map<String, dynamic>>[];
    final resolver = _SyncConfluenceResolverClient(_config);
    for (final m in _acLinkPagePattern.allMatches(storage)) {
      final resolved =
          _resolveAcLinkMatch(resolver, m.group(1) ?? '', pageSpaceKey);
      if (resolved != null) results.add(resolved);
    }
    return results;
  }

  Map<String, dynamic>? _resolveAcLinkMatch(
    _SyncConfluenceResolverClient resolver,
    String attrs,
    String? pageSpaceKey,
  ) {
    final title = _titleAttrPattern.firstMatch(attrs)?.group(1)?.trim();
    if (title == null || title.isEmpty) return null;
    final linkSpace = _spaceAttrPattern.firstMatch(attrs)?.group(1)?.trim();
    final space = _firstNonEmpty([linkSpace, pageSpaceKey, _defaultSpace]);
    return resolver.findContent(unescapeXml(title), spaceKey: space);
  }

  static String? _firstNonEmpty(List<String?> candidates) {
    for (final c in candidates) {
      if (c != null && c.isNotEmpty) return c;
    }
    return null;
  }

  void _writeInlineComments(
    String contentId,
    String pageTitle,
    String fileName,
  ) {
    try {
      final resp = _inlineCommentsResponse(_config, contentId, 100);
      if (!resp.isOk) return;
      final results = _childrenResults(resp.body);
      if (results == null || results.isEmpty) return;
      final md = _formatInlineCommentsMarkdown(pageTitle, results);
      File('${_output.path}/$fileName-comments.md').writeAsStringSync(md);
    } catch (_) {
      // Non-fatal: inline comments are optional discussion context.
    }
  }

  String _formatInlineCommentsMarkdown(
    String pageTitle,
    List<Map<String, dynamic>> comments,
  ) {
    final sb = StringBuffer('# Inline comments: $pageTitle\n\n');
    for (final comment in comments) {
      final commentId = comment['id']?.toString() ?? 'unknown';
      final status = comment['resolutionStatus']?.toString() ?? 'unknown';
      final body = comment['body'];
      final storage = body is Map ? body['storage'] : null;
      final rawStorage =
          storage is Map ? (storage['value']?.toString() ?? '') : '';
      final bodyMd = rawStorage.trim().isEmpty
          ? '_(empty)_'
          : confluenceStorageToMarkdown(rawStorage);
      final props = comment['properties'];
      final selection = props is Map
          ? (props['inlineOriginalSelection']?.toString() ?? '')
          : '';
      sb.writeln('## Comment $commentId');
      sb.writeln('- **Status**: $status');
      if (selection.trim().isNotEmpty) {
        sb.writeln('- **Selected text**: $selection');
      }
      sb.writeln('- **Body**:\n\n$bodyMd\n');
    }
    return sb.toString();
  }

  /// The storage body with excerpt includes materialized (resolved in the
  /// page's own space when the include carries no space key) and user
  /// mentions replaced by `@Display Name` (Java `ConfluencePageDownloader`
  /// pipeline: `toMarkdown(mentionResolver.resolve(inliner.inline(…)))`).
  String _resolvedBody(Map<String, dynamic> content, String storage) {
    final inlined = _excerptInliner.inline(
      storage,
      confluenceSpaceKeyOf(content),
    );
    return _mentionResolver.resolve(inlined);
  }

  /// Drains [_attachmentPages]: concurrent listing fetches, then
  /// concurrent attachment downloads, then ordered file writes.
  void _downloadCollectedAttachments() {
    if (_attachmentPages.isEmpty) return;
    final listings = _runConfluenceParallel(_listingJobs());
    final downloads = <SyncParallelJob>[];
    final targets = <_AttachmentTarget>[];
    for (var i = 0; i < listings.length; i++) {
      _collectAttachmentJobs(
          listings[i], _attachmentPages[i], downloads, targets);
    }
    final responses = _runConfluenceParallel(downloads);
    for (var i = 0; i < responses.length; i++) {
      _writeAttachment(responses[i], targets[i]);
    }
  }

  /// One listing GET per collected page, keyed by the page position
  /// (v2-aware listing URL — Java `getContentAttachments` parity).
  List<SyncParallelJob> _listingJobs() => <SyncParallelJob>[
        for (var i = 0; i < _attachmentPages.length; i++)
          SyncParallelJob(
            index: i,
            kind: _kJobHttpGet,
            args: <String, dynamic>{
              ..._jobArgsOf(_config),
              'url': _attachmentsUrl(_config, _attachmentPages[i].contentId),
            },
          ),
      ];

  /// Parses one page's listing [envelope] and appends a download job +
  /// write target per attachment carrying a `_links.download` path.
  void _collectAttachmentJobs(
    Map<String, dynamic>? envelope,
    _AttachmentPage page,
    List<SyncParallelJob> downloads,
    List<_AttachmentTarget> targets,
  ) {
    final resp = _httpJobResponse(envelope);
    if (resp == null || !resp.isOk) return;
    final results =
        _childrenResults(resp.body) ?? const <Map<String, dynamic>>[];
    final baseHost = Uri.tryParse(_config.rootUrl)?.host;
    for (final attachment in results) {
      final downloadPath = _attachmentDownloadPath(attachment);
      if (downloadPath == null) continue;
      downloads.add(SyncParallelJob(
        index: downloads.length,
        kind: _kJobAttachmentGet,
        args: <String, dynamic>{
          ..._jobArgsOf(_config),
          'url': _attachmentUrl(downloadPath, _config.rootUrl),
          'headers': _attachmentHeaders(downloadPath, baseHost),
        },
      ));
      targets.add((
        pageFolder: page.pageFolder,
        title: _sanitize(attachment['title']?.toString() ?? 'file'),
      ));
    }
  }

  /// Writes one downloaded attachment next to its page.
  ///
  /// An HTTP-level failure never touches the disk: the body is buffered
  /// in memory and written once below, so unlike the Java
  /// truncate-then-stream download (`RestClient.downloadFile`, 8cbf550d)
  /// this port cannot leave a partial file behind — and a file that IS
  /// present is a complete attachment of an earlier successful run, which
  /// a failed re-download must keep (a stale local copy beats no copy).
  /// Only a mid-write I/O error can produce a partial file; that partial
  /// is removed so it never looks "already downloaded" to the next run.
  void _writeAttachment(
    Map<String, dynamic>? envelope,
    _AttachmentTarget target,
  ) {
    final resp = _httpJobResponse(envelope);
    if (resp == null || !resp.isOk) return; // never touched the file
    final file = _attachmentFile(target);
    try {
      file.writeAsBytesSync(resp.bodyBytes, flush: true);
    } catch (_) {
      _deleteQuietly(file); // we may have left a partial behind
    }
  }

  /// The target file of one attachment inside its page's folder.
  File _attachmentFile(_AttachmentTarget target) {
    final dir = Directory('${_output.path}/${target.pageFolder}-attachments')
      ..createSync(recursive: true);
    return File('${dir.path}/${target.title}');
  }

  /// Best-effort [file] removal (partial-download cleanup).
  void _deleteQuietly(File file) {
    try {
      if (file.existsSync()) file.deleteSync();
    } catch (_) {
      // Unremovable leftovers are logged by the caller's skip, not thrown.
    }
  }

  /// The `_links.download` path of [attachment]; `null` when absent or
  /// empty.
  static String? _attachmentDownloadPath(Map<String, dynamic> attachment) {
    final links = attachment['_links'];
    final downloadPath = links is Map ? links['download'] : null;
    return downloadPath is String && downloadPath.isNotEmpty
        ? downloadPath
        : null;
  }

  /// The fetch URL of an attachment: `_links.download` is relative to the
  /// site root (`/download/…`) unless it is already absolute.
  static String _attachmentUrl(String downloadPath, String rootUrl) =>
      downloadPath.startsWith('http') ? downloadPath : '$rootUrl$downloadPath';

  /// Headers for one attachment fetch. `_links.download` is
  /// server-controlled content: the Confluence credentials never travel
  /// to a foreign host.
  Map<String, String> _attachmentHeaders(
    String downloadPath,
    String? baseHost,
  ) {
    var headers = _config.headers;
    if (downloadPath.startsWith('http') &&
        Uri.tryParse(downloadPath)?.host != baseHost) {
      headers = {...headers}..removeWhere(
          (key, _) => key.toLowerCase() == HttpHeaders.authorizationHeader,
        );
    }
    return headers;
  }

  /// Filesystem-safe file name from a page title.
  static String _sanitize(String title) =>
      title.replaceAll(RegExp(r'[^A-Za-z0-9._ -]'), '_').trim();
}

/// Where one downloaded attachment lands: its page folder + file name.
typedef _AttachmentTarget = ({String pageFolder, String title});

/// Java `Confluence.ATTACHMENT_DOWNLOAD_ATTEMPTS` (dm.ai 8cbf550d):
/// total tries for one attachment download.
const confluenceAttachmentDownloadAttempts = 4;

/// Java `Confluence.ATTACHMENT_RETRY_BASE_DELAY_MS` (dm.ai 8cbf550d):
/// the backoff base; attempt `n` waits `base * 2^(n-1) + jitter(base/2)`.
const confluenceAttachmentRetryBaseDelayMs = 1000;

/// Java `Confluence.isTransientDownloadFailure` parity (dm.ai 8cbf550d):
/// 429/408, 5xx, and transport failures (`statusCode == 0` — any network
/// error surfaces as such in [SyncHttpResponse]) may succeed on retry;
/// other 4xx will not.
bool isConfluenceTransientAttachmentFailure(int statusCode) =>
    statusCode == 0 ||
    statusCode == 408 ||
    statusCode == 429 ||
    statusCode >= 500;

/// Downloads one attachment with the Java retry schedule (dm.ai
/// 8cbf550d): up to [confluenceAttachmentDownloadAttempts] tries, backing
/// off `baseDelayMs * 2^(attempt-1) + jitter(baseDelayMs / 2)` between
/// transient failures and giving up immediately on client errors.
///
/// [fetch], [sleepDelay], and [random] are injectable for tests. The
/// default transport ([SyncHttpClient.get]) applies its own retry policy
/// on top, so the schedules compose rather than conflict.
SyncHttpResponse fetchConfluenceAttachmentWithRetry(
  String url,
  Map<String, String> headers, {
  SyncHttpResponse Function(String url, Map<String, String> headers)? fetch,
  void Function(int delayMs)? sleepDelay,
  int baseDelayMs = confluenceAttachmentRetryBaseDelayMs,
  Random? random,
}) {
  final get =
      fetch ?? (url, headers) => SyncHttpClient.get(url, headers: headers);
  final pause = sleepDelay ?? (ms) => sleep(Duration(milliseconds: ms));
  final rnd = random ?? Random();
  for (var attempt = 1;; attempt++) {
    final resp = get(url, headers);
    if (resp.isOk ||
        !isConfluenceTransientAttachmentFailure(resp.statusCode) ||
        attempt >= confluenceAttachmentDownloadAttempts) {
      return resp;
    }
    final jitter = baseDelayMs < 2 ? 1 : rnd.nextInt(baseDelayMs ~/ 2);
    pause(baseDelayMs * (1 << (attempt - 1)) + jitter);
  }
}
