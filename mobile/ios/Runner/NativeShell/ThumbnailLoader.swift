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

  func cached(_ asset: TimelineAsset, size: CGFloat, hdr: Bool = false) -> UIImage? {
    cache.object(forKey: Self.key(asset, size: size, hdr: hdr))
  }

  /// Loads at `size` points square. Returns a token to cancel with, or nil if
  /// the image was already cached or there is nothing to load.
  /// `hdr` asks for a decode that keeps high dynamic range. Only the viewer
  /// wants it: a grid tile is small, SDR is what it would be tone-mapped to
  /// anyway, and an HDR frame costs more memory per tile at a size where
  /// nobody can see the difference.
  func load(
    _ asset: TimelineAsset,
    size: CGFloat,
    hdr: Bool = false,
    completion: @escaping (UIImage?) -> Void
  ) -> Token? {
    let key = Self.key(asset, size: size, hdr: hdr)
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
        let image = data.flatMap { Self.decode($0, to: pixels, hdr: hdr) }
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

  private static func key(_ asset: TimelineAsset, size: CGFloat, hdr: Bool) -> NSString {
    let id = asset.remoteId ?? asset.localId ?? asset.name
    // The two decodes of one asset are different pictures, so they cannot
    // share a cache entry: the grid must not be handed the viewer's HDR frame,
    // and the viewer must not be handed the grid's flattened one.
    return "\(id)@\(Int(size))\(hdr ? "h" : "")" as NSString
  }

  /// Answer, for real assets on a real device, *where* the dynamic range is
  /// being lost. Three decodes of the same photo:
  ///
  ///   preview/thumb  - what the viewer does today
  ///   preview/full   - the same bytes without `preferredThumbnailSize`
  ///   original/full  - the untouched upload
  ///
  /// preview/full yes and preview/thumb no means thumbnailing drops the gain
  /// map. Both preview rows no with original yes means the server's re-encode
  /// drops it and a viewer has to fetch originals. All three no, across several
  /// assets, means these photos are not HDR and the test is invalid — which is
  /// why this walks a handful rather than trusting asset 0.
  @available(iOS 17.0, *)
  func probeHDR(_ assets: [TimelineAsset]) {
    for asset in assets {
      for (label, url) in [("preview", asset.previewURL), ("original", asset.originalURL)] {
        guard let url else { continue }
        URLSessionManager.shared.session.dataTask(with: url) { data, _, _ in
          guard let data else {
            NSLog("[shell:probe] %@ %@ fetch failed", asset.name, label)
            return
          }
          var thumbConfig = UIImageReader.Configuration()
          thumbConfig.prefersHighDynamicRange = true
          thumbConfig.preferredThumbnailSize = CGSize(width: 1206, height: 1206)
          var fullConfig = UIImageReader.Configuration()
          fullConfig.prefersHighDynamicRange = true
          let thumbed = UIImageReader(configuration: thumbConfig).image(data: data)
          let full = UIImageReader(configuration: fullConfig).image(data: data)
          NSLog(
            "[shell:probe] %@ %@ bytes=%d thumb=%@ full=%@",
            asset.name,
            label,
            data.count,
            thumbed?.isHighDynamicRange == true ? "HDR" : "sdr",
            full?.isHighDynamicRange == true ? "HDR" : "sdr"
          )
        }.resume()
      }
    }
  }

  private static func decode(_ data: Data, to pixels: CGFloat, hdr: Bool) -> UIImage? {
    if hdr, #available(iOS 17.0, *) {
      if let image = decodeHDR(data, to: pixels) {
        return image
      }
      // Falling through is deliberate: a decode that could not keep the range
      // is still a picture, and a blank page is worse than a flat one.
      shellLog("[shell:hdr] hdr decode failed, falling back to sdr")
    }
    return downsample(data, to: pixels)
  }

  /// A decode that keeps the gain map, which the grid's does not.
  ///
  /// `CGImageSourceCreateThumbnailAtIndex` returns a plain SDR frame — a
  /// thumbnail does not carry the auxiliary gain map, and `UIImage(cgImage:)`
  /// has nowhere to put one. `UIImageReader` is the decode that keeps it, and
  /// it still thumbnails, so a page does not cost a full-resolution frame.
  ///
  /// iOS 17 for now. HDR *video* has been public since iOS 11 and still images
  /// can be presented through a Metal layer from 16, so this floor is the
  /// convenience of the UIKit path rather than a limit of the platform; it is
  /// the thing to revisit if the deployment floor matters more than the code.
  @available(iOS 17.0, *)
  private static func decodeHDR(_ data: Data, to pixels: CGFloat) -> UIImage? {
    var config = UIImageReader.Configuration()
    config.prefersHighDynamicRange = true
    // Decoded off the main thread here, which is where this already runs.
    config.preparesImagesForDisplay = true
    config.preferredThumbnailSize = CGSize(width: pixels, height: pixels)
    let image = UIImageReader(configuration: config).image(data: data)
    if let image {
      // The one measurement that says whether any of this worked. If a real
      // photo reports false, the question is whether the *source* carried a
      // gain map at all — Immich's server re-encodes previews — and not
      // whether this decode asked for one.
      shellLog("[shell:hdr] decoded %.0fpx hdr=%@", pixels, image.isHighDynamicRange ? "yes" : "NO")
    }
    return image
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
