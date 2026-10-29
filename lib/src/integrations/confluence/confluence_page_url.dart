/// Confluence page-URL resolution — ports the Java `contentByUrl` segment
/// walk (`handleWikiUrls` / `checkBaseIndex` in `Confluence.java`).
///
/// Recognised shapes:
/// - `/wiki/spaces/{space}/pages/{id}[/{title}]` (also without `/wiki`) →
///   [ConfluencePageIdRef]
/// - `/wiki/display/{space}/{title}` → [ConfluenceDisplayRef]
/// - `/wiki/x/{key}` and `/l/...` short links → [ConfluenceRedirectRef]
///   (the caller must resolve the 3xx Location first)
/// - anything else → [ConfluenceUnknownUrlRef]
library;

/// Where a Confluence page URL points.
sealed class ConfluencePageRef {
  const ConfluencePageRef();
}

/// A REST content id extracted from the URL.
class ConfluencePageIdRef extends ConfluencePageRef {
  /// The REST content id.
  final String id;

  /// Creates a reference carrying [id].
  const ConfluencePageIdRef(this.id);
}

/// A title-in-space lookup (`/display/{space}/{title}`).
class ConfluenceDisplayRef extends ConfluencePageRef {
  /// The space key (possibly a user key like `~jdoe`).
  final String space;

  /// The percent-decoded page title.
  final String title;

  /// Creates a display reference for [title] in [space].
  const ConfluenceDisplayRef(this.space, this.title);
}

/// A short link (`/wiki/x/{key}`, `/l/...`) that answers a 3xx redirect.
class ConfluenceRedirectRef extends ConfluencePageRef {
  const ConfluenceRedirectRef();
}

/// An URL shape the resolver does not understand.
class ConfluenceUnknownUrlRef extends ConfluencePageRef {
  const ConfluenceUnknownUrlRef();
}

/// Resolves [url] into a [ConfluencePageRef], mirroring the Java switch:
/// `spaces`/`pages` walk with a fallback base index (paths come either as
/// `/wiki/spaces/…` or `/spaces/…`).
ConfluencePageRef resolveConfluencePageUrl(Uri url) {
  final segments = [
    for (final s in url.pathSegments)
      if (s.isNotEmpty) s,
  ];
  if (segments.isEmpty) return const ConfluenceUnknownUrlRef();

  // Short links must be resolved through their 3xx Location first; the key
  // in the path is not a REST content id.
  final first = segments.first.toLowerCase();
  if (first == 'l') return const ConfluenceRedirectRef();
  final wikiIndex = first == 'wiki' ? 1 : 0;
  if (wikiIndex < segments.length && segments[wikiIndex].toLowerCase() == 'x') {
    return const ConfluenceRedirectRef();
  }
  return _checkBaseIndex(segments, wikiIndex);
}

/// The Java `checkBaseIndex` walk over [segments] starting at [base].
ConfluencePageRef _checkBaseIndex(List<String> segments, int base) {
  if (base >= segments.length) return const ConfluenceUnknownUrlRef();
  switch (segments[base]) {
    case 'spaces':
      // /spaces/{space}/pages/{pageId}[/{title}]
      if (segments.length > base + 3 && segments[base + 2] == 'pages') {
        return ConfluencePageIdRef(segments[base + 3]);
      }
    case 'display':
      // /display/{userIdentifier}/{pageName}
      if (segments.length > base + 2) {
        return ConfluenceDisplayRef(
          segments[base + 1],
          // Java URLDecoder maps a literal '+' to a space (display URLs
          // encode spaces as '+'); percent-encoded '+', once decoded by
          // Uri.pathSegments, is already literal at this point.
          segments[base + 2].replaceAll('+', ' '),
        );
      }
  }
  return const ConfluenceUnknownUrlRef();
}

/// Builds the CQL query for `confluence_search_content_by_text` (gh-739):
/// scopes to [defaultSpace] when configured (non-empty) and [query] does
/// not already specify a `space =` / `space in` clause.
String buildConfluenceTextSearchCql(String query, String? defaultSpace) {
  final space = defaultSpace?.trim() ?? '';
  final textClause = '(title ~ "$query" OR text ~ "$query")';
  final scoped = space.isNotEmpty && !_hasSpaceClause(query)
      ? '$textClause AND space = "$space"'
      : textClause;
  return '$scoped ORDER BY lastModified ASC';
}

/// Whether [query] already carries an explicit `space =` or `space in`
/// CQL clause (case-insensitive).
bool _hasSpaceClause(String query) =>
    RegExp(r'\bspace\s*(?:=|in\b)', caseSensitive: false).hasMatch(query);
