import 'package:flutter/material.dart';
import 'package:immich_mobile/native_shell/native_shell.dart';

/// Replaces `MediaQuery.padding` with what the native shell reports.
///
/// Flutter's view fills its native container, so the padding it works out for
/// itself is the window's — the status bar and the home indicator. It cannot
/// see the navigation bar above it or the tab bar below it, which is why a
/// hosted page draws its scrubber under the native title.
///
/// A single wrapper at the app root rather than a change to each page: the
/// pages already lay out against `context.padding` correctly, they are just
/// being given the wrong number.
class NativeShellInsets extends StatelessWidget {
  const NativeShellInsets({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!NativeShell.isActive) {
      return child;
    }
    return ValueListenableBuilder<EdgeInsets?>(
      valueListenable: NativeShell.insets,
      builder: (context, insets, _) {
        if (insets == null) {
          return child;
        }
        final media = MediaQuery.of(context);
        // viewPadding as well as padding: a page that reads viewPadding is
        // asking what the chrome covers regardless of the keyboard, and the
        // answer is the same.
        return MediaQuery(data: media.copyWith(padding: insets, viewPadding: insets), child: child);
      },
    );
  }
}
