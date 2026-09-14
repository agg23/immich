import 'package:flutter/material.dart';

final _symbols = <IconData, String>{
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

String? nativeSymbolFor(IconData? icon) => icon == null ? null : _symbols[icon];
