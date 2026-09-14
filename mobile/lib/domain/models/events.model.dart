import 'package:immich_mobile/domain/utils/event_stream.dart';

// Timeline Events
class TimelineReloadEvent extends Event {
  const TimelineReloadEvent();
}

class ScrollToTopEvent extends Event {
  const ScrollToTopEvent();
}

/// Debug only: scroll the visible timeline to an offset.
///
/// The simulator takes no touch input from a script, so a scroll-driven
/// behaviour — a header collapsing, a bar taking over its title — cannot
/// otherwise be exercised at all.
class ScrollToOffsetEvent extends Event {
  const ScrollToOffsetEvent(this.offset);

  final double offset;
}

class ScrollToDateEvent extends Event {
  final DateTime date;

  const ScrollToDateEvent(this.date);
}

// Asset Viewer Events
class ViewerShowDetailsEvent extends Event {
  const ViewerShowDetailsEvent();
}

class ViewerReloadAssetEvent extends Event {
  const ViewerReloadAssetEvent();
}

class ViewerStackAssetDeletedEvent extends Event {
  final int stackIndex;

  const ViewerStackAssetDeletedEvent({required this.stackIndex});
}

// Multi-Select Events
class MultiSelectToggleEvent extends Event {
  final bool isEnabled;
  const MultiSelectToggleEvent(this.isEnabled);
}

// Map Events
class MapMarkerReloadEvent extends Event {
  const MapMarkerReloadEvent();
}
