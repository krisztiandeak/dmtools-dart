import 'dart:io';

import 'package:dmtools/src/config/property_names.dart';
import 'package:test/test.dart';

/// Drift guard: every config name the reader resolves must be declared in
/// [PropertyNames], so the JS `env_get` allowlist cannot miss a property.
void main() {
  test('PropertyNames.all lists each constant exactly once', () {
    expect(PropertyNames.all.toSet().length, PropertyNames.all.length);
    expect(PropertyNames.all, isNotEmpty);
  });

  test('reader sources use no bare config-name literal', () {
    final literal = RegExp(r"'([A-Z][A-Z0-9_]{2,})'");
    final declared = PropertyNames.all.toSet();
    final offenders = <String>[];
    for (final path in [
      'lib/src/config/property_reader_getters.dart',
      'lib/src/config/property_reader_ai_getters.dart',
    ]) {
      final src = File(path).readAsLinesSync();
      for (var i = 0; i < src.length; i++) {
        final line = src[i];
        if (line.trimLeft().startsWith('//')) continue;
        for (final m in literal.allMatches(line)) {
          if (declared.contains(m.group(1))) {
            offenders.add('$path:${i + 1} ${m.group(1)}');
          }
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: 'use PropertyNames.* instead of string literals',
    );
  });
}
