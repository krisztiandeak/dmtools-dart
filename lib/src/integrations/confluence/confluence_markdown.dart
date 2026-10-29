/// Markdown ↔ Confluence Storage Format converters.
///
/// Pragmatic Dart port of the Java `MarkdownToConfluenceStorage` /
/// `ConfluenceStorageMarkdown` pair. The Java side leans on flexmark + jsoup;
/// this port hand-parses the CommonMark subset the discovery agents emit
/// (headings, paragraphs, emphasis, inline code, fenced code, lists, task
/// lists, tables, links, images, blockquotes, rules) and the storage tags
/// this module itself produces plus the plain XHTML Confluence returns.
///
/// Known deviations from the flexmark/jsoup original: mixed task/plain lists
/// render as a task list with plain items marked incomplete; exotic constructs
/// (footnotes, definition lists, raw HTML in Markdown) pass through escaped.
library;

import 'dart:convert';

/// Storage → Markdown internals live in the part file below.
part 'confluence_markdown_storage.dart';

/// Excerpt-include / mention resolvers (Java `ConfluenceExcerptInliner` /
/// `ConfluenceMentionResolver` parity).
part 'confluence_markdown_resolvers.dart';

/// File extensions Confluence treats as downloadable attachments.
const attachmentExtensions = {
  'pdf',
  'doc',
  'docx',
  'xls',
  'xlsx',
  'ppt',
  'pptx',
  'png',
  'jpg',
  'jpeg',
  'gif',
  'svg',
  'webp',
  'zip',
  'tar',
  'gz',
  'tgz',
  'bz2',
  '7z',
  'txt',
  'csv',
  'json',
  'xml',
  'yaml',
  'yml',
  'html',
  'md',
};

/// Whether [url] points outside the wiki (http, https, mailto, …).
bool isExternalUrl(String url) {
  final lower = url.toLowerCase();
  return lower.startsWith('http://') ||
      lower.startsWith('https://') ||
      lower.startsWith('mailto:') ||
      lower.startsWith('ftp://');
}

/// Escapes XML text nodes and attribute values.
String escapeXml(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

/// Unescapes the XML entities [escapeXml] produces (`&amp;` last on purpose).
String unescapeXml(String text) => text
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&amp;', '&');

/// Converts [markdown] into Confluence Storage Format XHTML.
String markdownToConfluenceStorage(String markdown) {
  if (markdown.trim().isEmpty) return '';
  final blocks = _parseBlocks(_normalizeLegacyLinks(markdown));
  return blocks.map(_renderBlock).join();
}

/// Converts plain-text [text] into `<p>`-wrapped storage XHTML for inline
/// comment replies (Java `Confluence.prepareInlineCommentBody` parity).
String prepareConfluenceInlineCommentBody(String text) {
  if (text.trim().isEmpty) return '<p></p>';
  final lines = text
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .map((l) => '<p>${escapeXml(l)}</p>')
      .toList();
  return lines.isEmpty ? '<p></p>' : lines.join('\n');
}

/// Converts Confluence Storage Format [storage] into Markdown.
String confluenceStorageToMarkdown(String storage) {
  if (storage.trim().isEmpty) return '';
  final root = _parseXml(storage);
  final rendered = _storageNodeToMarkdown(root);
  final cleaned = rendered
      .replaceAll(RegExp(r'[ \t]+\n'), '\n')
      .replaceAll(RegExp(r'\n[ \t]+\n'), '\n\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
  return cleaned;
}

/// Extracts local attachment file names referenced by images/links in
/// [markdown] (mirrors `MarkdownToConfluenceStorage.extractAttachmentReferences`).
Set<String> extractAttachmentReferences(String markdown) {
  final names = <String>{};
  final images = RegExp(r'!\[([^\]]*)\]\(([^)]+)\)', dotAll: true);
  for (final m in images.allMatches(markdown)) {
    _addIfAttachment(names, _stripTitle(m.group(2)!));
  }
  final links = RegExp(r'\[([^\]]*)\]\(([^)]+)\)', dotAll: true);
  for (final m in links.allMatches(markdown)) {
    _addIfAttachment(names, _stripTitle(m.group(2)!));
  }
  return names;
}

/// Adds [rawUrl]'s file name when it is a local attachment reference.
void _addIfAttachment(Set<String> names, String rawUrl) {
  final url = rawUrl.trim();
  if (url.isEmpty || isExternalUrl(url) || url.startsWith('#')) return;
  final path = url.split('?').first.split('#').first;
  final name = path.split('/').last;
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return;
  if (attachmentExtensions.contains(name.substring(dot + 1).toLowerCase())) {
    names.add(name);
  }
}

/// Strips a Markdown ` "title"` suffix from a link destination.
String _stripTitle(String url) {
  final m = RegExp(r'^(\S+)\s+"[^"]*"\s*$').firstMatch(url.trim());
  return m?.group(1) ?? url.trim();
}

/// Wraps link/image destinations containing spaces in `%20` (the legacy
/// exporter emits `[text](Page Title)` — mirrors `normalizeLegacyLinks`).
String _normalizeLegacyLinks(String markdown) {
  final pattern = RegExp(r'(!?\[[^\]]*\])\(([^)]+)\)', dotAll: true);
  return markdown.replaceAllMapped(pattern, (m) {
    final url = m.group(2)!.trim();
    if (!url.contains(' ') || url.startsWith('<')) return m[0]!;
    return '${m.group(1)}(${url.replaceAll(' ', '%20')})';
  });
}

// ── Markdown → storage: block parsing ──────────────────────────────────────

/// A parsed Markdown block: [kind] plus its payload.
class _Block {
  final String kind;

  /// Paragraph/heading/code text, or assembled `<tbody>` for tables.
  final String text;

  /// Fence info string, or per-item task flags (`-` plain, `u`/`c` task).
  final String? info;

  /// List item bodies (each a list of blocks), or quote/inner children.
  final List<List<_Block>> children;

  const _Block(this.kind, this.text, {this.info, this.children = const []});
}

final _fence = RegExp(r'^\s*(```|~~~)\s*(\S*)\s*$');
final _heading = RegExp(r'^(#{1,6})\s+(.*\S)\s*$');
final _hr = RegExp(r'^\s{0,3}((-\s*){3,}|(\*\s*){3,}|(_\s*){3,})$');
final _ulItem = RegExp(r'^(\s*)([-*+])\s+(.*)$');
final _olItem = RegExp(r'^(\s*)(\d+)[.)]\s+(.*)$');
final _quote = RegExp(r'^\s{0,3}>\s?(.*)$');
final _task = RegExp(r'^\[( |x|X)\]\s+(.*)$');
final _tableRow = RegExp(r'^\s*\|.*\|\s*$');
final _tableSplit = RegExp(r'^\s*\|?[\s:|-]*-{3,}[\s:|-]*\|?\s*$');

/// Splits [markdown] into top-level blocks.
List<_Block> _parseBlocks(String markdown) {
  final blocks = <_Block>[];
  final lines = markdown.replaceAll('\r\n', '\n').split('\n');
  var i = 0;
  while (i < lines.length) {
    final consumed = _parseOneBlock(lines, i, blocks);
    i += consumed > 0 ? consumed : 1;
  }
  return blocks;
}

/// Parses the block starting at [i] into [blocks]; returns lines consumed.
int _parseOneBlock(List<String> lines, int i, List<_Block> blocks) {
  final line = lines[i];
  final single = _singleLineBlock(line, blocks);
  if (single != null) return single;
  final fence = _fence.firstMatch(line);
  if (fence != null) return _parseFence(lines, i, fence, blocks);
  if (_startsTable(line, i, lines)) return _parseTable(lines, i, blocks);
  if (_ulItem.hasMatch(line) || _olItem.hasMatch(line)) {
    return _parseList(lines, i, blocks, 0);
  }
  if (_quote.hasMatch(line)) return _parseQuote(lines, i, blocks);
  return _parseParagraph(lines, i, blocks);
}

/// Parses a blank line, ATX heading, or thematic rule (all one-liners);
/// `null` when [line] opens none of them.
int? _singleLineBlock(String line, List<_Block> blocks) {
  if (line.trim().isEmpty) return 1;
  final heading = _heading.firstMatch(line);
  if (heading != null) {
    blocks.add(_Block('h${heading.group(1)!.length}', heading.group(2)!));
    return 1;
  }
  if (_hr.hasMatch(line)) {
    blocks.add(const _Block('hr', ''));
    return 1;
  }
  return null;
}

/// Consumes a fenced code block starting at [i].
int _parseFence(
  List<String> lines,
  int i,
  RegExpMatch fence,
  List<_Block> blocks,
) {
  final marker = fence.group(1)!;
  final body = <String>[];
  var j = i + 1;
  while (j < lines.length && !lines[j].trim().startsWith(marker)) {
    body.add(lines[j]);
    j++;
  }
  blocks.add(_Block('code', body.join('\n'), info: fence.group(2)));
  return j - i + 1;
}

/// Consumes a table (header, separator, rows) starting at [i].
int _parseTable(List<String> lines, int i, List<_Block> blocks) {
  final rows = <List<String>>[_splitRow(lines[i])];
  var j = i + 2; // skip the |---|---| separator line
  while (j < lines.length && _tableRow.hasMatch(lines[j])) {
    rows.add(_splitRow(lines[j]));
    j++;
  }
  final buf = StringBuffer();
  for (var r = 0; r < rows.length; r++) {
    final tag = r == 0 ? 'th' : 'td';
    final cells =
        rows[r].map((c) => '<$tag>${_inline(c.trim())}</$tag>').join();
    buf.write('<tr>$cells</tr>');
  }
  blocks.add(_Block('table', '<tbody>$buf</tbody>'));
  return j - i;
}

/// Splits one GFM table row into cells.
List<String> _splitRow(String row) {
  var s = row.trim();
  if (s.startsWith('|')) s = s.substring(1);
  if (s.endsWith('|')) s = s.substring(0, s.length - 1);
  return s.split('|');
}

/// Consumes a list at [i] whose items sit at column [indent].
int _parseList(List<String> lines, int i, List<_Block> blocks, int indent) {
  final items = <List<_Block>>[];
  final flags = StringBuffer(); // per item: '-', 'u' (unchecked), 'c' (checked)
  var taskList = false;
  final ordered = _olItem.hasMatch(lines[i]);
  var j = i;
  while (j < lines.length) {
    final m = _listItemMatch(lines[j]);
    if (m == null || m.group(1)!.length < indent) break;
    if (m.group(1)!.length > indent) {
      j += _parseNestedTail(lines, j, items, m.group(1)!.length);
      continue;
    }
    if (_olItem.hasMatch(lines[j]) != ordered) break;
    if (_appendListItem(items, flags, m)) taskList = true;
    j++;
  }
  blocks.add(_listBlock(taskList, ordered, flags.toString(), items));
  return j - i;
}

/// The list-item marker on [line] (unordered or ordered), or `null`.
RegExpMatch? _listItemMatch(String line) =>
    _ulItem.firstMatch(line) ?? _olItem.firstMatch(line);

/// The block for a parsed list: task list, ordered, or unordered.
_Block _listBlock(
  bool taskList,
  bool ordered,
  String flags,
  List<List<_Block>> items,
) =>
    _Block(
      taskList ? 'tasks' : (ordered ? 'ol' : 'ul'),
      '',
      info: flags,
      children: items,
    );

/// Parses one list item's payload into [items]/[flags] (`-` plain, `u`
/// unchecked, `c` checked); returns whether the item was a task item.
bool _appendListItem(
  List<List<_Block>> items,
  StringBuffer flags,
  RegExpMatch m,
) {
  final task = _task.firstMatch((m.group(3) ?? '').trim());
  if (task == null) {
    flags.write('-');
    items.add(_parseBlocks((m.group(3) ?? '').trim()));
    return false;
  }
  flags.write(task.group(1)!.toLowerCase() == 'x' ? 'c' : 'u');
  items.add([_Block('para', task.group(2)!)]);
  return true;
}

/// Parses the nested-list tail of the current item at [j]; returns consumed.
int _parseNestedTail(
  List<String> lines,
  int j,
  List<List<_Block>> items,
  int childIndent,
) {
  final nested = <_Block>[];
  final consumed = _parseList(lines, j, nested, childIndent);
  if (items.isEmpty) items.add(const []);
  items.last.addAll(nested);
  return consumed;
}

/// Consumes a blockquote starting at [i].
int _parseQuote(List<String> lines, int i, List<_Block> blocks) {
  final inner = <String>[];
  var j = i;
  while (j < lines.length) {
    final m = _quote.firstMatch(lines[j]);
    if (m == null) break;
    inner.add(m.group(1)!);
    j++;
  }
  blocks.add(
    _Block('blockquote', '', children: [_parseBlocks(inner.join('\n'))]),
  );
  return j - i;
}

/// Consumes a paragraph starting at [i] (until blank line or new block).
int _parseParagraph(List<String> lines, int i, List<_Block> blocks) {
  final buf = <String>[];
  var j = i;
  while (j < lines.length &&
      lines[j].trim().isNotEmpty &&
      !_startsBlock(lines[j], j, lines)) {
    buf.add(lines[j].trim());
    j++;
  }
  blocks.add(_Block('para', buf.join(' ')));
  return j - i;
}

/// Whether [line] opens a non-paragraph block (paragraph terminator).
bool _startsBlock(String line, int i, List<String> lines) {
  if (_startsWithAtomicBlock(line)) return true;
  if (_ulItem.hasMatch(line) || _olItem.hasMatch(line)) return true;
  if (_quote.hasMatch(line)) return true;
  return _startsTable(line, i, lines);
}

/// Whether [line] alone opens a block (fence, heading, or rule).
bool _startsWithAtomicBlock(String line) =>
    _fence.hasMatch(line) || _heading.hasMatch(line) || _hr.hasMatch(line);

/// Whether [line] starts a GFM table (row plus a `|---|` separator next).
bool _startsTable(String line, int i, List<String> lines) =>
    _tableRow.hasMatch(line) &&
    i + 1 < lines.length &&
    _tableSplit.hasMatch(lines[i + 1]);

// ── Markdown → storage: rendering ──────────────────────────────────────────

/// Renders one parsed [block] into storage XHTML.
String _renderBlock(_Block block) {
  switch (block.kind) {
    case 'code':
      return _renderCodeMacro(block);
    case 'blockquote':
      return '<blockquote>${block.children.first.map(_renderBlock).join()}'
          '</blockquote>';
    case 'table':
      return '<table>${block.text}</table>';
    case 'ul':
    case 'ol':
    case 'tasks':
      return _renderList(block);
    default:
      return _renderLeaf(block);
  }
}

/// Renders a leaf block: rule, paragraph, heading, or unknown container.
String _renderLeaf(_Block block) {
  if (block.kind == 'hr') return '<hr/>';
  if (block.kind == 'para') return '<p>${_inline(block.text)}</p>';
  return '<${block.kind}>${_inline(block.text)}</${block.kind}>';
}

/// Renders a fenced code block as a Confluence `code` macro.
String _renderCodeMacro(_Block block) {
  final lang = block.info ?? '';
  final param = lang.isEmpty
      ? ''
      : '<ac:parameter ac:name="language">${escapeXml(lang)}</ac:parameter>';
  return '<ac:structured-macro ac:name="code">$param'
      '<ac:plain-text-body><![CDATA[${block.text}]]>'
      '</ac:plain-text-body></ac:structured-macro>';
}

/// Renders a list block (`ul`, `ol`, or `tasks`).
String _renderList(_Block block) {
  final flags = block.info ?? '';
  if (block.kind == 'tasks') {
    final items = <String>[];
    for (var i = 0; i < block.children.length; i++) {
      final status =
          i < flags.length && flags[i] == 'c' ? 'complete' : 'incomplete';
      final body = block.children[i].map(_renderBlock).join();
      items.add('<ac:task><ac:task-status>$status</ac:task-status>'
          '<ac:task-body>$body</ac:task-body></ac:task>');
    }
    return '<ac:task-list>${items.join()}</ac:task-list>';
  }
  final items = [
    for (final item in block.children)
      '<li>${item.map(_renderBlock).join()}</li>',
  ];
  return '<${block.kind}>${items.join()}</${block.kind}>';
}

/// Renders inline Markdown ([text]) into storage XHTML.
String _inline(String text) {
  final stash = <String>[];
  var work = _stashPattern(text, stash, RegExp(r'`([^`]+)`'),
      (m) => '<code>${escapeXml(m[1]!)}</code>');
  work = _stashPattern(
      work, stash, RegExp(r'!\[([^\]]*)\]\(([^)]+)\)'), _renderImage);
  work = _stashPattern(
      work, stash, RegExp(r'\[([^\]]*)\]\(([^)]+)\)'), _renderLink);
  work = _stashPattern(work, stash, RegExp(r'\*\*([^*]+)\*\*'),
      (m) => '<strong>${escapeXml(m[1]!)}</strong>');
  work = _stashPattern(work, stash, RegExp(r'(?<!\*)\*([^*\n]+)\*(?!\*)'),
      (m) => '<em>${escapeXml(m[1]!)}</em>');
  work = _stashPattern(work, stash, RegExp(r'~~([^~]+)~~'),
      (m) => '<del>${escapeXml(m[1]!)}</del>');
  work = _stashPattern(
      work,
      stash,
      RegExp(r'(?<![\("=\u0000])(https?://[^\s<)]+)'),
      (m) => '<a href="${escapeXml(m[1]!)}">${escapeXml(m[1]!)}</a>');
  return _restore(escapeXml(work), stash);
}

/// Applies [render] to every [pattern] match, stashing the output.
String _stashPattern(
  String text,
  List<String> stash,
  RegExp pattern,
  String Function(RegExpMatch) render,
) {
  return text.replaceAllMapped(pattern, (m) {
    stash.add(render(m as RegExpMatch));
    return '\u0000${stash.length - 1}\u0000';
  });
}

/// Restores stashed fragments into escaped [text].
String _restore(String text, List<String> stash) => text.replaceAllMapped(
      RegExp('\u0000(\\d+)\u0000'),
      (m) => stash[int.parse(m.group(1)!)],
    );

/// Renders a Markdown image reference.
String _renderImage(RegExpMatch m) {
  final alt = m[1]!;
  final url = _stripTitle(m[2]!);
  if (isExternalUrl(url)) {
    return '<img src="${escapeXml(url)}" alt="${escapeXml(alt)}"/>';
  }
  final name = url.split('/').last;
  return '<ac:image><ri:attachment ri:filename="${escapeXml(name)}"/>'
      '</ac:image>';
}

/// Renders a Markdown link reference.
String _renderLink(RegExpMatch m) {
  final label = m[1]!;
  final url = _stripTitle(m[2]!);
  if (isExternalUrl(url) || url.startsWith('#')) {
    return '<a href="${escapeXml(url)}">${escapeXml(label)}</a>';
  }
  final body = '<ac:link-body>${escapeXml(label)}</ac:link-body>';
  final name = url.split('/').last;
  if (extractAttachmentReferences('![]($url)').contains(name)) {
    return '<ac:link><ri:attachment ri:filename="${escapeXml(name)}"/>'
        '$body</ac:link>';
  }
  return '<ac:link><ri:page ri:content-title="${escapeXml(url)}"/>'
      '$body</ac:link>';
}
