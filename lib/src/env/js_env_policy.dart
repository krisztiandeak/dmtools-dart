/// Single source of truth for WHICH configuration values a JS agent may read.
///
/// Dart port of Java `com.github.istin.dmtools.env.JsEnvPolicy` (dm.ai#710),
/// the spec for the `env_get` / `env_list` tools. Rules, in order:
///
/// 1. A name that looks like a secret is NEVER readable, whatever any
///    allowlist says (whole `_`-separated word match; `*_MAX_TOKENS` and
///    `*_TOKEN_LIMIT` stay readable).
/// 2. The default allowlist is every name the reader declares
///    ([PropertyNames.all]) minus the secrets.
/// 3. `JS_ENV_ALLOWLIST=A,B` extends it; secret-looking entries are dropped.
library;

import '../config/property_names.dart';

/// Outcome of [JsEnvPolicy.decide].
enum EnvDecision {
  /// Readable through `env_get`.
  allowed,

  /// Looks like a credential: never readable.
  secret,

  /// Well-formed, but neither built in nor added via `JS_ENV_ALLOWLIST`.
  notAllowlisted,

  /// Not a `[A-Za-z][A-Za-z0-9_]*` name; rejected without a lookup.
  invalidName,
}

/// Static policy functions (Java `JsEnvPolicy` parity).
class JsEnvPolicy {
  JsEnvPolicy._();

  /// Name of the variable that extends the allowlist (itself readable).
  static const String allowlistKey = 'JS_ENV_ALLOWLIST';

  /// Words that mark a `_`-separated name as a credential (Java `SECRET_WORDS`).
  static const Set<String> _secretWords = {
    'TOKEN', 'TOKENS', 'PAT', 'KEY', 'KEYS', 'SECRET', 'SECRETS', //
    'PASSWORD', 'PASSWORDS', 'PASSWD', 'PASS', 'CREDENTIAL', 'CREDENTIALS',
    'AUTH', 'AUTHORIZATION', 'LOGIN', 'PRIVATE', 'CERT', 'CERTIFICATE',
    'SIGNATURE', 'COOKIE', 'COOKIES', 'SESSION', 'BEARER', 'PASSPHRASE',
    'APIKEY',
  };

  static final RegExp _validName = RegExp(r'^[A-Za-z][A-Za-z0-9_]*$');
  static final RegExp _upperName = RegExp(r'^[A-Z][A-Z0-9_]*$');
  static final RegExp _separators = RegExp(r'[,\s]+');

  /// True when [name] looks like a secret. A null or blank name fails closed.
  static bool looksSecret(String? name) {
    if (name == null || name.trim().isEmpty) return true;
    final words = name.trim().toUpperCase().split('_');
    if (_isTokenLimitOrCount(words)) return false;
    return words.any(_isSecretWord);
  }

  /// Only the exact limit shapes are configuration: `*_MAX_TOKENS` (last
  /// word `TOKENS`, preceded by `MAX`) and `*_TOKEN_LIMIT` (last two words
  /// `TOKEN LIMIT`). Any other name containing TOKEN stays a secret.
  static bool _isTokenLimitOrCount(List<String> words) {
    final n = words.length;
    final isMaxTokens =
        n >= 2 && words[n - 1] == 'TOKENS' && words[n - 2] == 'MAX';
    final isTokenLimit =
        n >= 2 && words[n - 2] == 'TOKEN' && words[n - 1] == 'LIMIT';
    return isMaxTokens || isTokenLimit;
  }

  /// True when a single `_`-separated word marks the name as a credential.
  static bool _isSecretWord(String word) =>
      _secretWords.contains(word) ||
      word.endsWith('TOKEN') ||
      word.endsWith('SECRET') ||
      word.endsWith('PASSWORD') ||
      word.endsWith('APIKEY');

  /// Built-in allowlist: every declared [PropertyNames] constant minus the
  /// secrets, plus [allowlistKey].
  static final Set<String> defaultAllowed = Set.unmodifiable({
    for (final name in PropertyNames.all)
      if (!looksSecret(name)) name,
    allowlistKey,
  });

  /// Names added through `JS_ENV_ALLOWLIST` (comma/space separated), upper
  /// cased, secrets dropped.
  static Set<String> projectAllowed(String? rawAllowlist) => {
        for (final name in _tokens(rawAllowlist))
          if (_upperName.hasMatch(name) && !looksSecret(name)) name,
      };

  /// Names from `JS_ENV_ALLOWLIST` rejected because they look like secrets.
  static Set<String> rejectedFromAllowlist(String? rawAllowlist) => {
        for (final name in _tokens(rawAllowlist))
          if (_upperName.hasMatch(name) && looksSecret(name)) name,
      };

  /// Decision for one [name] given the raw `JS_ENV_ALLOWLIST` value.
  static EnvDecision decide(String? name, String? rawProjectAllowlist) {
    if (name == null || !_validName.hasMatch(name)) {
      return EnvDecision.invalidName;
    }
    final upper = name.toUpperCase();
    if (looksSecret(upper)) return EnvDecision.secret;
    if (defaultAllowed.contains(upper) ||
        projectAllowed(rawProjectAllowlist).contains(upper)) {
      return EnvDecision.allowed;
    }
    return EnvDecision.notAllowlisted;
  }

  static Iterable<String> _tokens(String? raw) sync* {
    if (raw == null) return;
    for (final part in raw.split(_separators)) {
      final name = part.trim().toUpperCase();
      if (name.isNotEmpty) yield name;
    }
  }
}
