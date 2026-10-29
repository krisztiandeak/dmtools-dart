/// Version information for the Dart port of DMTools.
///
/// The CLI `--version` output must stay compatible with the Java
/// distribution format (`dmtools <version>`).
library;

/// Current package version, mirroring `pubspec.yaml`.
const String dmtoolsVersion = '0.1.81';

/// Returns the version line printed by `dmtools --version`.
String versionLine() => 'dmtools $dmtoolsVersion';
