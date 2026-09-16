import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';

@immutable
class TimelineSection {
  const TimelineSection({required this.offset, required this.count, this.date});

  final int offset;
  final int count;

  final DateTime? date;

  Map<String, Object?> describe() => {
    'offset': offset,
    'count': count,
    if (date != null) 'date': date!.millisecondsSinceEpoch,
  };

  @override
  bool operator ==(Object other) =>
      other is TimelineSection && other.offset == offset && other.count == count && other.date == date;

  @override
  int get hashCode => Object.hash(offset, count, date);
}

/// A timeline's buckets flattened once, so no platform derives offsets itself.
@immutable
class TimelineSections {
  const TimelineSections._(this.sections, this.total);

  factory TimelineSections.fromBuckets(List<Bucket> buckets) {
    final sections = <TimelineSection>[];
    var offset = 0;
    for (final bucket in buckets) {
      // An empty bucket shares its offset with the next, making [locate] ambiguous.
      if (bucket.assetCount <= 0) {
        continue;
      }
      sections.add(
        TimelineSection(offset: offset, count: bucket.assetCount, date: bucket is TimeBucket ? bucket.date : null),
      );
      offset += bucket.assetCount;
    }
    return TimelineSections._(List.unmodifiable(sections), offset);
  }

  static const empty = TimelineSections._(<TimelineSection>[], 0);

  final List<TimelineSection> sections;

  final int total;

  bool get isEmpty => total == 0;

  int? flatIndex({required int section, required int item}) {
    if (section < 0 || section >= sections.length || item < 0 || item >= sections[section].count) {
      return null;
    }
    return sections[section].offset + item;
  }

  ({int section, int item})? locate(int flatIndex) {
    if (flatIndex < 0 || flatIndex >= total) {
      return null;
    }
    // Binary search: thousands of day sections, walked on every cell configure.
    var low = 0;
    var high = sections.length - 1;
    while (low < high) {
      final mid = (low + high + 1) ~/ 2;
      if (sections[mid].offset <= flatIndex) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return (section: low, item: flatIndex - sections[low].offset);
  }

  List<Map<String, Object?>> describe() => [for (final section in sections) section.describe()];

  @override
  bool operator ==(Object other) =>
      other is TimelineSections && other.total == total && listEquals(other.sections, sections);

  @override
  int get hashCode => Object.hash(total, Object.hashAll(sections));
}

/// Clamps a viewport-sized request to what the timeline actually holds.
({int start, int count}) clampWindow({required int start, required int count, required int total}) {
  if (total <= 0 || count <= 0 || start >= total) {
    return (start: math.max(0, math.min(start, total)), count: 0);
  }
  final from = math.max(0, start);
  return (start: from, count: math.min(count, total - from));
}
