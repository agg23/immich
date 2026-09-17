import 'package:flutter/widgets.dart';
import 'package:immich_mobile/native_shell/native_bar_publisher.dart';
import 'package:immich_mobile/native_shell/native_shell.dart';

/// Transparent over a cover photo, fading to solid. The fade is native; Dart
/// only reports the threshold.
mixin NativeHeroBar<T extends StatefulWidget> on NativeBarPublisher<T> {
  bool _hero = false;

  bool get isHero => _hero;

  void publishHeroBar({required String title, List<Widget>? actions}) {
    _hero = publishTranslated(title: title, actions: actions, hero: true);
  }

  void reportHeroCollapse(double scrollProgress) {
    final route = barRoute;
    if (_hero && route != null) {
      NativeShell.setBarProgress(route, scrollProgress);
      NativeShell.setBarCollapsed(route, collapsed: scrollProgress > 0.95);
    }
  }
}
