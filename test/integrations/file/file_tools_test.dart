import 'dart:io';

import 'package:dmtools/dmtools.dart';
import 'package:test/test.dart';

/// Tests for the [fileTools] catalog and [FileToolExecutor] operations.
void main() {
  toolCatalogTests();
  readTests();
  writeTests();
  listTests();
  existsTests();
  deleteTests();
  unknownToolTests();
}

/// Looks up a registered tool by name.
ToolDefinition toolNamed(String name) =>
    fileTools().firstWhere((t) => t.name == name);

/// Creates a temp directory for file-operation tests.
/// Symlink-resolved (macOS `/var` → `/private/var`) so paths compare equal
/// to the canonical ones the executor reports.
Directory _tempDir() => Directory(
      Directory.systemTemp
          .createTempSync('dmtools_file_test_')
          .resolveSymbolicLinksSync(),
    );

/// Catalog shape: names, integration, params, category.
void toolCatalogTests() {
  group('fileTools catalog', () {
    final tools = fileTools();

    test('registers tools in declaration order, five originals first', () {
      expect(tools.map((t) => t.name).take(5), [
        'file_read',
        'file_write',
        'file_list',
        'file_exists',
        'file_delete',
      ]);
    });

    test('every tool belongs to the file integration', () {
      expect(tools.every((t) => t.integration == 'file'), isTrue);
    });

    test('every tool is in the filesystem category', () {
      expect(tools.every((t) => t.category == 'filesystem'), isTrue);
    });

    test('every tool has a required first param', () {
      for (final tool in tools) {
        expect(tool.params.first.required, isTrue, reason: tool.name);
      }
    });

    test('file_write also has a required content param', () {
      final tool = toolNamed('file_write');
      final contentParam = tool.params.firstWhere((p) => p.name == 'content');
      expect(contentParam.required, isTrue);
    });
  });
}

/// [FileToolExecutor.read] and `file_read` dispatch.
void readTests() {
  late FileToolExecutor executor;
  late Directory tempDir;

  setUp(() {
    executor = FileToolExecutor();
    tempDir = _tempDir();
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  group('FileToolExecutor.read', () {
    test('reads file content', () async {
      final file = File('${tempDir.path}/read.txt')
        ..writeAsStringSync('hello world');
      expect(await executor.read(file.path), 'hello world');
    });

    test('routes file_read through execute dispatch', () async {
      final file = File('${tempDir.path}/dispatch.txt')
        ..writeAsStringSync('dispatched');
      final result =
          await executor.execute('file_read', {'path': file.path}) as String;
      expect(result, 'dispatched');
    });

    test('throws on missing file', () {
      expect(
        executor.read('${tempDir.path}/no_such.txt'),
        throwsA(isA<FileSystemException>()),
      );
    });
  });
}

/// [FileToolExecutor.write] and `file_write` dispatch.
void writeTests() {
  late FileToolExecutor executor;
  late Directory tempDir;

  setUp(() {
    executor = FileToolExecutor();
    tempDir = _tempDir();
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  group('FileToolExecutor.write', () {
    test('writes content to a new file', () async {
      final path = '${tempDir.path}/out.txt';
      await executor.write(path, 'written data');
      expect(File(path).readAsStringSync(), 'written data');
    });

    test('overwrites existing content', () async {
      final path = '${tempDir.path}/overwrite.txt';
      File(path).writeAsStringSync('old');
      await executor.write(path, 'new');
      expect(File(path).readAsStringSync(), 'new');
    });

    test('creates missing parent directories (Java parity)', () async {
      final path = '${tempDir.path}/a/b/c/out.txt';
      await executor.write(path, 'nested');
      expect(File(path).readAsStringSync(), 'nested');
    });

    test('routes file_write through execute dispatch', () async {
      final path = '${tempDir.path}/dispatch_write.txt';
      await executor
          .execute('file_write', {'path': path, 'content': 'via dispatch'});
      expect(File(path).readAsStringSync(), 'via dispatch');
    });
  });
}

/// [FileToolExecutor.list] and `file_list` dispatch.
void listTests() {
  late FileToolExecutor executor;
  late Directory tempDir;

  setUp(() {
    executor = FileToolExecutor();
    tempDir = _tempDir();
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  group('FileToolExecutor.list', () {
    test('lists entries in a directory', () async {
      File('${tempDir.path}/a.txt').writeAsStringSync('a');
      File('${tempDir.path}/b.txt').writeAsStringSync('b');
      final entries = await executor.list(tempDir.path);
      expect(entries.length, 2);
      expect(entries.every((e) => e.startsWith(tempDir.path)), isTrue);
      expect(entries.map((e) => e.split('/').last).toSet(), {'a.txt', 'b.txt'});
    });

    test('returns empty list for an empty directory', () async {
      final empty = Directory('${tempDir.path}/empty')..createSync();
      expect(await executor.list(empty.path), isEmpty);
    });

    test('routes file_list through execute dispatch', () async {
      File('${tempDir.path}/x.txt').writeAsStringSync('x');
      final entries = await executor
          .execute('file_list', {'path': tempDir.path}) as List<String>;
      expect(entries, hasLength(1));
    });
  });
}

/// [FileToolExecutor.exists] and `file_exists` dispatch.
void existsTests() {
  late FileToolExecutor executor;
  late Directory tempDir;

  setUp(() {
    executor = FileToolExecutor();
    tempDir = _tempDir();
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  group('FileToolExecutor.exists', () {
    test('returns true for an existing file', () async {
      final file = File('${tempDir.path}/e.txt')..writeAsStringSync('e');
      expect(await executor.exists(file.path), isTrue);
    });

    test('returns true for an existing directory', () async {
      expect(await executor.exists(tempDir.path), isTrue);
    });

    test('returns false for a missing path', () async {
      expect(await executor.exists('${tempDir.path}/missing'), isFalse);
    });

    test('routes file_exists through execute dispatch', () async {
      final file = File('${tempDir.path}/exists.txt')..writeAsStringSync('x');
      final result =
          await executor.execute('file_exists', {'path': file.path}) as bool;
      expect(result, isTrue);
    });
  });
}

/// [FileToolExecutor.delete] and `file_delete` dispatch.
void deleteTests() {
  late FileToolExecutor executor;
  late Directory tempDir;

  setUp(() {
    executor = FileToolExecutor();
    tempDir = _tempDir();
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  group('FileToolExecutor.delete', () {
    test('deletes an existing file and returns true', () async {
      final file = File('${tempDir.path}/del.txt')..writeAsStringSync('d');
      expect(await executor.delete(file.path), isTrue);
      expect(file.existsSync(), isFalse);
    });

    test('returns false for a missing file', () async {
      expect(await executor.delete('${tempDir.path}/nope.txt'), isFalse);
    });

    test('routes file_delete through execute dispatch', () async {
      final file = File('${tempDir.path}/dd.txt')..writeAsStringSync('x');
      final result =
          await executor.execute('file_delete', {'path': file.path}) as bool;
      expect(result, isTrue);
      expect(file.existsSync(), isFalse);
    });
  });
}

/// Unknown-tool rejection.
void unknownToolTests() {
  final executor = FileToolExecutor();

  test('execute throws ArgumentError for an unknown tool', () {
    expect(
      () => executor.execute('file_unknown', {'path': 'x'}),
      throwsArgumentError,
    );
  });
}
