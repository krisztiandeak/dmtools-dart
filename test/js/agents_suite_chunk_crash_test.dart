import 'package:dmtools/src/js/agents_suite.dart';
import 'package:test/test.dart';

/// `_runChunkSync` must never rethrow: when the per-chunk tree copy fails
/// (here, the working directory does not exist), the failure must come
/// back as a crashed outcome carrying the shard index, and the temp copy
/// root must not be left behind.
void main() {
  test('runChunkInIsolate: a failed tree copy becomes a crashed outcome',
      () async {
    final missing =
        'test/.tmp_missing_chunk_src_${DateTime.now().microsecondsSinceEpoch}';
    final chunk = ShardInvocation(
      index: 4,
      total: 6,
      scriptPath: 'agents/does_not_exist.js',
      jobParams: const {},
      workingDirectory: missing,
      preludeCode: '',
    );

    final outcome = await runChunkInIsolate(chunk);

    expect(outcome.index, 4);
    expect(outcome.result, isNull);
    expect(outcome.error, isNotNull);
    expect(outcome.error, isNotEmpty);
  });
}
