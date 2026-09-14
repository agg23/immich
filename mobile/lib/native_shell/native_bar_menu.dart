import 'package:flutter/material.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/native_shell/native_shell.dart';
import 'package:immich_mobile/native_shell/native_symbols.dart';
import 'package:immich_mobile/presentation/widgets/action_buttons/base_action_button.widget.dart';

/// One row of an app bar's overflow menu.
///
/// The same three things Immich's own [BaseActionButton] is made of — a label,
/// an icon and a callback — because that is what the menus are already built
/// from. [destructive] is the one addition, and it is not new behaviour: the
/// album menu already draws its delete row red and separates it with a
/// `Divider`, which is what iOS spells as a destructive attribute and its own
/// section.
class NativeBarMenuItem {
  const NativeBarMenuItem({required this.label, required this.icon, this.onPressed, this.destructive = false});

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool destructive;
}

/// An app bar overflow menu, described once and rendered twice.
///
/// [NativeAppBar] cannot read a menu out of the widget tree: a `MenuAnchor`
/// only exists once the widget holding it has been built, with a
/// `BuildContext` and a `WidgetRef` that a bar inspecting `actions` does not
/// have — which is why Immich wrapped each one in a `ConsumerWidget` or a
/// `FutureBuilder` in the first place. So the menu is *declared* instead of
/// inferred, and the wrapper moves outward, to the page that owns the state.
/// This widget renders the Flutter menu Immich has today everywhere the native
/// bar is not showing — Android, and any page whose bar falls back.
///
/// That is also why this is one widget rather than a mixin or a marker
/// interface: the four hand-rolled `MenuAnchor`s each repeated the same
/// `MenuStyle`, so describing the menu removes duplication instead of adding a
/// seam.
class NativeBarMenu extends StatelessWidget {
  const NativeBarMenu({
    super.key,
    required this.icon,
    required this.items,
    this.iconColor,
    this.iconShadows,
    this.tooltip,
  });

  /// The trigger, which is the button the native bar shows and the icon the
  /// Flutter menu hangs off.
  final IconData icon;
  final List<NativeBarMenuItem> items;

  /// The album and person headers tint and shadow their icons against a cover
  /// photo. Meaningless natively — a `UIBarButtonItem` is tinted by the bar —
  /// and kept because the Flutter rendering is still what Android draws.
  final Color? iconColor;
  final List<Shadow>? iconShadows;
  final String? tooltip;

  /// This menu as the native bar would receive it, or null if any part of it
  /// does not translate.
  ///
  /// All or nothing, like every other bar: a native menu quietly missing the
  /// row you were reaching for is worse than a Flutter menu that has it.
  NativeBarAction? describe() {
    final trigger = nativeSymbolFor(icon);
    if (trigger == null || items.isEmpty) {
      return null;
    }
    final rows = <NativeMenuItem>[];
    for (final item in items) {
      final symbol = nativeSymbolFor(item.icon);
      if (symbol == null) {
        return null;
      }
      rows.add(
        NativeMenuItem(
          label: item.label,
          symbol: symbol,
          onPressed: item.onPressed,
          destructive: item.destructive,
        ),
      );
    }
    return NativeBarAction(symbol: trigger, menu: rows);
  }

  /// What stopped it translating, for the log.
  String? untranslatable() {
    if (items.isEmpty) {
      return 'menu has no rows';
    }
    if (nativeSymbolFor(icon) == null) {
      return 'no symbol for the menu trigger $icon';
    }
    for (final item in items) {
      if (nativeSymbolFor(item.icon) == null) {
        return 'no symbol for menu row ${item.icon}';
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      consumeOutsideTap: true,
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(context.themeData.scaffoldBackgroundColor),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.grey),
        elevation: const WidgetStatePropertyAll(4),
        shape: const WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
        ),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 6)),
      ),
      menuChildren: [
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 150),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final item in items) ...[
                // The separator the album menu drew by hand, now implied by the
                // same flag that makes the row red.
                if (item.destructive && item != items.first) const Divider(height: 1),
                BaseActionButton(
                  label: item.label,
                  iconData: item.icon,
                  iconColor: item.destructive ? (context.isDarkTheme ? Colors.red[400] : Colors.red[800]) : null,
                  onPressed: item.onPressed,
                  menuItem: true,
                ),
              ],
            ],
          ),
        ),
      ],
      builder: (context, controller, child) => IconButton(
        tooltip: tooltip,
        icon: Icon(icon, color: iconColor, shadows: iconShadows),
        onPressed: () => controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }
}
