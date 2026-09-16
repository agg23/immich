import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/native_shell/native_timeline_window.dart';

/// The flat↔section mapping every platform grid needs.
void main() {
  TimelineSections sectionsOf(List<int> counts) =>
      TimelineSections.fromBuckets([for (final count in counts) Bucket(assetCount: count)]);

  group('fromBuckets', () {
    test('lays sections end to end', () {
      final sections = sectionsOf([3, 1, 4]);
      expect(sections.sections.map((s) => s.offset), [0, 3, 4]);
      expect(sections.total, 8);
    });

    test('keeps the dates of dated buckets and tolerates undated ones', () {
      final date = DateTime.utc(2025, 3, 1);
      final sections = TimelineSections.fromBuckets([
        TimeBucket(date: date, assetCount: 2),
        const Bucket(assetCount: 1),
      ]);
      expect(sections.sections.first.date, date);
      expect(sections.sections.last.date, isNull);
    });

    test('drops empty buckets, which would otherwise share an offset', () {
      final sections = sectionsOf([2, 0, 3]);
      expect(sections.sections.length, 2);
      expect(sections.sections.map((s) => s.offset), [0, 2]);
      expect(sections.total, 5);
    });

    test('an empty timeline is empty, not a section of nothing', () {
      expect(sectionsOf(const []).isEmpty, isTrue);
      expect(sectionsOf([0, 0]).sections, isEmpty);
    });
  });

  group('locate', () {
    test('finds the section holding each index, including boundaries', () {
      final sections = sectionsOf([3, 1, 4]);
      expect(sections.locate(0), (section: 0, item: 0));
      expect(sections.locate(2), (section: 0, item: 2));
      expect(sections.locate(3), (section: 1, item: 0));
      expect(sections.locate(4), (section: 2, item: 0));
      expect(sections.locate(7), (section: 2, item: 3));
    });

    test('refuses an index off either end', () {
      final sections = sectionsOf([3, 1]);
      expect(sections.locate(-1), isNull);
      expect(sections.locate(4), isNull);
      expect(sectionsOf(const []).locate(0), isNull);
    });

    test('agrees with flatIndex over a whole timeline', () {
      final sections = sectionsOf([5, 1, 12, 3, 9]);
      for (var flat = 0; flat < sections.total; flat++) {
        final at = sections.locate(flat)!;
        expect(sections.flatIndex(section: at.section, item: at.item), flat);
      }
    });
  });

  group('flatIndex', () {
    test('refuses an item past the end of its section', () {
      final sections = sectionsOf([3, 1]);
      expect(sections.flatIndex(section: 0, item: 3), isNull);
      expect(sections.flatIndex(section: 2, item: 0), isNull);
      expect(sections.flatIndex(section: -1, item: 0), isNull);
    });
  });

  group('clampWindow', () {
    test('passes a window that fits', () {
      expect(clampWindow(start: 0, count: 120, total: 500), (start: 0, count: 120));
    });

    test('shortens a window that runs off the end', () {
      expect(clampWindow(start: 480, count: 120, total: 500), (start: 480, count: 20));
    });

    test('asks for nothing past the end, rather than a negative count', () {
      expect(clampWindow(start: 600, count: 120, total: 500).count, 0);
      expect(clampWindow(start: 0, count: 120, total: 0).count, 0);
    });

    test('pulls a negative start back to the beginning', () {
      expect(clampWindow(start: -10, count: 5, total: 500), (start: 0, count: 5));
    });
  });
}
