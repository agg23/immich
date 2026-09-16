import 'package:flutter/material.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/native_shell/native_icon.dart';
import 'package:immich_mobile/native_shell/native_shell.dart';
import 'package:immich_mobile/presentation/widgets/action_buttons/base_action_button.widget.dart';

class NativeBarMenuItem {
  const NativeBarMenuItem({required this.label, required this.icon, this.onPressed, this.destructive = false});

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool destructive;
}

class NativeBarMenu extends StatelessWidget {
  const NativeBarMenu({
    super.key,
    required this.icon,
    required this.items,
    this.iconColor,
    this.iconShadows,
    this.tooltip,
  });

  final IconData icon;
  final List<NativeBarMenuItem> items;

  final Color? iconColor;
  final List<Shadow>? iconShadows;
  final String? tooltip;

  NativeBarAction? describe() {
    final trigger = nativeIconFor(icon);
    if (trigger == null || items.isEmpty) {
      return null;
    }
    final rows = <NativeMenuItem>[];
    for (final item in items) {
      final token = nativeIconFor(item.icon);
      if (token == null) {
        return null;
      }
      rows.add(
        NativeMenuItem(label: item.label, icon: token, onPressed: item.onPressed, destructive: item.destructive),
      );
    }
    return NativeBarAction(icon: trigger, menu: rows);
  }

  String? untranslatable() {
    if (items.isEmpty) {
      return 'menu has no rows';
    }
    if (nativeIconFor(icon) == null) {
      return 'no icon token for the menu trigger $icon';
    }
    for (final item in items) {
      if (nativeIconFor(item.icon) == null) {
        return 'no icon token for menu row ${item.icon}';
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
