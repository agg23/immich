# Hybrid Shell — Channel Contract

The interface between Dart and whatever native shell is hosting it. This is what an
Android implementation is written against; until now it existed only as matching `switch`
statements in two languages.

Two channels, both `MethodChannel` with the standard codec:

| channel | owns |
|---|---|
| `immich/shell` | tabs, navigation stack mirroring, bars, insets, surface handoff |
| `immich/timeline` | timeline sections and asset windows |

Dart's half is `lib/native_shell/`; the reference implementation of the native half is
`mobile/ios/Runner/NativeShell/`.

## Rule

Dart owns what the data means. Native owns what the pixels do. The test for any given
piece of logic: would Android answer this question differently? If yes it is presentation
and stays native; if no it belongs in Dart, written once.

Consequences visible in this contract: icons are semantic tokens, not SF Symbols; tabs are
declared by Dart including their localised labels; timeline section offsets and page size
arrive precomputed; a window is complete or it is not sent.

## Activation

`NativeShell.isActive` gates every call on the Dart side. It is currently
`Platform.isIOS` and is the single line an Android port flips. When false, Dart draws its
own chrome and neither channel is used.

---

# `immich/shell`

## Dart → native

### `ready`
Sent once per attach, **before `auth`**. Native must not build its tab bar until it
arrives.

```
{ tabs: [ { id: String, label: String, icon: String } ] }
```

`id` is the tab's identity on this channel. Order is identity too — index *n* means the
same tab on both sides. `label` is already localised; native must not substitute its own.
`icon` is a token (see [Icon tokens](#icon-tokens)).

### `auth`
```
{ signedIn: Bool }
```
Native swaps its root between a launch surface and the shell. Sent after `ready`.

### `sync`
The mirrored navigation stack. Sent on every route change, tab change, and bar republish.

```
{
  routes: [ { name: String, title: String?, actions: [Action], hero: Bool } ],
  surface: String,      // route name, or tab id when the stack is empty
  overlay: Bool,        // a non-opaque Flutter route is on top
  tab: String,          // active tab id
  claimTab: Bool,       // Dart moved tabs and native should follow
}
```

`routes` excludes routes the native shell draws itself — the pre-auth roots, the tab
shell, each tab's container and root. Dart derives that set from the tab list
(`nativeShellRoutes`); native never needs the concept.

`claimTab` distinguishes "Dart changed tabs" from "Dart is reporting the tab native
already selected". Without it a sync crossing a tab tap reverses the tap.

`overlay` is true while a non-opaque Flutter route is on top. Native should hide its bar
and disable the interactive pop gesture, or both transitions play at once.

Native reconciles its stack against `routes` by common prefix: push when exactly one frame
was added, animate a removal when frames were only removed, otherwise replace without
animation.

### `barCollapsed`
```
{ route: String, collapsed: Bool }
```
A threshold, not a stream. A hero bar starts transparent over a cover photo; Dart reports
only the crossing and native animates the change.

### `openViewer`
```
{ session: Int, index: Int }
```
Dart declines its own `AssetViewerRoute` (via `NativeViewerGuard`) and asks for the native
viewer instead, so nothing is added to Dart's stack for `sync` to mirror.

### `log`
```
{ text: String }
```
Suppressed in release builds.

## Native → Dart

### `show` → `{ surface: String }`
```
{ route: String? }
```
A tab id selects that tab; `null` or `""` asks only where Dart currently is. Dart replies
after two rendered frames with the surface it settled on. Native uses this to decide when
to reveal the Flutter view.

### `popFromNative`
```
{ name: String? }
```
A native back gesture or bar button popped a frame. Dart pops the matching route if its
top still matches `name`, and otherwise re-syncs rather than guessing.

### `popToRoot`
```
{ tab: String }
```
The selected tab was tapped again.

### `barAction`
```
{ route: String, index: Int, item: Int }   // item < 0 for a plain action
```
Resolved against the bar Dart last published for `route`. A tap on a bar that has since
changed fires nothing and triggers a re-sync.

### `insets`
```
{ top: Double, bottom: Double, left: Double, right: Double }
```
Native safe-area insets, which Dart injects as `MediaQuery` padding. Necessary because the
Flutter view sits inside a native container whose chrome Flutter cannot see.

### `resync`
No arguments. Native lost or rebuilt its stack and wants a forced `sync`.

### `capture` → `Uint8List?`
No arguments. A PNG of the current Flutter surface, used as a still while the engine
re-attaches to a different container.

---

# `immich/timeline`

Timelines are numbered *sessions*; session `0` is the main timeline. Others are opened
when a screen with its own timeline (an album, a search) hands one over.

## Dart → native

### `invalidate`
```
{
  session: Int,
  generation: Int,       // increments on every invalidation
  total: Int,
  pageSize: Int,
  sections: [ { offset: Int, count: Int, date: Int? } ],   // date = epoch ms
}
```

Sections arrive with `offset` precomputed and empty buckets already dropped — an empty
section would share an offset with the next and make the reverse lookup ambiguous.
`pageSize` is declared here so both platforms page identically.

**Dart only sends this once it can serve every index the sections claim.** `TimelineService`
reloads its buffer on the same stream the buckets come from and raises its own total only
afterwards, so sections published on arrival name assets that cannot yet be fetched. Native
therefore does not need to retry, and must not assume it should.

On receipt, native discards its cached assets and reloads visible cells.

### Debug methods
`debugOpenViewer`, `debugPushAlbum` — see [Debug](#debug).

## Native → Dart

### `window` → window
```
{ session: Int, start: Int, count: Int }
```
returns
```
{ session: Int, generation: Int, start: Int, assets: [Asset] }
```

The request is a viewport-sized range; Dart clamps it to what the timeline holds, so a
short answer near the end is correct. The reply carries the generation it was served from,
and `-1` if an invalidation landed while the load was in flight. **Native must drop any
window whose generation is not the current one** — it describes indices that have moved.

### `open`
```
{ session: Int }
```
Native is about to display this session and wants an `invalidate`. A signal, not a query: a
reply would carry state as of the call.

### `closeSession`
```
{ session: Int }
```
Session `0` is ignored.

---

# Shared types

### Action
```
{ icon: String?, label: String?, enabled: Bool, menu: [MenuItem]? }
```
One of `icon` or `label` is present — `icon` for a translated `IconButton`, `label` for a
`TextButton`. With a `menu`, the platform opens it and the action itself never fires.

### MenuItem
```
{ label: String, icon: String?, enabled: Bool, destructive: Bool? }
```
Destructive rows are grouped separately by the platform.

### Asset
```
{
  name: String, localId: String?, remoteId: String?,
  isVideo: Bool, durationMs: Int?, createdAt: Int,   // epoch ms
  isFavorite: Bool,
  thumbUrl: String?, previewUrl: String?, originalUrl: String?,
}
```
URLs are present only for assets with a `remoteId`.

### Icon tokens

Dart names meanings; each platform maps them to its own artwork. Defined by `NativeIcon`
in `lib/native_shell/native_icon.dart`; iOS resolves them in `ShellIcon.swift`.

```
add  addPhoto  addUser  albums  close  comment  delete  deleteForever
edit  favorite  favoriteFilled  library  link  overflow  pause  photos
play  removeUser  restore  search  settings  slideshow  sort
```

An unknown token must log and draw nothing rather than guess — Dart may be newer than the
native side it is talking to. Dart falls back to drawing the whole bar itself if any one
action in it has no token, so a missing token degrades a screen rather than breaking it.

---

# Ordering guarantees

| | |
|---|---|
| `ready` precedes `auth` | the tab bar is built from `ready` |
| `sync` may arrive before native has a stack | native re-requests with `resync` |
| `show` is answered after two rendered frames | one is not enough for a settled layout |
| `window` replies may arrive out of order | each is stamped with its generation |
| `invalidate` invalidates in-flight windows | compare generation, drop mismatches |

---

# Debug

`debugPush`, `debugPop`, `debugTab` on `immich/shell`; `debugOpenViewer`, `debugPushAlbum`
on `immich/timeline`. Driven by `-immichShell…` launch arguments.

Dart answers nothing in release builds; iOS compiles its half only under `SHELL_DEBUG`
(Debug and Profile, never Release). An Android port can skip this entirely at first.

---

# Notes for an Android implementation

The native half is ~2,100 lines of Kotlin, almost all of it presentation. Nothing in this
contract is shared code — it is a shared *contract*, and the logic behind it is what does
not need writing twice.

| piece | Android |
|---|---|
| Engine hosting, stack, tabs, bars | `FlutterEngine` + fragments; same logic as `ShellEngine`/`ShellBridge`/`FlutterStackController` |
| Timeline grid | `RecyclerView`; sections and offsets arrive ready |
| Asset viewer | `ViewPager2` |
| Thumbnails | Coil or Glide in place of `ThumbnailLoader` |
| Zoom transition | shared-element transition |

The native grid and viewer are **not** optional on Android: Flutter cannot render HDR
there either, which was the original motivation on iOS.

One piece deliberately stays per-platform: reconciling the native stack against `routes`.
It is ~50 lines and the UIKit distinction it encodes (`pushViewController` versus
`setViewControllers`) has no Android analogue worth generalising.
