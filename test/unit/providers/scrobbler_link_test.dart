import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/providers/session_provider.dart';

void main() {
  const a = 'https://jf.example|user-a';
  const b = 'https://jf.example|user-b';

  ScrobblerLinkAction decide({required bool connected, String? owner, String account = a}) =>
      decideScrobblerLink(connected: connected, owner: owner, account: account);

  group('decideScrobblerLink', () {
    test('a connected link with no recorded owner is adopted', () {
      expect(decide(connected: true), ScrobblerLinkAction.adopt);
    });

    test("the owner's own link is kept", () {
      expect(decide(connected: true, owner: a), ScrobblerLinkAction.keep);
    });

    test("another account's link is disconnected", () {
      expect(decide(connected: true, owner: a, account: b),
          ScrobblerLinkAction.disconnect);
    });

    test('a disconnected link forgets its owner', () {
      expect(decide(connected: false, owner: a, account: b),
          ScrobblerLinkAction.forget);
    });

    test('nothing connected and no owner: nothing to do', () {
      expect(decide(connected: false), ScrobblerLinkAction.keep);
    });
  });
}
