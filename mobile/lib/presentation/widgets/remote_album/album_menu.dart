import 'package:flutter/material.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/native_shell/native_bar_menu.dart';

List<NativeBarMenuItem> remoteAlbumMenuItems(
  BuildContext context, {
  VoidCallback? onEditAlbum,
  VoidCallback? onAddPhotos,
  VoidCallback? onAddUsers,
  VoidCallback? onLeaveAlbum,
  VoidCallback? onToggleAlbumOrder,
  VoidCallback? onCreateSharedLink,
  VoidCallback? onShowOptions,
  VoidCallback? onDeleteAlbum,
}) => [
  if (onEditAlbum != null) NativeBarMenuItem(label: context.t.edit_album, icon: Icons.edit, onPressed: onEditAlbum),
  if (onAddPhotos != null)
    NativeBarMenuItem(label: context.t.add_photos, icon: Icons.add_a_photo, onPressed: onAddPhotos),
  if (onAddUsers != null)
    NativeBarMenuItem(label: context.t.album_viewer_page_share_add_users, icon: Icons.group_add, onPressed: onAddUsers),
  if (onLeaveAlbum != null)
    NativeBarMenuItem(label: context.t.leave_album, icon: Icons.person_remove_rounded, onPressed: onLeaveAlbum),
  if (onToggleAlbumOrder != null)
    NativeBarMenuItem(
      label: context.t.change_display_order,
      icon: Icons.swap_vert_rounded,
      onPressed: onToggleAlbumOrder,
    ),
  if (onCreateSharedLink != null)
    NativeBarMenuItem(label: context.t.create_shared_link, icon: Icons.link, onPressed: onCreateSharedLink),
  if (onShowOptions != null)
    NativeBarMenuItem(label: context.t.options, icon: Icons.settings, onPressed: onShowOptions),
  if (onDeleteAlbum != null)
    NativeBarMenuItem(label: context.t.delete_album, icon: Icons.delete, onPressed: onDeleteAlbum, destructive: true),
];
