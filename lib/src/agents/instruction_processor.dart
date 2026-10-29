/// Processes CLI prompt strings by extracting and embedding content from
/// URLs and file paths found in the text.
///
/// Ports Java `InstructionProcessor` (`teammate/InstructionProcessor.java`).
/// The Java version checks whether an *entire* prompt entry is a URL or file
/// path; this Dart port scans *within* the prompt text so that references
/// embedded in a larger instruction are also enriched.
///
/// Detected references:
/// - **File paths** (`./file.md`, `../dir/file.txt`, `/abs/file.json`) —
///   file content is read synchronously and embedded inline.
/// - **GitHub PR URLs** (`https://github.com/{owner}/{repo}/pull/{num}`) —
///   annotated with structured metadata (content not fetched in this phase).
/// - **Jira ticket keys** (`PROJ-123`) — annotated (content not fetched).
/// - **Other URLs** — left unchanged.
library;

import 'dart:io';

/// Matches relative or absolute file paths with known extensions.
///
/// Path segments may contain dots (`/home/runner/.dmtools/packs/
/// story_development-0.1.18/...md`) — pack paths on runners always do —
/// so the charset includes `.` between separators. The extension anchor
/// stays pinned to the known list, and the leading boundary (`/`, `./`,
/// `../`) keeps ordinary prose with dots out.
final RegExp _filePathRegExp = RegExp(
  r'(?<![:/\w])\.{0,2}/[\w./-]+\.(?:md|txt|json|yaml|yml)\b',
);

/// Matches GitHub pull-request URLs (captures owner, repo, number).
final RegExp _githubPrRegExp = RegExp(
  r'https://github\.com/([\w.-]+)/([\w.-]+)/pull/(\d+)',
);

/// Matches Jira ticket keys such as `PROJ-123`.
final RegExp _jiraKeyRegExp = RegExp(
  r'\b[A-Z][A-Z0-9]+-\d+\b',
);

/// Processes CLI prompt strings by extracting and embedding content from
/// URLs and file paths found in the text.
class InstructionProcessor {
  /// Creates a processor that resolves relative file paths against
  /// [workingDirectory] (defaults to the current working directory).
  InstructionProcessor({this.workingDirectory});

  /// Base directory for resolving relative file paths embedded in prompts.
  final String? workingDirectory;

  /// Processes [prompt], returning the enriched version.
  ///
  /// Processing order: file paths → GitHub PR URLs → Jira keys.
  String process(String prompt) {
    var result = prompt;
    result = _embedFilePaths(result);
    result = _embedUrls(result);
    result = _embedJiraKeys(result);
    return result;
  }

  /// Replaces each detected file path in [text] with its embedded content.
  ///
  /// Non-existent or unreadable files are left unchanged.
  String _embedFilePaths(String text) {
    return text.replaceAllMapped(_filePathRegExp, (match) {
      final path = match.group(0)!;
      final resolved = _resolveFilePath(path);
      final file = File(resolved);
      if (!file.existsSync()) return path;
      try {
        // Minimal basename header, not a <file path="..."> wrapper: pack
        // configs inline up to a dozen instruction files and the absolute
        // runner path (~110 chars each) is pure prompt-token bloat (the
        // Java InstructionProcessor inlines bare content; cross-file
        // references like "see tdd_approach.md" only need the basename).
        final basename = path.replaceAll('\\', '/').split('/').last;
        return '## $basename\n${file.readAsStringSync()}';
      } catch (_) {
        return path;
      }
    });
  }

  /// Annotates GitHub PR URLs in [text] with structured metadata.
  ///
  /// Each `https://github.com/{owner}/{repo}/pull/{number}` URL gets a
  /// `[github-pr:owner/repo#number]` suffix so downstream consumers know
  /// the reference type without a network fetch. Other URLs are left as-is.
  String _embedUrls(String text) {
    return text.replaceAllMapped(_githubPrRegExp, (match) {
      final owner = match.group(1)!;
      final repo = match.group(2)!;
      final number = match.group(3)!;
      return '${match.group(0)!} [github-pr:$owner/$repo#$number]';
    });
  }

  /// Annotates Jira ticket keys in [text].
  ///
  /// Each `PROJ-123` style key gets a `[jira-ticket]` suffix.
  String _embedJiraKeys(String text) {
    return text.replaceAllMapped(
      _jiraKeyRegExp,
      (match) => '${match.group(0)!} [jira-ticket]',
    );
  }

  /// Resolves a relative or absolute file path.
  ///
  /// Absolute paths (starting with `/`) are returned unchanged. Relative
  /// paths are resolved against [workingDirectory] (or the current
  /// directory when null), with `.` and `..` segments normalized.
  String _resolveFilePath(String input) {
    if (input.startsWith('/')) return input;
    final base = workingDirectory ?? Directory.current.absolute.path;
    final segments = [...base.split('/'), ...input.split('/')];
    final stack = <String>[];
    for (final seg in segments) {
      if (seg.isEmpty || seg == '.') continue;
      if (seg == '..') {
        if (stack.isNotEmpty) stack.removeLast();
      } else {
        stack.add(seg);
      }
    }
    return '/${stack.join('/')}';
  }
}
