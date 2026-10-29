/// Provenance of an installed agent pack (gh-375): which zip the cached
/// directory was unpacked from. Two releases can share a pack version with
/// different content, so the cache is keyed on the zip's SHA-256 and the
/// source URL (which carries the registry base), not on name+version alone.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// File name written at the root of every unpacked pack directory.
const String packProvenanceFileName = '.provenance.json';

/// Substrings of the JS runtime's missing-`require` errors. The provenance
/// line is printed only for these; keep them in sync with `require_loader.dart`
/// and `job_runner.dart`, which throw them.
const String packMissingModuleMarker = 'Failed to require module';

/// The job-runner error substring for a missing entry script — the second
/// provenance-log trigger beside [packMissingModuleMarker].
const String packMissingFileMarker = 'JavaScript file not found';

/// Identity of the zip an unpacked pack directory came from.
class PackProvenance {
  /// Creates a provenance record.
  const PackProvenance({
    required this.name,
    required this.version,
    required this.sha256,
    required this.sourceUrl,
  });

  /// Decodes a record written by [toJson]; `null` when malformed.
  static PackProvenance? fromJson(Object? json) {
    if (json is! Map) return null;
    final name = json['name'];
    final version = json['version'];
    final sha = json['sha256'];
    final source = json['sourceUrl'];
    if (name is! String ||
        version is! String ||
        sha is! String ||
        source is! String) {
      return null;
    }
    return PackProvenance(
        name: name, version: version, sha256: sha, sourceUrl: source);
  }

  /// Agent name from the manifest.
  final String name;

  /// Pack version from the manifest.
  final String version;

  /// Lower-case hex SHA-256 of the zip the pack was unpacked from.
  final String sha256;

  /// Download URL, local zip path, or registry-resolved URL of the zip.
  final String sourceUrl;

  /// JSON map persisted as [packProvenanceFileName].
  Map<String, String> toJson() => {
        'name': name,
        'version': version,
        'sha256': sha256,
        'sourceUrl': sourceUrl,
      };

  /// True when [other] describes the same zip content from the same source.
  bool matches(PackProvenance? other) =>
      other != null &&
      other.name == name &&
      other.version == version &&
      other.sha256 == sha256 &&
      other.sourceUrl == sourceUrl;

  /// One actionable log line naming the pack, version, sha and source.
  String describe() =>
      'pack provenance: name=$name version=$version sha256=$sha256 '
      'source=$sourceUrl';

  /// Reads the provenance record stored under [packRoot]; `null` when absent
  /// or unreadable (treated as a cache miss by the resolver).
  static PackProvenance? read(Directory packRoot) {
    final file = File(p.join(packRoot.path, packProvenanceFileName));
    if (!file.existsSync()) return null;
    try {
      return fromJson(jsonDecode(file.readAsStringSync()));
    } on FormatException {
      return null;
    }
  }

  /// Writes this record under [packRoot].
  void write(Directory packRoot) {
    File(p.join(packRoot.path, packProvenanceFileName))
        .writeAsStringSync(jsonEncode(toJson()));
  }
}

/// Strips `./` and `agents/` prefixes from [raw] and maps bare `.js` filenames
/// (such as `thenAction: "assignForSolutionArchitecture.js"`) to `js/<name>`
/// unless `<rootPath>/<name>` exists directly at the root (legacy root-level
/// scripts like `agents/restoreDescription.js`).
String normalizePackReferencePath(String raw, {String? rootPath}) {
  var ref = raw.trim();
  while (ref.startsWith('./')) {
    ref = ref.substring(2);
  }
  if (ref.startsWith('agents/')) {
    ref = ref.substring('agents/'.length);
  }
  if (!ref.contains('/') && ref.endsWith('.js')) {
    if (rootPath != null && File(p.join(rootPath, ref)).existsSync()) {
      return ref;
    }
    return 'js/$ref';
  }
  return ref;
}
