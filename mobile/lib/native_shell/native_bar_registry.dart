import 'package:flutter/foundation.dart';
import 'package:immich_mobile/native_shell/native_shell.dart';

@immutable
class NativeBar {
  const NativeBar({required this.title, required this.actions, this.hero = false});

  final String title;
  final List<NativeBarAction> actions;

  /// Starts transparent over a cover photo.
  final bool hero;

  Map<String, Object?> describe(String route) => {
    'name': route,
    'title': title,
    'actions': [for (final action in actions) action.describe()],
    'hero': hero,
  };

  @override
  bool operator ==(Object other) =>
      other is NativeBar && other.title == title && other.hero == hero && listEquals(other.actions, actions);

  @override
  int get hashCode => Object.hash(title, hero, Object.hashAll(actions));
}

typedef NativeBarHit = ({NativeBarAction action, NativeMenuItem? row});

/// The bars every live route has published. No channel, no router: this part tests.
class NativeBarRegistry {
  NativeBarRegistry({required this.onChanged});

  /// Only on a real change: a rebuild republishes an identical bar every frame.
  final VoidCallback onChanged;

  final _bars = <String, NativeBar>{};
  final _collapsed = <String, bool>{};

  NativeBar? operator [](String route) => _bars[route];

  bool get isEmpty => _bars.isEmpty;

  void publish(String route, NativeBar bar) {
    if (_bars[route] == bar) {
      return;
    }
    _bars[route] = bar;
    onChanged();
  }

  void clear(String route) {
    _collapsed.remove(route);
    if (_bars.remove(route) != null) {
      onChanged();
    }
  }

  /// Whether this is news; the threshold is reported on every scroll frame.
  bool setCollapsed(String route, {required bool collapsed}) {
    if (_collapsed[route] == collapsed) {
      return false;
    }
    _collapsed[route] = collapsed;
    return true;
  }

  /// Null once the bar has moved on, leaving the caller to re-sync rather than guess.
  NativeBarHit? resolve({required String route, required int index, required int item}) {
    final action = _bars[route]?.actions.elementAtOrNull(index);
    if (action == null) {
      return null;
    }
    if (item < 0) {
      return (action: action, row: null);
    }
    final row = action.menu?.elementAtOrNull(item);
    return row == null ? null : (action: action, row: row);
  }

  // Not `row?.onPressed ?? action.onPressed`: a disabled row would fall through.
  static VoidCallback? handlerFor(NativeBarHit hit) => hit.row != null ? hit.row!.onPressed : hit.action.onPressed;

  @visibleForTesting
  void clearAll() {
    _bars.clear();
    _collapsed.clear();
  }
}
