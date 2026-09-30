import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/services/listenbrainz_service.dart';

void main() {
  test('valid token reports the account user_name', () {
    final c = ListenBrainzService.parseTokenCheck(
        200, '{"code":200,"message":"Token valid.","valid":true,"user_name":"rob"}');
    expect(c.status, ListenBrainzTokenStatus.valid);
    expect(c.userName, 'rob');
  });

  test('invalid token vs network/server problems', () {
    expect(
      ListenBrainzService.parseTokenCheck(200, '{"valid":false}').status,
      ListenBrainzTokenStatus.invalid,
    );
    expect(ListenBrainzService.parseTokenCheck(401, '').status,
        ListenBrainzTokenStatus.invalid);
    expect(ListenBrainzService.parseTokenCheck(503, '').status,
        ListenBrainzTokenStatus.networkError);
    expect(ListenBrainzService.parseTokenCheck(429, '').status,
        ListenBrainzTokenStatus.networkError);
    expect(ListenBrainzService.parseTokenCheck(200, '<html>').status,
        ListenBrainzTokenStatus.networkError);
  });
}
