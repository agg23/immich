import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';

/// One navigation stack per tab.
///
/// Immich declared every pushable route as a sibling of `TabShellRoute`, so a
/// push landed on the root stack *above* the tab shell and covered the tab bar.
/// That is why the tab bar had to be hidden under the native shell, and why you
/// could not change tabs with a route open: there was only ever one stack.
///
/// These pages are router outlets and nothing else. Each tab's routes are
/// declared beneath one of them, so `context.pushRoute` — which resolves to the
/// nearest router — pushes into the tab you are actually in, and every other
/// tab keeps its own stack and its own state. That is what a
/// `UINavigationController` per tab already does on the native side, so this is
/// the Dart half of an arrangement the shell was always assuming.
///
/// One page per tab rather than one reused four times: `@RoutePage()` generates
/// a route class per widget, and `AutoTabsRouter` needs four distinct ones.
@RoutePage()
class PhotosTabPage extends StatelessWidget {
  const PhotosTabPage({super.key});

  @override
  Widget build(BuildContext context) => const AutoRouter();
}

@RoutePage()
class SearchTabPage extends StatelessWidget {
  const SearchTabPage({super.key});

  @override
  Widget build(BuildContext context) => const AutoRouter();
}

@RoutePage()
class AlbumsTabPage extends StatelessWidget {
  const AlbumsTabPage({super.key});

  @override
  Widget build(BuildContext context) => const AutoRouter();
}

@RoutePage()
class LibraryTabPage extends StatelessWidget {
  const LibraryTabPage({super.key});

  @override
  Widget build(BuildContext context) => const AutoRouter();
}
