/// Encoding auto-detection and decoding — Dart port of Java `EncodingDetector`.
///
/// Mirrors `EncodingDetector.autoDetectAndDecode()`: tries base64 first, then
/// URL-encoding, throwing [ArgumentError] when both attempts fail.
library;

import 'dart:convert';

/// Auto-detects and decodes an encoded string.
///
/// Tries base64 first; if the string is not valid base64 (or the decoded bytes
/// are not valid UTF-8), falls back to URL-encoding. Throws [ArgumentError]
/// when both decoding attempts fail.
String autoDetectAndDecode(String encoded) {
  final base64Result = _tryBase64Decode(encoded);
  if (base64Result != null) {
    return base64Result;
  }
  final urlResult = _tryUrlDecode(encoded);
  if (urlResult != null) {
    return urlResult;
  }
  throw ArgumentError(
    'Could not decode string as base64 or URL-encoding: $encoded',
  );
}

/// Attempts a base64 decode; returns the decoded string or `null` on failure.
///
/// A candidate must match the base64 alphabet (`A-Z`, `a-z`, `0-9`, `+`, `/`,
/// with up to two trailing `=`) and a length divisible by 4; the decoded bytes
/// must form valid UTF-8. This guards against falsely decoding URL-encoded
/// input (which contains `%`) or arbitrary text.
String? _tryBase64Decode(String encoded) {
  if (encoded.isEmpty || encoded.length % 4 != 0) {
    return null;
  }
  if (!RegExp(r'^[A-Za-z0-9+/]+={0,2}$').hasMatch(encoded)) {
    return null;
  }
  try {
    final bytes = base64.decode(encoded);
    return utf8.decode(bytes);
  } on FormatException {
    return null;
  }
}

/// Attempts a URL-decode; returns the decoded string or `null` on failure.
///
/// Replaces `+` with `%20` first to support `application/x-www-form-urlencoded`
/// payloads (matching Java `URLDecoder.decode`), while preserving `%2B` as
/// literal `+`. `Uri.decodeComponent` throws [FormatException] on malformed
/// percent-escape sequences (e.g. `%zz`), which counts as a failure here.
String? _tryUrlDecode(String encoded) {
  try {
    return Uri.decodeComponent(encoded.replaceAll('+', '%20'));
  } on FormatException {
    return null;
  }
}
