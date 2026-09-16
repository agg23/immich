import UIKit

/// The only place that knows what Dart's icon tokens look like on iOS.
enum ShellIcon: String {
  case add
  case addPhoto
  case addUser
  case albums
  case close
  case comment
  case delete
  case deleteForever
  case edit
  case favorite
  case favoriteFilled
  case library
  case link
  case overflow
  case pause
  case photos
  case play
  case removeUser
  case restore
  case search
  case searchDescription
  case searchFilename
  case searchOcr
  case searchSmart
  case settings
  case slideshow
  case sort

  var systemName: String {
    switch self {
    case .add: "plus"
    case .addPhoto: "photo.badge.plus"
    case .addUser: "person.badge.plus"
    case .albums: "rectangle.stack"
    case .close: "xmark"
    case .comment: "bubble.left"
    case .delete: "trash"
    case .deleteForever: "trash.slash"
    case .edit: "pencil"
    case .favorite: "heart"
    case .favoriteFilled: "heart.fill"
    case .library: "square.grid.2x2"
    case .link: "link"
    case .overflow: "ellipsis"
    case .pause: "pause.fill"
    case .photos: "photo.on.rectangle"
    case .play: "play.fill"
    case .removeUser: "person.badge.minus"
    case .restore: "arrow.uturn.backward"
    case .search: "magnifyingglass"
    case .searchDescription: "text.alignleft"
    case .searchFilename: "textformat.abc"
    case .searchOcr: "doc.viewfinder"
    case .searchSmart: "sparkle.magnifyingglass"
    case .settings: "gearshape"
    case .slideshow: "play.rectangle"
    case .sort: "arrow.up.arrow.down"
    }
  }

  var image: UIImage? { UIImage(systemName: systemName) }

  /// Dart may be newer than the app it is talking to, so an unknown token is
  /// expected rather than exceptional.
  static func image(for token: Any?) -> UIImage? {
    guard let raw = token as? String else { return nil }
    guard let icon = ShellIcon(rawValue: raw) else {
      shellLog("[shell:nav] unknown icon token %@", raw)
      return nil
    }
    return icon.image
  }
}
