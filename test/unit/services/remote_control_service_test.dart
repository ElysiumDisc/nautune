import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/services/remote_control_service.dart';

void main() {
  test('keep-alive request', () {
    final c = parseRemoteMessage('{"MessageType":"ForceKeepAlive","Data":60}');
    expect(c, isA<RemoteKeepAlive>());
    expect((c as RemoteKeepAlive).interval, const Duration(seconds: 60));
  });

  test('playstate with seek position (ticks are 100 ns)', () {
    final c = parseRemoteMessage(
        '{"MessageType":"Playstate","Data":{"Command":"Seek","SeekPositionTicks":300000000}}');
    expect(c, isA<RemotePlaystate>());
    c as RemotePlaystate;
    expect(c.command, 'Seek');
    expect(c.seekPosition, const Duration(seconds: 30));
  });

  test('play command', () {
    final c = parseRemoteMessage(
        '{"MessageType":"Play","Data":{"ItemIds":["a","b"],"StartIndex":1,"PlayCommand":"PlayNext"}}');
    c as RemotePlay;
    expect(c.itemIds, ['a', 'b']);
    expect(c.startIndex, 1);
    expect(c.playCommand, 'PlayNext');
  });

  test('general command arguments become strings', () {
    final c = parseRemoteMessage(
        '{"MessageType":"GeneralCommand","Data":{"Name":"SetVolume","Arguments":{"Volume":35}}}');
    c as RemoteGeneral;
    expect(c.name, 'SetVolume');
    expect(c.arguments['Volume'], '35');
  });

  test('ignores junk and unrelated messages', () {
    expect(parseRemoteMessage('not json'), isNull);
    expect(parseRemoteMessage('{"MessageType":"LibraryChanged","Data":{}}'), isNull);
    expect(parseRemoteMessage('{"MessageType":"Play","Data":{"ItemIds":[]}}'), isNull);
  });

  test('socket URL keeps the base path, switches scheme, carries no token', () {
    final uri = RemoteControlService.socketUri('https://host/jellyfin', 'dev');
    expect(uri.toString(), 'wss://host/jellyfin/socket?deviceId=dev');
    expect(uri.queryParameters.keys, isNot(contains('ApiKey')));
    expect(RemoteControlService.socketUri('http://10.0.0.2:8096', 'd').scheme, 'ws');
  });
}
