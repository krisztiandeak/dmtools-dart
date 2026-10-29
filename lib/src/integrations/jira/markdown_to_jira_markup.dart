/// Markdown / HTML → Jira wiki markup conversion for comment bodies posted
/// through the Jira sync path (gh-191, P6-JSY-09).
///
/// Dart port of the Java `MarkdownToJiraConverter.convertToJiraMarkdown`
/// (`dmtools-core/.../common/utils/MarkdownToJiraConverter.java`) — the
/// exact converter Java `JiraClient.postComment` runs when
/// `TrackerClient.TextType == MARKDOWN` (which `BasicJiraClient` always
/// returns for Jira), so agent-authored Markdown comments render with Jira
/// wiki formatting instead of raw Markdown.
///
/// The Java converter has three input branches, all ported here:
/// - **pure Markdown** (no HTML tags outside code spans/fences):
///   ``` fences → `{code:lang}…{code}`, `#`-headings → `hN.`, `**bold**` →
///   `*bold*`, `` `code` `` → `{{code}}`, `[t](u)` → `[t|u]`,
///   `![name|attrs]` → `!name|attrs!`;
/// - **pure HTML**: walked with an HTML DOM (package:html — the Jsoup
///   equivalent), block elements → Jira constructs (`<ul>` → `* item`,
///   `<table>` → `|cell|`/`||header||`, `<pre><code>` → `{code:lang}`);
/// - **mixed**: split on blank lines, each chunk routed to the branch that
///   matches it, ```` ``` ```` and `<code>` spans preserved verbatim across
///   the round trip via [HtmlCodeBlockPreserver].
library;

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' show parse;

/// Converts [input] (Markdown, HTML, or a mix) to Jira wiki markup.
///
/// Empty/whitespace-only input yields `""`; a body consisting solely of HTML
/// entities is decoded as-is; otherwise the Markdown/HTML branches above
/// apply. Mirrors `MarkdownToJiraConverter.convertToJiraMarkdown`.
String markdownToJiraMarkup(String? input) {
  if (input == null || input.trim().isEmpty) return '';
  if (_containsOnlyHtmlEntities(input)) return decodeHtmlEntities(input);
  return switch (_classifyInput(input)) {
    _InputKind.mixed => _convertMixedContent(input),
    _InputKind.html => _convertHtmlToJiraMarkup(input),
    _InputKind.markdown => _convertMarkdownToJiraMarkup(input),
  };
}

/// Which converter branch an input routes to (the Java
/// `hasMarkdown`×`hasHtml` dispatch, extracted for testability).
enum _InputKind { markdown, html, mixed }

/// Classifies [input] by its content markers: both Markdown and HTML
/// markers → [._InputKind.mixed], HTML only → [._InputKind.html],
/// otherwise Markdown.
_InputKind _classifyInput(String input) {
  final hasMarkdown =
      input.contains('#') || input.contains('```') || input.contains('* ');
  final hasHtml = containsHtmlTags(input);
  if (hasMarkdown && hasHtml) return _InputKind.mixed;
  return hasHtml ? _InputKind.html : _InputKind.markdown;
}

/// Marker a `<code>` span is swapped for while the surrounding body is
/// converted; [HtmlCodeBlockPreserver.restoreCodeBlocks] swaps the Jira
/// `{code}` construct back in.
const codeBlockPlaceholder = '___CODE_BLOCK_PLACEHOLDER___';

/// Decodes the five basic HTML entities (`&lt; &gt; &amp; &quot; &apos;`).
///
/// Java parity: `MarkdownToJiraConverter.unescapeHtml` performs exactly these
/// replacements (its post-pass `-%gt;` rewrite is dead code — `&gt;` is
/// already gone) plus newline normalization.
String decodeHtmlEntities(String s) => s
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&amp;', '&')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll(RegExp(r'\r\n?|\u2028|\u2029'), '\n');

/// Whether [input] consists solely of HTML entity references.
bool _containsOnlyHtmlEntities(String input) {
  if (!input.contains('&')) return false;
  return input.replaceAll(RegExp(r'&[a-zA-Z]+;'), '').trim().isEmpty;
}

/// Whether [s] contains HTML tags outside code fences and inline code spans.
///
/// Java parity: `containsHtml` strips ```-fenced blocks and `` ` `` spans
/// before testing `<[^>]+>`.
bool containsHtmlTags(String s) {
  final noFences = s.replaceAll(RegExp(r'```(\w*)\n([\s\S]*?)```'), '');
  final noCode = noFences.replaceAll(RegExp(r'`[^`]*`'), '');
  return RegExp(r'<[^>]+>').hasMatch(noCode);
}

/// Mixed branch: split on blank lines and route each chunk to the Markdown
/// or HTML converter (Java `convertMixedContent`).
String _convertMixedContent(String input) {
  final preserver = HtmlCodeBlockPreserver();
  final preserved = preserver.preserveCodeBlocks(input);
  final parts = <String>[];
  for (final chunk in preserved.split('\n\n')) {
    final trimmed = chunk.trim();
    if (trimmed.isEmpty) continue;
    parts.add(
      containsHtmlTags(trimmed)
          ? _convertHtmlToJiraMarkup(trimmed)
          : _convertMarkdownToJiraMarkup(trimmed),
    );
  }
  final joined = preserver.restoreCodeBlocks(parts.join('\n\n'));
  return joined.trim();
}

/// Markdown branch: line walk with code-fence tracking and paragraph
/// accumulation (Java `convertMarkdownToJiraMarkdown`).
String _convertMarkdownToJiraMarkup(String markdown) {
  final blocks = <String>[];
  var inCodeBlock = false;
  final codeBuf = StringBuffer();
  var codeLang = '';
  final paragraph = StringBuffer();

  void flushParagraph() {
    if (paragraph.isNotEmpty) {
      blocks.add(_processTextParagraph(paragraph.toString()));
      paragraph.clear();
    }
  }

  for (final line in markdown.split('\n')) {
    final trimmedLine = line.trim();
    if (trimmedLine.startsWith('```')) {
      if (!inCodeBlock) {
        flushParagraph();
        inCodeBlock = true;
        codeLang = trimmedLine.substring(3).trim();
      } else {
        final code = codeBuf
            .toString()
            .replaceAll(RegExp(r'^\r?\n+'), '')
            .replaceAll(RegExp(r'\r?\n+$'), '');
        blocks.add('{code:${codeLang.isEmpty ? 'java' : codeLang}}$code{code}');
        inCodeBlock = false;
        codeBuf.clear();
        codeLang = '';
      }
      continue;
    }
    if (inCodeBlock) {
      codeBuf.writeln(line);
      continue;
    }
    final processed = _processImages(line);
    if (trimmedLine.isEmpty) {
      flushParagraph();
    } else {
      if (paragraph.isNotEmpty) paragraph.writeln();
      paragraph.write(processed);
    }
  }
  flushParagraph();
  return blocks.join('\n\n').trim();
}

/// `![name|attrs]` → `!name|attrs!` (Java `processImages`).
String _processImages(String text) => text.replaceAllMapped(
      RegExp(r'!\[(.*?)\|([^\]]+)\]'),
      (m) => '!${m.group(1)}|${m.group(2)}!',
    );

/// Per-paragraph Markdown inline conversion (Java `processTextParagraph`):
/// `1. **bold opener**` → `*bold opener*` bullets, `#`-headings, inline code,
/// bold, and links.
String _processTextParagraph(String text) {
  final output = <String>[];
  for (final line in _processImages(text).split('\n')) {
    var trimmed = _convertStrike(line.trim());
    trimmed = trimmed.replaceAllMapped(
      RegExp(r'^1\. \*\*(.*?)\*\*'),
      (m) => '*${m.group(1)}*',
    );
    final heading = RegExp(r'^(#{1,6})\s+(.+)$').firstMatch(trimmed);
    if (heading != null) {
      output.add('h${heading.group(1)!.length}. ${heading.group(2)}');
      continue;
    }
    trimmed = trimmed
        .replaceAllMapped(
          RegExp(r'`\s*([^`]+)\s*`'),
          (m) => '{{${m.group(1)}}}',
        )
        .replaceAllMapped(RegExp(r'\*\*([^*]+)\*\*'), (m) => '*${m.group(1)}*')
        .replaceAllMapped(
          RegExp(r'\[([^\]]+)\]\(([^)]+)\)'),
          (m) => '[${m.group(1)}|${m.group(2)}]',
        );
    output.add(trimmed);
  }
  return output.join('\n');
}

/// `~~gone~~` → Jira strike `-gone-` (dm.ai#676 parity). Only spans with a
/// non-space character at both ends convert. Code spans, `{{…}}`, `{code}`
/// blocks and URLs are masked with placeholders before the pass, so their
/// content is never rewritten. A URL token stops before trailing `~~`, so a
/// closing strike marker after a URL still pairs with its opener.
String _convertStrike(String s) {
  final saved = <String>[];
  final masked = s.replaceAllMapped(_strikeProtected, (m) {
    saved.add(m.group(0)!);
    return '\u0000${saved.length - 1}\u0000';
  });
  final converted = _applyStrike(masked);
  return converted.replaceAllMapped(
    RegExp('\u0000(\\d+)\u0000'),
    (m) => saved[int.parse(m.group(1)!)],
  );
}

final RegExp _strikeProtected = RegExp(
  r'`[^`]*`|\{\{.*?\}\}|\{code[^}]*\}.*?\{code\}|https?://\S*?(?=(?:~~)*(?:\s|$))',
  dotAll: true,
);

final RegExp _strikeSpan = RegExp(r'~~(?=\S)(.+?)(?<=\S)~~');

String _applyStrike(String segment) =>
    segment.replaceAllMapped(_strikeSpan, (m) => '-${m.group(1)}-');

/// Whether [tag] starts a new block in the HTML walker (Java `isBlockLevel`).
bool _isBlockLevel(String tag) => _blockLevelTags.contains(tag);

const _blockLevelTags = <String>{
  'ac:structured-macro',
  'p',
  'pre',
  'ul',
  'ol',
  'table',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'code',
  'strong',
  'em',
  'b',
  'i',
  'a',
};

/// HTML branch: enumerates the body's top-level nodes, accumulating inline
/// runs and flushing them as paragraphs between blocks (Java
/// `convertHtmlToJiraMarkdown`).
String _convertHtmlToJiraMarkup(String html) {
  final preserver = HtmlCodeBlockPreserver();
  final preserved = preserver.preserveCodeBlocks(html);
  final body = parse(preserved).body!;
  final nodes = body.nodes;

  final blocks = <String>[];
  final inlineBuffer = StringBuffer();

  void flushInline() {
    final raw = inlineBuffer.toString().trim();
    inlineBuffer.clear();
    if (raw.isEmpty) return;
    blocks.add(_processParagraph(parse(raw).body!));
  }

  var i = 0;
  while (i < nodes.length) {
    final node = nodes[i];
    if (node is dom.Element) {
      final tag = node.localName!.toLowerCase();
      if (_isBlockLevel(tag)) {
        flushInline();
        final special = _consecutiveInlineBlock(nodes, i, tag, node);
        if (special != null) {
          blocks.add(special.block);
          i = special.nextIndex + 1;
        } else {
          blocks.add(_handleBlockElement(node));
          i++;
        }
      } else {
        inlineBuffer.write(node.outerHtml);
        i++;
      }
    } else {
      inlineBuffer.write(_escapeTextNode(node.text ?? ''));
      i++;
    }
  }
  flushInline();

  final joined = blocks.where((b) => b.trim().isNotEmpty).join('\n\n').trim();
  return preserver.restoreCodeBlocks(_fixNewlineBeforeLink(joined));
}

/// Result of a special-cased top-level inline run (`<strong>+<ul>`, `<b>` /
/// `<i>` chains, top-level `<a>`).
typedef _SpecialBlock = ({String block, int nextIndex});

/// Handles the special top-level element runs the Java walker treats as
/// blocks: `<strong>` directly followed by `<ul>`, chains of sibling `<b>` /
/// `<i>` elements, and a top-level `<a>`. Returns `null` for the normal
/// block path. [nodes] is the body child list and [i] the current index of
/// [el] with [tag].
_SpecialBlock? _consecutiveInlineBlock(
  List<dom.Node> nodes,
  int i,
  String tag,
  dom.Element el,
) {
  if (tag == 'strong' &&
      i + 1 < nodes.length &&
      nodes[i + 1] is dom.Element &&
      (nodes[i + 1] as dom.Element).localName!.toLowerCase() == 'ul') {
    return _strongUlBlock(nodes, i, el);
  }
  if (tag == 'b' || tag == 'i') return _boldItalicChain(nodes, i, tag, el);
  if (tag == 'a') return _anchorBlock(i, el);
  return null;
}

/// `# *text*` heading + the `<ul>` that directly follows it
/// (Java's strong+list special case).
_SpecialBlock _strongUlBlock(List<dom.Node> nodes, int i, dom.Element el) {
  final heading = '# *${el.text.trim()}*';
  return (
    block: '$heading\n${_processUnorderedList(nodes[i + 1] as dom.Element)}',
    nextIndex: i + 1,
  );
}

/// Merges the run of sibling `<b>`/`<i>` elements starting at [i] into one
/// paragraph (Java's consecutive-inline chain).
_SpecialBlock _boldItalicChain(
  List<dom.Node> nodes,
  int i,
  String tag,
  dom.Element el,
) {
  final combined = StringBuffer(_trimLeadingSpaces(el.outerHtml));
  var j = i;
  while (j + 1 < nodes.length &&
      nodes[j + 1] is dom.Element &&
      (nodes[j + 1] as dom.Element).localName!.toLowerCase() == tag) {
    combined
      ..write(' ')
      ..write(_trimLeadingSpaces((nodes[j + 1] as dom.Element).outerHtml));
    j++;
  }
  return (
    block: _processParagraph(parse(combined.toString()).body!),
    nextIndex: j,
  );
}

/// A top-level `<a>` becomes a bare Jira link block.
_SpecialBlock _anchorBlock(int i, dom.Element el) =>
    (block: '[${el.text}|${el.attributes['href'] ?? ''}]', nextIndex: i);

/// Strips leading whitespace from every element's own text, destroying
/// nested markup in the process (Java `trimLeadingSpaces` — `Element.text()`
/// clears children).
String _trimLeadingSpaces(String html) {
  final body = parse(html).body!;
  for (final e in body.querySelectorAll('*')) {
    final own = e.nodes.whereType<dom.Text>().map((t) => t.text).join();
    if (own.isEmpty) continue;
    final cleaned = own.replaceFirst(RegExp(r'^\s+'), '');
    if (cleaned != own) {
      e
        ..nodes.clear()
        ..append(dom.Text(cleaned));
    }
  }
  return body.innerHtml;
}

/// Escapes a bare text node for re-parsing (Jsoup `TextNode.outerHtml`
/// round-trips the text entity-escaped).
String _escapeTextNode(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

/// Dispatches a block-level element to its Jira construct (Java
/// `handleBlockElement`).
String _handleBlockElement(dom.Element el) {
  final tag = el.localName!.toLowerCase();
  if (tag.startsWith('h') && tag.length == 2) {
    return 'h${tag[1]}. ${el.text}';
  }
  return (_blockElementHandlers[tag] ?? _processParagraph)(el);
}

/// Tag → Jira construct handler for [_handleBlockElement].
final _blockElementHandlers = <String, String Function(dom.Element)>{
  'pre': _processPre,
  'ul': _processUnorderedList,
  'ol': _processOrderedList,
  'table': _processTable,
  'code': _processCodeElement,
  'ac:structured-macro': _processCodeElement,
};

/// Strips the placeholder-wrapping `<code>` tags before re-insertion
/// (magic-constants gate: this literal recurs at every restoration site).
final RegExp codeTagPattern = RegExp(r'</?code[^>]*>', caseSensitive: false);

final RegExp _anchorTag = RegExp(r'<a\s+href="([^"]+)">(.*?)</a>');
final RegExp _strongTag = RegExp(
  r'<strong>(.*?)</strong>',
  caseSensitive: false,
);
final RegExp _emTag = RegExp(r'<em>(.*?)</em>', caseSensitive: false);
final RegExp _bTag = RegExp(r'<b>(.*?)</b>', caseSensitive: false);
final RegExp _iTag = RegExp(r'<i>(.*?)</i>', caseSensitive: false);
final RegExp _inlineCodeTag = RegExp(
  '<code>(?!\\$codeBlockPlaceholder\\d+)(.*?)</code>',
  caseSensitive: false,
);
final RegExp _anyTag = RegExp(r'<[^>]+>');

/// The shared inline replacement ladder for paragraph/list/table cells
/// (Java's repeated `pClone.html()` replacement chain): links, bold/italic,
/// `<br>` (context-specific [brPattern] → [brReplacement]), inline code,
/// then any residual tag strip.
String _inlineChain(
  String html, {
  required Pattern brPattern,
  required String brReplacement,
}) =>
    html
        .replaceAllMapped(_anchorTag, (m) => '[${m.group(2)}|${m.group(1)}]')
        .replaceAllMapped(_strongTag, (m) => '*${m.group(1)}*')
        .replaceAllMapped(_emTag, (m) => '_${m.group(1)}_')
        .replaceAllMapped(_bTag, (m) => '*${m.group(1)}*')
        .replaceAll(brPattern, brReplacement)
        .replaceAllMapped(_iTag, (m) => '_${m.group(1)}_')
        .replaceAllMapped(_inlineCodeTag, (m) => '{{${m.group(1)}}}')
        .replaceAll(_anyTag, '');

/// The shared inline replacement chain for paragraph/list/table cells
/// (Java's repeated `pClone.html()` replacement chain).
String _inlineMarkup(String html) => _inlineChain(
      html,
      brPattern: RegExp(r'<br\s*/?>', caseSensitive: false),
      brReplacement: '\n',
    );

/// Paragraph conversion: inline replacement chain over the element's inner
/// HTML, entity decode, trim (Java `processParagraph`).
String _processParagraph(dom.Element p) {
  final html = p.innerHtml;
  if (html.contains(codeBlockPlaceholder)) {
    return html.replaceAll(codeTagPattern, '');
  }
  final text = _inlineMarkup(html);
  return _fixNewlineBeforeLink(decodeHtmlEntities(text).trim());
}

/// `<code>` element: inline when single-line, `{code:lang}` block when
/// multi-line (Java `processCodeElement`).
String _processCodeElement(dom.Element codeEl) {
  if (codeEl.outerHtml.contains(codeBlockPlaceholder)) {
    return codeEl.outerHtml.replaceAll(codeTagPattern, '');
  }
  final codeText = _decodedCodeText(codeEl);
  final lang = _codeLanguage(codeEl);
  if (codeText.contains('\n')) {
    return '\n${_codeBlock(lang, codeText)}\n';
  }
  return '{{$codeText}}';
}

/// `<pre>` element: `<code>` child becomes a `{code:lang}` block; otherwise
/// the plain text (Java `processPre`).
String _processPre(dom.Element pre) {
  final codeEl = pre.querySelector('code');
  if (codeEl != null) {
    if (codeEl.innerHtml.contains(codeBlockPlaceholder)) {
      return codeEl.innerHtml.replaceAll(codeTagPattern, '');
    }
    final codeText = _decodedCodeText(codeEl);
    return _codeBlock(_codeLanguage(codeEl), codeText);
  }
  return decodeHtmlEntities(pre.text);
}

/// Entity-decoded code text with leading/trailing blank lines stripped
/// (the shared body of the two code-block processors).
String _decodedCodeText(dom.Element codeEl) =>
    decodeHtmlEntities(codeEl.innerHtml)
        .replaceAll(RegExp(r'^\r?\n+'), '')
        .replaceAll(RegExp(r'\r?\n+$'), '');

/// The `class`-attribute language of [codeEl], defaulting to `java`
/// (Java `mapLanguage` default).
String _codeLanguage(dom.Element codeEl) {
  final lang = codeEl.attributes['class']?.trim();
  return lang == null || lang.isEmpty ? 'java' : lang;
}

/// A `{code:lang}…{code}` block around [text].
String _codeBlock(String lang, String text) => '{code:$lang}\n$text\n{code}';

/// `<ul>` → `* item` lines with nested-list recursion (Java
/// `processUnorderedList`).
String _processUnorderedList(dom.Element ul) {
  final sb = StringBuffer();
  for (final li in ul.children.where((c) => c.localName == 'li')) {
    sb.writeln('* ${_listItemText(li)}');
    _appendNestedLists(sb, li);
  }
  return sb.toString().trim();
}

/// `<ol>` → `# item` lines; a direct `<strong>+<ul>` pair becomes a
/// `# *heading*` + bullets block (Java `processOrderedList`).
String _processOrderedList(dom.Element ol) {
  final sb = StringBuffer();
  for (final li in ol.children.where((c) => c.localName == 'li')) {
    final strongEl = li.children.where((c) => c.localName == 'strong');
    final nestedUl = li.children.where((c) => c.localName == 'ul');
    if (strongEl.isNotEmpty && nestedUl.isNotEmpty) {
      sb
        ..writeln('# *${strongEl.first.text.trim()}*')
        ..writeln(_processUnorderedList(nestedUl.first));
      continue;
    }
    if (li.innerHtml.contains(codeBlockPlaceholder)) {
      sb.writeln(li.innerHtml.replaceAll(codeTagPattern, ''));
      continue;
    }
    sb.writeln('# ${_listItemText(li)}');
    _appendNestedLists(sb, li);
  }
  return sb.toString().trim();
}

/// The inline-converted text of one `<li>` with nested lists stripped (the
/// shared middle of the two list processors).
String _listItemText(dom.Element li) {
  final clone = li.clone(true);
  clone.querySelectorAll('ul,ol').forEach((e) => e.remove());
  final raw = clone.innerHtml.replaceAll(codeTagPattern, '');
  return decodeHtmlEntities(_listInlineMarkup(raw)).trim();
}

/// List-item inline chain — like [_inlineMarkup] but `<br>` also swallows
/// trailing whitespace (Java list variant).
String _listInlineMarkup(String html) => _inlineChain(
      html,
      brPattern: RegExp(r'<br\s*/?>\s*', caseSensitive: false),
      brReplacement: '\n',
    );

/// Appends nested `<ul>`/`<ol>` children of [li] to [sb] (Java's recursion
/// tail in both list processors).
void _appendNestedLists(StringBuffer sb, dom.Element li) {
  for (final child in li.children) {
    final tag = child.localName?.toLowerCase();
    if (tag == 'ul') {
      sb.writeln(_processUnorderedList(child));
    } else if (tag == 'ol') {
      sb.writeln(_processOrderedList(child));
    }
  }
}

/// `<table>` → Jira table markup: `||header||` rows first, then `|cell|`
/// rows; `<br>` inside a cell becomes a literal `\\` line continuation
/// (Java `processTable`).
String _processTable(dom.Element table) {
  final sb = StringBuffer();
  var headerDone = false;
  for (final row in table.querySelectorAll('tr')) {
    final cells = row.querySelectorAll('th,td');
    if (cells.isEmpty) continue;
    if (!headerDone && row.querySelectorAll('th').isNotEmpty) {
      _writeHeaderRow(sb, cells);
      headerDone = true;
    } else {
      _writeBodyRow(sb, cells);
    }
  }
  return sb.toString().trim();
}

/// Writes one `||header||` row (Java `processTable` header branch).
void _writeHeaderRow(StringBuffer sb, List<dom.Element> cells) {
  sb.write('||');
  for (final th in cells) {
    final trimmed = th.text.trim();
    sb
      ..write(decodeHtmlEntities(trimmed.isEmpty ? ' ' : trimmed))
      ..write('||');
    for (var i = 1; i < _colspan(th); i++) {
      sb.write(' ||');
    }
  }
  sb.writeln();
}

/// Writes one `|cell|` body row; placeholder-wrapped cells are restored
/// verbatim, others run through the cell inline chain.
void _writeBodyRow(StringBuffer sb, List<dom.Element> cells) {
  sb.write('|');
  for (final cell in cells) {
    if (cell.innerHtml.contains(codeBlockPlaceholder)) {
      sb
        ..write(cell.innerHtml.replaceAll(codeTagPattern, ''))
        ..write('|');
    } else {
      final cellText = _tableCellMarkup(cell.innerHtml);
      final trimmed = cellText.trim().replaceAll('|', '/');
      sb
        ..write(decodeHtmlEntities(trimmed.isEmpty ? ' ' : trimmed))
        ..write('|');
    }
    for (var i = 1; i < _colspan(cell); i++) {
      sb.write(' |');
    }
  }
  sb.writeln();
}

/// Table-cell inline chain — `<br>` becomes newline + two literal
/// backslashes (the Jira table line break, Java `processTable` cell chain).
String _tableCellMarkup(String html) => _inlineChain(
      html,
      brPattern: RegExp(r'<br\s*/?>', caseSensitive: false),
      brReplacement: '\n\\\\',
    );

/// Numeric `colspan` attribute of [cell], `1` when absent or unparseable.
int _colspan(dom.Element cell) =>
    int.tryParse(cell.attributes['colspan'] ?? '') ?? 1;

/// Java `fixNewlineBeforeLink` — the three literal regex passes from the
/// original, ported unchanged (two of them are effectively no-ops but keep
/// byte-parity with the Java output).
String _fixNewlineBeforeLink(String text) => text
    .replaceAllMapped(
      RegExp(r'(\S)\n\[(https?://)'),
      (m) => '${m.group(1)}\n[${m.group(2)}',
    )
    .replaceAll(RegExp(r'\n\[\n(https?://)'), '\n[https://')
    .replaceAll(RegExp(r'\n\[https?://'), '\n[https://');

/// Preserves `<code>…</code>` spans across HTML parsing/conversion by
/// swapping them for indexed placeholders (Dart port of the Java
/// `HTMLCodeBlockPreserver`).
class HtmlCodeBlockPreserver {
  static final _codePattern = RegExp(r'<code[^>]*>(.*?)</code>', dotAll: true);
  static final _classPattern = RegExp("class=[\"']([^\"']*)[\"']");

  final List<({String content, String language, bool isInline})>
      _preservedCodeBlocks = [];

  /// Swaps every `<code>` span for a placeholder element; spans already
  /// carrying a placeholder are left alone.
  String preserveCodeBlocks(String html) =>
      html.replaceAllMapped(_codePattern, (match) {
        final fullMatch = match.group(0)!;
        final codeContent = match.group(1)!;
        if (codeContent.contains(codeBlockPlaceholder)) return fullMatch;
        final classMatch = _classPattern.firstMatch(fullMatch);
        final language = classMatch?.group(1) ?? 'java';
        final isInline =
            !fullMatch.contains('class=') && !codeContent.contains('\n');
        _preservedCodeBlocks.add((
          content: codeContent,
          language: language,
          isInline: isInline,
        ));
        return '<code>$codeBlockPlaceholder${_preservedCodeBlocks.length - 1}'
            '</code>';
      });

  /// Swaps each placeholder back for its Jira construct: `{{inline}}` for
  /// single-line spans, `{code:lang}…{code}` blocks otherwise (`properties`
  /// maps to `bash` like the Java `mapLanguage`).
  String restoreCodeBlocks(String processedHtml) {
    var result = processedHtml;
    for (var i = 0; i < _preservedCodeBlocks.length; i++) {
      final block = _preservedCodeBlocks[i];
      final lines = block.content.split(RegExp(r'\r?\n'));
      final normalized = lines
          .where((line) => line.isNotEmpty)
          .join('\n')
          .replaceAll(RegExp(r'[\r\n]+$'), '');
      final text = decodeHtmlEntities(normalized);
      final replacement = block.isInline
          ? '{{${text.trim()}}}'
          : '{code:${_mapLanguage(block.language)}}$text{code}';
      result = result.replaceAll('$codeBlockPlaceholder$i', replacement);
    }
    return result;
  }

  static String _mapLanguage(String language) =>
      language.equalsIgnoreCase('properties') ? 'bash' : language;
}

/// Case-insensitive comparison helper local to this library.
extension on String {
  bool equalsIgnoreCase(String other) => toLowerCase() == other.toLowerCase();
}
