/// Extracts external references (Confluence URLs, Figma URLs, Jira keys,
/// GitHub issue references & inline attachments, ADO work item IDs) from
/// ticket/issue text.
///
/// Mirrors Java `IssuesIDsParser` (`extractConfluenceUrls`, `extractFigmaUrls`,
/// `extractAllJiraIDs`) while extending reference extraction to GitHub Issues
/// and Azure DevOps work items.
library;

/// Extracts structured references from ticket description and comment text.
class TicketReferenceExtractor {
  TicketReferenceExtractor._();

  static final RegExp _figmaUrlRegex = RegExp(
    r'(https?://(?:www\.)?figma\.com/(?:file|proto|design)/[^\s\]"<>)]+)',
    caseSensitive: false,
  );

  static final RegExp _jiraKeyRegex =
      RegExp(r'(?:\b|/browse/)([A-Z][A-Z0-9]+-\d+)\b');

  static final RegExp _githubIssueRefRegex = RegExp(
    r'(?:https?://github\.com/([\w.-]+/[\w.-]+)/issues/(\d+)\b|(?<![/\w.-])([\w.-]+/[\w.-]+)#(\d+)\b|(?<![/\w.-])#(\d+)\b|\bGH-(\d+)\b)',
    caseSensitive: false,
  );

  static final RegExp _adoWorkItemRefRegex = RegExp(
    r'(?:https?://[^\s"<>)\]]+/_workitems/edit/(\d+)\b|\bAB#(\d+)\b)',
    caseSensitive: false,
  );

  static final RegExp _markdownImageOrLink = RegExp(
    r'!?\[([^\]]*)\]\((https?://(?:github\.com/user-attachments/(?:assets|files)/[^\s)"<>]+|(?:private-)?user-images\.githubusercontent\.com/[^\s)"<>]+|github\.com/[\w.-]+/[\w.-]+/assets/[^\s)"<>]+))\)',
    caseSensitive: false,
  );

  static final RegExp _htmlImgTag = RegExp(
    r'<img\b[^>]*?\bsrc=["\x27](https?://(?:github\.com/user-attachments/assets/[^"\x27\s<>]+|(?:private-)?user-images\.githubusercontent\.com/[^"\x27\s<>]+|github\.com/[\w.-]+/[\w.-]+/assets/[^"\x27\s<>]+))["\x27][^>]*>',
    caseSensitive: false,
  );

  /// Extracts unique Confluence page URLs matching [confluenceBasePath] from
  /// [text] (Java `IssuesIDsParser.extractConfluenceUrls` parity).
  static List<String> extractConfluenceUrls(
    String? confluenceBasePath,
    String? text,
  ) {
    final domain = _confluenceBaseDomain(confluenceBasePath);
    if (domain == null || text == null || text.isEmpty) return const [];
    final pattern = RegExp(
      '${RegExp.escape(domain)}/(?:wiki/|l/cp/|spaces/|pages/|display/|x/)[^"\\s|\\]\\\\<>)]+',
    );
    final seen = <String>{};
    for (final match in pattern.allMatches(text)) {
      final cleaned = cleanupUrl(match.group(0)!);
      if (cleaned.isNotEmpty) seen.add(cleaned);
    }
    return seen.toList(growable: false);
  }

  static String? _confluenceBaseDomain(String? confluenceBasePath) {
    final trimmed =
        confluenceBasePath?.trim().replaceAll(RegExp(r'/+$'), '') ?? '';
    if (trimmed.isEmpty) return null;
    final wikiIdx = trimmed.lastIndexOf('/wiki');
    final domain = wikiIdx >= 0 ? trimmed.substring(0, wikiIdx) : trimmed;
    return domain.isEmpty ? null : domain;
  }

  /// Extracts unique Figma design/file/proto URLs from [text]
  /// (Java `IssuesIDsParser.extractFigmaUrls` parity).
  static List<String> extractFigmaUrls(String? text) {
    if (text == null || text.isEmpty) return const [];
    final seen = <String>{};
    for (final match in _figmaUrlRegex.allMatches(text)) {
      final raw = match.group(1);
      if (raw == null) continue;
      final cleaned = _removeFigmaTimeParam(cleanupUrl(raw));
      if (_isValidFigmaUrl(cleaned)) {
        seen.add(cleaned);
      }
    }
    return seen.toList(growable: false);
  }

  /// Extracts unique Jira issue keys (`PROJ-123`) from [text], applying
  /// optional [ignorePrefixes] and [allowedPrefixes] filters
  /// (Java `IssuesIDsParser.extractAllJiraIDs` parity).
  static List<String> extractJiraKeys(
    String? text, {
    Set<String> ignorePrefixes = const {},
    Set<String> allowedPrefixes = const {},
  }) {
    if (text == null || text.isEmpty) return const [];
    final normIgnore = _normalizePrefixSet(ignorePrefixes);
    final normAllow = _normalizePrefixSet(allowedPrefixes);
    final seen = <String>{};
    for (final match in _jiraKeyRegex.allMatches(text)) {
      final key = match.group(1);
      if (key != null && _isPrefixAllowed(key, normAllow, normIgnore)) {
        seen.add(key);
      }
    }
    return seen.toList(growable: false);
  }

  static Set<String> _normalizePrefixSet(Set<String> raw) =>
      raw.map((p) => p.trim().toUpperCase()).where((p) => p.isNotEmpty).toSet();

  static bool _isPrefixAllowed(
    String key,
    Set<String> allowed,
    Set<String> ignored,
  ) {
    final prefix = key.split('-').first.toUpperCase();
    if (allowed.isNotEmpty && !allowed.contains(prefix)) return false;
    return !ignored.contains(prefix);
  }

  /// Extracts referenced GitHub issues from [text] (`owner/repo#123`,
  /// `https://github.com/owner/repo/issues/123`, `#123`, `GH-123`).
  ///
  /// Bare `#123` / `GH-123` references are only extracted when [defaultRepo]
  /// (`owner/repo`) is provided, avoiding false positives on non-GitHub text.
  static List<String> extractGithubIssueKeys(
    String? text, {
    String? defaultRepo,
  }) {
    if (text == null || text.isEmpty) return const [];
    final repo = (defaultRepo != null && defaultRepo.contains('/'))
        ? defaultRepo.trim()
        : null;
    final seen = <String>{};
    for (final m in _githubIssueRefRegex.allMatches(text)) {
      final resolved = _resolveGithubMatch(m, repo);
      if (resolved != null) seen.add(resolved);
    }
    return seen.toList(growable: false);
  }

  static String? _resolveGithubMatch(RegExpMatch m, String? defaultRepo) {
    if (m.group(1) != null && m.group(2) != null) {
      return '${m.group(1)}#${m.group(2)}';
    }
    if (m.group(3) != null && m.group(4) != null) {
      return '${m.group(3)}#${m.group(4)}';
    }
    final bareNum = m.group(5) ?? m.group(6);
    if (bareNum != null && defaultRepo != null) {
      return '$defaultRepo#$bareNum';
    }
    return null;
  }

  /// Extracts referenced Azure DevOps work item IDs from [text]
  /// (`https://.../_workitems/edit/123` or `AB#123`).
  static List<String> extractAdoWorkItemIds(String? text) {
    if (text == null || text.isEmpty) return const [];
    final seen = <String>{};
    for (final m in _adoWorkItemRefRegex.allMatches(text)) {
      final id = m.group(1) ?? m.group(2);
      if (id != null && id.isNotEmpty) seen.add(id);
    }
    return seen.toList(growable: false);
  }

  /// Extracts inline GitHub attachment/image URLs from Markdown (`![alt](url)`,
  /// `[name](url)`) and HTML (`<img src="url">`) in [text].
  static List<({String name, String url})> extractGithubInlineAttachments(
    String? text,
  ) {
    if (text == null || text.isEmpty) return const [];
    final seenUrls = <String>{};
    final results = <({String name, String url})>[];
    for (final m in _markdownImageOrLink.allMatches(text)) {
      _addAttachmentIfNew(
        results,
        seenUrls,
        m.group(1)?.trim() ?? '',
        m.group(2) ?? '',
      );
    }
    for (final m in _htmlImgTag.allMatches(text)) {
      _addAttachmentIfNew(results, seenUrls, '', m.group(1) ?? '');
    }
    return results;
  }

  static void _addAttachmentIfNew(
    List<({String name, String url})> results,
    Set<String> seenUrls,
    String label,
    String rawUrl,
  ) {
    final url = cleanupUrl(rawUrl);
    if (url.isNotEmpty && seenUrls.add(url)) {
      final name = _deriveGithubAttachmentName(label, url, results.length + 1);
      results.add((name: name, url: url));
    }
  }

  static String _deriveGithubAttachmentName(
    String label,
    String url,
    int index,
  ) {
    final uri = Uri.tryParse(url);
    final lastSeg =
        uri != null && uri.pathSegments.isNotEmpty ? uri.pathSegments.last : '';
    final hasExt = RegExp(r'\.[A-Za-z0-9]{2,5}$').hasMatch(lastSeg);
    if (hasExt) return lastSeg;
    if (label.isNotEmpty && RegExp(r'\.[A-Za-z0-9]{2,5}$').hasMatch(label)) {
      return label.replaceAll(RegExp(r'[^\w.\-]'), '_');
    }
    final idPart = lastSeg.isNotEmpty ? lastSeg : '$index';
    return 'github_attachment_$idPart.png';
  }

  /// Cleans trailing punctuation, HTML entities, and wiki markup from [url]
  /// (Java `IssuesIDsParser.cleanupUrl` parity).
  static String cleanupUrl(String url) {
    var cleaned = url.replaceAll('&amp;', '&');
    cleaned = cleaned.split(']').first;
    cleaned = cleaned.split(RegExp(r'\s+')).first;
    cleaned = cleaned.split('|').first;
    cleaned = cleaned.replaceAll(RegExp(r'[\]\\)>]+$'), '');
    cleaned = cleaned.replaceAll(RegExp(r'[^\w\-/_:.&=?%]+$'), '');
    return cleaned;
  }

  static bool _isValidFigmaUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    if (host != 'www.figma.com' && host != 'figma.com') return false;
    final path = uri.path;
    if (!path.startsWith('/file/') &&
        !path.startsWith('/proto/') &&
        !path.startsWith('/design/')) {
      return false;
    }
    return RegExp(r'figma\.com/(?:file|proto|design)/[\w-]+').hasMatch(url);
  }

  static String _removeFigmaTimeParam(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasQuery) return url;
    final kept = uri.query
        .split('&')
        .where((p) => p.isNotEmpty && !p.startsWith('t='))
        .toList();
    return uri
        .replace(query: kept.isEmpty ? null : kept.join('&'))
        .toString()
        .replaceAll(RegExp(r'\?$'), '');
  }
}
