import 'package:flutter/material.dart';

/// Material icons to SF Symbols, for the icons Immich actually puts in an app
/// bar or an app bar's menu.
///
/// An icon that is not here makes its page fall back rather than guessing a
/// symbol, so the table can stay honest and short. It lives on its own because
/// both halves of a bar need it: the buttons, which are widgets [NativeAppBar]
/// reads, and the menu rows, which are data a [NativeBarMenu] declares.
final _symbols = <IconData, String>{
  // Bar buttons.
  Icons.search: 'magnifyingglass',
  Icons.close: 'xmark',
  Icons.add_rounded: 'plus',
  Icons.add_outlined: 'plus',
  Icons.favorite: 'heart.fill',
  Icons.favorite_outline: 'heart',
  Icons.delete_outline_rounded: 'trash',
  Icons.settings_outlined: 'gearshape',
  Icons.swap_vert: 'arrow.up.arrow.down',
  Icons.play_arrow: 'play.fill',
  Icons.pause: 'pause.fill',
  Icons.more_vert_rounded: 'ellipsis',
  Icons.more_vert: 'ellipsis',
  Icons.slideshow_outlined: 'play.rectangle',
  Icons.chat_outlined: 'bubble.left',
  // Menu rows.
  Icons.delete_forever_outlined: 'trash.slash',
  Icons.restore_outlined: 'arrow.uturn.backward',
  Icons.edit: 'pencil',
  Icons.add_a_photo: 'photo.badge.plus',
  Icons.group_add: 'person.badge.plus',
  Icons.person_remove_rounded: 'person.badge.minus',
  Icons.swap_vert_rounded: 'arrow.up.arrow.down',
  Icons.link: 'link',
  Icons.settings: 'gearshape',
  Icons.delete: 'trash',
};

/// The SF Symbol for [icon], or null if there is no honest answer.
String? nativeSymbolFor(IconData? icon) => icon == null ? null : _symbols[icon];
