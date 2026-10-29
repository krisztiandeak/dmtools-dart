/// Unit tests for `markdownToJiraMarkup` (gh-191, P6-JSY-09) — the Dart port
/// of the Java `MarkdownToJiraConverter.convertToJiraMarkdown` that
/// `JiraClient.postComment` runs on Markdown comment bodies.
///
/// The Markdown-path cases are ported 1:1 from the Java
/// `MarkdownToJiraConverterTest`; the HTML/mixed cases cover every block
/// construct the HTML walker handles (headings, paragraphs, lists, tables,
/// code, links, images, entities).
library;

import 'package:dmtools/src/integrations/jira/markdown_to_jira_markup.dart';
import 'package:test/test.dart';

void main() {
  _strikeTests();
  edgeCaseTests();
  markdownBranchTests();
  markdownCodeBlockTests();
  htmlBranchTests();
  htmlInlineAndEntityTests();
  topLevelInlineRunTests();
  mixedBranchTests();
  preserverTests();
}

void edgeCaseTests() {
  group('markdownToJiraMarkup: edge cases (Java testEdgeCases)', () {
    test('empty input yields empty string', () {
      expect(markdownToJiraMarkup(''), '');
    });

    test('whitespace-only input yields empty string', () {
      expect(markdownToJiraMarkup('  \n  \t  '), '');
    });

    test('pure HTML entities are decoded', () {
      expect(markdownToJiraMarkup('&lt; &gt; &amp; &quot;'), '< > & "');
    });
  });
}

void markdownBranchTests() {
  group('markdownToJiraMarkup: markdown branch', () {
    test('markdown input (Java testMarkdownInput)', () {
      const markdown = 'This is **bold** and _italic_\n\n'
          '```java\npublic class Test {}\n```';
      expect(
        markdownToJiraMarkup(markdown),
        'This is *bold* and _italic_\n\n{code:java}public class Test {}{code}',
      );
    });

    test('complex markdown input (Java testComplexMarkdownInput)', () {
      const markdown = '# Title\n\n'
          '**Bold text** and _italic text_\n\n'
          '```java\npublic class Test {}\n```\n\n'
          '* Item 1\n* Item 2\n\n'
          '[Link](http://example.com)\n\n'
          '`inline code`';
      expect(
        markdownToJiraMarkup(markdown),
        'h1. Title\n\n'
        '*Bold text* and _italic text_\n\n'
        '{code:java}public class Test {}{code}\n\n'
        '* Item 1\n* Item 2\n\n'
        '[Link|http://example.com]\n\n'
        '{{inline code}}',
      );
    });

    test('complex markdown input 2 (Java testComplexMarkdownInput2)', () {
      const markdown = '1. **Step one**\n'
          '2. Do the thing\n'
          '\n'
          '```dart\nfinal x = 1;\n```\n'
          '\n'
          'See [the docs](https://example.com/docs) for `details`.';
      expect(
        markdownToJiraMarkup(markdown),
        '*Step one*\n2. Do the thing\n\n'
        '{code:dart}final x = 1;{code}\n\n'
        'See [the docs|https://example.com/docs] for {{details}}.',
      );
    });
  });
}

void markdownCodeBlockTests() {
  group('markdownToJiraMarkup: markdown branch', () {
    test('code blocks conversion (Java testCodeBlocksConversion)', () {
      const input = "Here's how to implement a feature:\n"
          '\n'
          '1. Update `src/auth.ts`:\n'
          '\n'
          '<code class="typescript">\n'
          "import { auth } from './auth';\n"
          '</code>\n';
      // Java ground truth (Probe run against the real converter): the
      // input carries no `#` / ``` / `* ` markers, so the whole body takes
      // the HTML branch and the single-backtick span is preserved verbatim
      // -- only the <code> element becomes a {code} block. Adjacent text
      // runs keep their newline here where Jsoup pretty-print collapses it
      // to a single space (documented whitespace deviation).
      expect(
        markdownToJiraMarkup(input),
        "Here's how to implement a feature:\n"
        '\n'
        '1. Update `src/auth.ts`:\n'
        '\n'
        "{code:typescript}import { auth } from './auth';{code}",
      );
    });

    test('multi-item list stays a list (2+ items)', () {
      expect(
        markdownToJiraMarkup('* First\n* Second\n* Third'),
        '* First\n* Second\n* Third',
      );
    });
  });
}

void htmlBranchTests() {
  group('markdownToJiraMarkup: HTML branch', () {
    test('html input (Java testHtmlInput)', () {
      const html = '<p>This is <strong>bold</strong> and <em>italic</em></p>'
          '<pre><code class="java">public class Test {}</code></pre>';
      expect(
        markdownToJiraMarkup(html),
        'This is *bold* and _italic_\n\n{code:java}public class Test {}{code}',
      );
    });

    test('complex html input (Java testComplexHtmlInput)', () {
      const input = '<h1>Title</h1><p><strong>Bold text</strong> and '
          '<em>italic text</em></p>'
          '<pre><code class="java">public class Test {}</code></pre>'
          '<ul><li>Item 1</li><li>Item 2</li></ul>'
          '<a href="http://example.com">Link</a>'
          '<code>inline code</code>';
      expect(
        markdownToJiraMarkup(input),
        'h1. Title\n\n'
        '*Bold text* and _italic text_\n\n'
        '{code:java}public class Test {}{code}\n\n'
        '* Item 1\n* Item 2\n\n'
        '[Link|http://example.com]\n\n'
        '{{inline code}}',
      );
    });

    test('nested unordered list', () {
      const html = '<ul><li>Parent<ul><li>Child</li></ul></li></ul>';
      expect(markdownToJiraMarkup(html), '* Parent\n* Child');
    });

    test('ordered list with strong+ul pair', () {
      const html = '<ol><li><strong>Given</strong><ul><li>a page</li></ul>'
          '</li><li>plain item</li></ol>';
      expect(markdownToJiraMarkup(html), '# *Given*\n* a page\n# plain item');
    });

    test('table with header, line break, and emphasis', () {
      const html = '<table><tr><th>Name</th><th>Value</th></tr>'
          '<tr><td><strong>event.name</strong></td>'
          '<td>trackEvent("x")<br>second line</td></tr></table>';
      expect(
        markdownToJiraMarkup(html),
        '||Name||Value||\n'
        '|*event.name*|trackEvent("x")\n'
        '\\\\second line|',
      );
    });
  });
}

void htmlInlineAndEntityTests() {
  group('markdownToJiraMarkup: HTML branch', () {
    test('multi-line code element becomes a block', () {
      const html = '<p>before</p><code class="kotlin">\nval x = 1\n'
          'val y = 2\n</code>';
      expect(
        markdownToJiraMarkup(html),
        'before\n\n{code:kotlin}val x = 1\nval y = 2{code}',
      );
    });

    test('greeting line breaks inside a paragraph', () {
      const html = '<p><strong>Given</strong> a page<br>'
          '<strong>When</strong> the user clicks</p>';
      expect(
        markdownToJiraMarkup(html),
        '*Given* a page\n*When* the user clicks',
      );
    });

    test('entities inside html are decoded', () {
      expect(
        markdownToJiraMarkup('<p>fish &amp; chips &lt;3</p>'),
        'fish & chips <3',
      );
    });

    test('markdown image syntax converts', () {
      // Java ground truth: only the ![name|attrs] part is rewritten; the
      // trailing (url) stays (Java `processImages` regex does not cover it).
      expect(
        markdownToJiraMarkup('![Screenshot|width=300](img.png)'),
        '!Screenshot|width=300!(img.png)',
      );
    });
  });
}

/// The Java walker's special top-level inline runs (Java
/// `convertHtmlToJiraMarkdown` special cases): sibling `<b>`/`<i>` chains,
/// `<strong>`+`<ul>` heading pairs, and whitespace-trimmed chain members.
void topLevelInlineRunTests() {
  group('markdownToJiraMarkup: HTML top-level inline runs', () {
    test('sibling <b> chain merges into one paragraph (2+ items)', () {
      const html = '<b>First</b><b>Second</b>';
      expect(markdownToJiraMarkup(html), '*First* *Second*');
    });

    test('sibling <i> chain with leading whitespace trims members', () {
      const html = '<i> First</i><i>Second</i>';
      expect(markdownToJiraMarkup(html), '_First_ _Second_');
    });

    test('top-level <a> keeps the sibling that follows it', () {
      const html = '<a href="u">L</a> tail <b>z</b>';
      expect(markdownToJiraMarkup(html), contains('tail'));
      expect(markdownToJiraMarkup(html), contains('*z*'));
    });

    test('top-level <strong>+<ul> becomes a heading + bullets block', () {
      const html = '<strong>Given</strong><ul><li>a page</li></ul>';
      expect(markdownToJiraMarkup(html), '# *Given*\n* a page');
    });

    test('multi-line <code> restores as a {code:java} block', () {
      const html = '<code>line1\nline2</code>';
      expect(markdownToJiraMarkup(html), '{code:java}line1\nline2{code}');
    });

    test('<pre><code> keeps an explicit language class', () {
      const html = '<pre><code class="python">x = 1</code></pre>';
      expect(markdownToJiraMarkup(html), '{code:python}x = 1{code}');
    });

    test('unclosed <code> without a class reaches the DOM code path', () {
      // The preserver's regex needs a closing </code>; an unclosed span
      // survives to the DOM walker, whose default language is java.
      expect(markdownToJiraMarkup('<code>x = 1'), '{{x = 1}}');
      expect(markdownToJiraMarkup('<code class="">y = 2'), '{{y = 2}}');
      expect(markdownToJiraMarkup('<code class="python">z = 3'), '{{z = 3}}');
    });

    test('unclosed <code> in a <pre> uses the class language', () {
      expect(
        markdownToJiraMarkup('<pre><code class="python">x = 1</pre>'),
        '{code:python}\nx = 1\n{code}',
      );
    });
  });
}

void mixedBranchTests() {
  group('markdownToJiraMarkup: mixed branch', () {
    test('mixed input (Java testMixedInput)', () {
      const input = '# Heading\n\n<p>This is <strong>bold</strong></p>'
          '\n\n* List item\n\n```java\ncode\n```';
      expect(
        markdownToJiraMarkup(input),
        'h1. Heading\n\n'
        'This is *bold*\n\n'
        '* List item\n\n'
        '{code:java}code{code}',
      );
    });

    test('html chunk without markdown markers routes to the html branch', () {
      const input = 'plain paragraph\n\n<p><em>emph</em></p>';
      expect(markdownToJiraMarkup(input), 'plain paragraph\n\n_emph_');
    });
  });
}

void preserverTests() {
  group('HtmlCodeBlockPreserver', () {
    test('placeholder survives a preserve/restore round trip', () {
      // Java parity: restoreCodeBlocks only substitutes the placeholder
      // text — the surrounding <code> element stays (it is stripped later
      // by the real conversion chain's tag pass, not by the preserver).
      final preserver = HtmlCodeBlockPreserver();
      final preserved = preserver.preserveCodeBlocks(
        '<p>a <code class="java">x = 1;</code> b</p>',
      );
      expect(preserved, contains(codeBlockPlaceholder));
      final restored = preserver.restoreCodeBlocks(preserved);
      expect(restored, '<p>a <code>{code:java}x = 1;{code}</code> b</p>');
    });

    test('inline code without class becomes {{monospace}}', () {
      final preserver = HtmlCodeBlockPreserver();
      final preserved = preserver.preserveCodeBlocks(
        '<p>a <code>x</code> b</p>',
      );
      expect(
        preserver.restoreCodeBlocks(preserved),
        '<p>a <code>{{x}}</code> b</p>',
      );
    });

    test('properties language maps to bash', () {
      final preserver = HtmlCodeBlockPreserver();
      final preserved = preserver.preserveCodeBlocks(
        '<code class="properties">a=b\nc=d</code>',
      );
      expect(
        preserver.restoreCodeBlocks(preserved),
        '<code>{code:bash}a=b\nc=d{code}</code>',
      );
    });

    test('decodeHtmlEntities normalizes newlines and decodes basics', () {
      expect(decodeHtmlEntities('&lt;x&gt;&amp;\r\nnext'), '<x>&\nnext');
    });
  });
}

void _strikeTests() {
  group('markdownToJiraMarkup: strikethrough (gh-377 / dm.ai#676)', () {
    test('~~x~~ becomes Jira -x-', () {
      expect(
        markdownToJiraMarkup('this is ~~gone~~ now'),
        'this is -gone- now',
      );
    });
    test('space at either end keeps the markers', () {
      expect(markdownToJiraMarkup('a ~~ b ~~ c'), 'a ~~ b ~~ c');
    });
    test('code span content is not converted', () {
      expect(markdownToJiraMarkup('use `~~x~~` here'), 'use {{~~x~~}} here');
    });
    test('URL content is not converted', () {
      expect(
        markdownToJiraMarkup('see https://x.io/~~a~~ now'),
        'see https://x.io/~~a~~ now',
      );
    });
    test('strike wrapping a URL converts both markers', () {
      expect(markdownToJiraMarkup('~~https://x.io~~'), '-https://x.io-');
    });
    test('hyphenated words and ranges are untouched', () {
      expect(markdownToJiraMarkup('a-b-c and 1-2'), 'a-b-c and 1-2');
    });
  });
}
