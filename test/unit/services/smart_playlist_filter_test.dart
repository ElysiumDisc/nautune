import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/services/smart_playlist_filter.dart';

void main() {
  group('trackMatchesAllTags', () {
    test('returns false when trackTags is null', () {
      expect(trackMatchesAllTags(null, const ['rock']), false);
    });

    test('returns false when trackTags is empty', () {
      expect(trackMatchesAllTags(const [], const ['rock']), false);
    });

    test('returns true when the query is empty (vacuously satisfied)', () {
      // No tags to require -> every() over an empty list is true.
      expect(trackMatchesAllTags(const ['rock'], const []), true);
    });

    test('matches case-insensitively on the track side', () {
      expect(trackMatchesAllTags(const ['Rock', 'Live'], const ['rock']), true);
      expect(trackMatchesAllTags(const ['ROCK'], const ['rock']), true);
    });

    test('requires every query tag to match at least one track tag', () {
      expect(
        trackMatchesAllTags(const ['rock', 'live'], const ['rock', 'live']),
        true,
      );
      expect(
        trackMatchesAllTags(const ['rock'], const ['rock', 'live']),
        false,
      );
    });

    test('uses substring (contains) semantics, not exact match', () {
      // Query 'roc' is a substring of 'rock'.
      expect(trackMatchesAllTags(const ['rock'], const ['roc']), true);
      // Query 'rocky' is not a substring of 'rock'.
      expect(trackMatchesAllTags(const ['rock'], const ['rocky']), false);
    });

    test('matches across multiple track tags for one query tag', () {
      expect(
        trackMatchesAllTags(
          const ['Indie', 'Folk', 'Live'],
          const ['folk', 'live'],
        ),
        true,
      );
    });

    test('preserves behavior of pre-refactor allocation-heavy version', () {
      // Cross-check: the old code lowercased both sides into lists then ran
      // normalizedTags.every((nt) => trackTagsNormalized.any((tt) => tt.contains(nt))).
      // Spot-check a few inputs against an inline equivalent.
      bool reference(List<String>? trackTags, List<String> normalizedQuery) {
        if (trackTags == null || trackTags.isEmpty) return false;
        final normalized = trackTags.map((t) => t.toLowerCase()).toList();
        return normalizedQuery
            .every((nt) => normalized.any((tt) => tt.contains(nt)));
      }

      final samples = <(List<String>?, List<String>)>[
        (null, ['x']),
        ([], ['x']),
        (['Rock', 'Live'], ['rock']),
        (['ROCK'], ['rock']),
        (['rock'], ['roc']),
        (['rock'], ['rocky']),
        (['Indie', 'Folk', 'Live'], ['folk', 'live']),
        (['Pop'], ['rock', 'live']),
        (['Jazz', 'Smooth'], ['smooth', 'jazz']),
      ];

      for (final (trackTags, query) in samples) {
        expect(
          trackMatchesAllTags(trackTags, query),
          reference(trackTags, query),
          reason: 'tags=$trackTags query=$query',
        );
      }
    });
  });
}
