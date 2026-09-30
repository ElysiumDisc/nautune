import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/services/essential_mix_service.dart';

void main() {
  group('EssentialMixService.resumeActionFor', () {
    EssentialMixResumeAction action(
      int status, {
      int existing = 0,
      String? range,
    }) =>
        EssentialMixService.resumeActionFor(
          statusCode: status,
          existingBytes: existing,
          contentRange: range,
        );

    test('206 from our offset appends to the partial file', () {
      expect(
        action(206, existing: 1000, range: 'bytes 1000-244958621/244958622'),
        EssentialMixResumeAction.append,
      );
      // No Content-Range header: trust the 206.
      expect(action(206, existing: 1000), EssentialMixResumeAction.append);
    });

    test('206 from a different offset discards the partial file', () {
      expect(
        action(206, existing: 1000, range: 'bytes 0-244958621/244958622'),
        EssentialMixResumeAction.discardPartial,
      );
    });

    test('200 restarts from the beginning', () {
      expect(action(200), EssentialMixResumeAction.restart);
      expect(action(200, existing: 5000), EssentialMixResumeAction.restart);
    });

    test('416 with a partial file discards it', () {
      expect(action(416, existing: 5000), EssentialMixResumeAction.discardPartial);
    });

    test('other statuses fail and keep the partial for later', () {
      expect(action(403, existing: 5000), EssentialMixResumeAction.fail);
      expect(action(500), EssentialMixResumeAction.fail);
      expect(action(416), EssentialMixResumeAction.fail);
      expect(action(206), EssentialMixResumeAction.fail);
    });

    test('recognises the Essential Mix track id', () {
      expect(EssentialMixService.isEssentialMixTrackId('essential-mix-soulwax-2017'), isTrue);
      expect(EssentialMixService.isEssentialMixTrackId('abc123'), isFalse);
    });
  });
}
