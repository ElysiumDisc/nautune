import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/data/network_channels.dart';

void main() {
  group('networkChannels data', () {
    test('channel numbers are unique', () {
      final numbers = networkChannels.map((c) => c.number).toList();
      expect(numbers.toSet().length, numbers.length);
    });

    test('numbers sit on the 0-333 dial, plus the hidden 999', () {
      for (final channel in networkChannels) {
        expect(
          (channel.number >= 0 && channel.number <= 333) ||
              channel.number == 999,
          isTrue,
          reason: 'channel ${channel.number}',
        );
      }
    });

    test('every channel has a name, artist and audio file', () {
      for (final channel in networkChannels) {
        expect(channel.name.trim(), isNotEmpty, reason: '${channel.number}');
        expect(channel.artist.trim(), isNotEmpty, reason: '${channel.number}');
        expect(channel.audioFile, endsWith('.mp3'), reason: '${channel.number}');
        expect(channel.imageFile?.trim(), isNot(''), reason: '${channel.number}');
      }
    });

    test('channels whose recording is gone are flagged, not removed', () {
      final unavailable = networkChannels
          .where((c) => !c.available)
          .map((c) => c.number)
          .toSet();
      // Checked against the server with scripts/check_network_channels.dart.
      expect(unavailable, {24, 61, 120, 121, 303, 333, 999});
      expect(
        availableNetworkChannels.map((c) => c.number),
        isNot(anyElement(isIn(unavailable))),
      );
      expect(
        availableNetworkChannels.length + unavailable.length,
        networkChannels.length,
      );
    });

    test('lookup map and sorted list cover every channel', () {
      expect(networkChannelsByNumber.length, networkChannels.length);
      expect(sortedChannels.length, networkChannels.length);
      for (var i = 1; i < sortedChannels.length; i++) {
        expect(sortedChannels[i - 1].number < sortedChannels[i].number, isTrue);
      }
    });

    test('URLs percent-encode file names', () {
      final channel = networkChannelsByNumber[145]!; // 'radio radi0.mp3'
      expect(
        channel.audioUrl,
        'https://www.other-people.network/audio/radio%20radi0.mp3',
      );
    });

    test('findNearestChannel picks the closest number', () {
      expect(findNearestChannel(333).number, 333);
      expect(findNearestChannel(0).number, 0);
    });
  });
}
