import Photos
import UIKit

/// Pixels for the native timeline and viewer.
///
/// Nothing new is plumbed here. Remote assets are fetched with
/// `URLSessionManager.shared.session`, which Immich has already configured
/// with the auth headers, the shared cookie store and a 1GiB `URLCache` —
/// `NetworkRepository.setHeaders` pushes the token into it from Dart on every
/// login. Local assets go through `PHImageManager`, which is what
/// `LocalImageApiImpl` already uses.
///
/// So the native grid is authenticated, cached and warm on the same terms as
/// the Flutter one, with no second credential path to keep in step.
final class ThumbnailLoader {
  static let shared = ThumbnailLoader()

  /// Decoded images, cost-limited in bytes. `URLCache` already holds the
  /// encoded bytes; this avoids re-decoding on every cell reuse.
  private let cache: NSCache<NSString, UIImage> = {
    let cache = NSCache<NSString, UIImage>()
    cache.totalCostLimit = 96 << 20
    return cache
  }()

  enum Token {
    case url(URLSessionDataTask)
    case photos(PHImageRequestID)

    func cancel() {
      switch self {
      case .url(let task): task.cancel()
      case .photos(let id): PHImageManager.default().cancelImageRequest(id)
      }
    }
  }

  func cached(_ asset: TimelineAsset, size: CGFloat) -> UIImage? {
    cache.object(forKey: Self.key(asset, size: size))
  }

  /// Loads at `size` points square. Returns a token to cancel with, or nil if
  /// the image was already cached or there is nothing to load.
  func load(_ asset: TimelineAsset, size: CGFloat, completion: @escaping (UIImage?) -> Void) -> Token? {
    let key = Self.key(asset, size: size)
    if let hit = cache.object(forKey: key) {
      completion(hit)
      return nil
    }
    let pixels = size * UIScreen.main.scale

    // Remote first. An asset that exists both places is the same picture, and
    // the server's thumbnail is already the right size, where the local one
    // has to be rendered from the original.
    if let url = asset.thumbURL {
      let task = URLSessionManager.shared.session.dataTask(with: url) { [weak self] data, _, _ in
        let image = data.flatMap { Self.downsample($0, to: pixels) }
        if let image { self?.store(image, for: key) }
        DispatchQueue.main.async { completion(image) }
      }
      task.resume()
      return .url(task)
    }

    guard let localId = asset.localId,
          let phAsset = PHAsset.fetchAssets(withLocalIdentifiers: [localId], options: nil).firstObject
    else {
      completion(nil)
      return nil
    }

    let options = PHImageRequestOptions()
    options.deliveryMode = .opportunistic
    options.resizeMode = .fast
    options.isNetworkAccessAllowed = false
    let id = PHImageManager.default().requestImage(
      for: phAsset,
      targetSize: CGSize(width: pixels, height: pixels),
      contentMode: .aspectFill,
      options: options
    ) { [weak self] image, info in
      // Opportunistic delivery calls back twice; only the full-quality result
      // is worth caching.
      let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
      if let image, !isDegraded { self?.store(image, for: key) }
      completion(image)
    }
    return .photos(id)
  }

  private func store(_ image: UIImage, for key: NSString) {
    guard let cgImage = image.cgImage else { return }
    cache.setObject(image, forKey: key, cost: cgImage.bytesPerRow * cgImage.height)
  }

  private static func key(_ asset: TimelineAsset, size: CGFloat) -> NSString {
    let id = asset.remoteId ?? asset.localId ?? asset.name
    return "\(id)@\(Int(size))" as NSString
  }

  /// Decode straight to the size the grid draws at, rather than decoding a
  /// full frame and letting the GPU scale it.
  private static func downsample(_ data: Data, to pixels: CGFloat) -> UIImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
    else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: pixels,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    return UIImage(cgImage: cgImage)
  }
}
