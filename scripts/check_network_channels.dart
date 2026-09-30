// Checks every audio and image URL of The Network Easter egg against the
// live server and reports what is broken.
//
// Usage (from the repo root):
//   dart run scripts/check_network_channels.dart
//
// Exit code 1 if a channel marked available has a dead file, or a channel
// marked unavailable has come back (so the data can be updated either way).
// Pure Dart: no Flutter needed.

import 'dart:async';
import 'dart:io';

import 'package:nautune/data/network_channels.dart';
import 'package:nautune/models/network_channel.dart';

const _concurrency = 12;
const _timeout = Duration(seconds: 30);

Future<void> main() async {
  final client = HttpClient()..connectionTimeout = _timeout;
  final checks = <_Check>[];
  final seen = <String>{};
  for (final channel in networkChannels) {
    if (seen.add('a:${channel.audioFile}')) {
      checks.add(_Check(channel, channel.audioUrl, isAudio: true));
    }
    final image = channel.imageUrl;
    if (image != null && seen.add('i:${channel.imageFile}')) {
      checks.add(_Check(channel, image, isAudio: false));
    }
  }

  var next = 0;
  Future<void> worker() async {
    while (next < checks.length) {
      final check = checks[next++];
      check.status = await _probe(client, check.url);
    }
  }

  await Future.wait(List.generate(_concurrency, (_) => worker()));
  client.close(force: true);

  var problems = 0;
  for (final check in checks) {
    final ok = check.status == 200 || check.status == 206;
    final kind = check.isAudio ? 'audio' : 'image';
    final label = '${check.channel.number.toString().padLeft(3)} '
        '${check.channel.name} ($kind)';
    if (check.isAudio && !check.channel.available) {
      if (ok) {
        problems++;
        stdout.writeln('BACK  $label is marked unavailable but answers '
            '${check.status}: ${check.url}');
      }
      continue;
    }
    if (!ok) {
      if (check.isAudio) problems++;
      stdout.writeln('${check.isAudio ? 'DEAD ' : 'WARN '} $label -> '
          '${check.status ?? 'no response'}: ${check.url}');
    }
  }

  final unavailable = networkChannels.where((c) => !c.available).length;
  stdout.writeln('Checked ${checks.length} URLs for ${networkChannels.length} '
      'channels ($unavailable marked unavailable). Problems: $problems.');
  exit(problems == 0 ? 0 : 1);
}

/// Status code of a one-byte ranged GET (some hosts reject HEAD), or null.
Future<int?> _probe(HttpClient client, String url) async {
  try {
    final request = await client.getUrl(Uri.parse(url)).timeout(_timeout);
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
    final response = await request.close().timeout(_timeout);
    await response.drain<void>();
    return response.statusCode;
  } catch (_) {
    return null;
  }
}

class _Check {
  _Check(this.channel, this.url, {required this.isAudio});

  final NetworkChannel channel;
  final String url;
  final bool isAudio;
  int? status;
}
