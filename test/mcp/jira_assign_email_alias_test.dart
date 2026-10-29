import 'package:dmtools/dmtools.dart';
import 'package:test/test.dart';

/// Review thread PRRT_kwDOTw8Iwc6tjOGz (BLOCKING): an email must never be
/// normalized onto `accountId`, because Jira expects an account ID there.
void main() {
  final tool = createDefaultToolRegistry().getTool('jira_assign_ticket_to');

  test('jira_assign_ticket_to is registered', () {
    expect(tool, isNotNull);
  });

  test('userEmail is not an alias for accountId', () {
    final out = tool!.applyParamAliases({'userEmail': 'a@b.com'});
    expect(out.containsKey('accountId'), isFalse);
  });

  test('assignee is not an alias for accountId', () {
    final out = tool!.applyParamAliases({'assignee': 'a@b.com'});
    expect(out.containsKey('accountId'), isFalse);
  });

  test('accountId itself still passes through unchanged', () {
    final out =
        tool!.applyParamAliases({'accountId': '5b10ac8d82e05b22cc7d4ef5'});
    expect(out['accountId'], '5b10ac8d82e05b22cc7d4ef5');
  });
}
