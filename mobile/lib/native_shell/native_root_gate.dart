import 'package:flutter/material.dart';
import 'package:immich_mobile/native_shell/native_shell.dart';
import 'package:immich_mobile/routing/tabs.dart';

/// A tab root the shell may draw itself. Under a native root Dart's page is never seen,
/// so building it — a timeline with its own buckets, thumbnails and rebuilds — is work
/// the platform thread pays for nothing. The route stays: tab indices, `popToRoot` and
/// the frames pushed over it are unchanged, only the page body is an empty surface.
class NativeRootGate extends StatelessWidget {
  const NativeRootGate({super.key, required this.tab, required this.child, @visibleForTesting this.active});

  final NativeTab tab;
  final Widget child;

  /// Tests only; the shell decides otherwise.
  final bool? active;

  bool get _active => active ?? NativeShell.isActive;

  /// True while the shell has not answered `ready`, and after it named this tab.
  static bool isNative(NativeTab tab, Set<String>? roots) => roots == null || roots.contains(tab.id);

  @override
  Widget build(BuildContext context) {
    if (!_active) {
      return child;
    }
    return ValueListenableBuilder(
      valueListenable: NativeShell.nativeRoots,
      builder: (context, roots, _) =>
          isNative(tab, roots) ? ColoredBox(color: Theme.of(context).colorScheme.surface) : child,
    );
  }
}
