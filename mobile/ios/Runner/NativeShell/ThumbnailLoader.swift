import Photos
import UIKit

final class ThumbnailLoader {
  static let shared = ThumbnailLoader()

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
    // The two decodes are different pictures and cannot share a cache entry.
    return "\(id)@\(Int(size))\(hdr ? "h" : "")" as NSString
  }

  @available(iOS 17.0, *)
  func probeHDR(_ assets: [TimelineAsset]) {
    for asset in assets {
      for (label, url) in [("preview", asset.previewURL), ("original", asset.originalURL)] {
        guard let url else { continue }
        URLSessionManager.shared.session.dataTask(with: url) { data, _, _ in
          guard let data else {
            shellLog("[shell:probe] %@ %@ fetch failed", asset.name, label)
            return
          }
          var thumbConfig = UIImageReader.Configuration()
          thumbConfig.prefersHighDynamicRange = true
          thumbConfig.preferredThumbnailSize = CGSize(width: 1206, height: 1206)
          var fullConfig = UIImageReader.Configuration()
          fullConfig.prefersHighDynamicRange = true
          let thumbed = UIImageReader(configuration: thumbConfig).image(data: data)
          let full = UIImageReader(configuration: fullConfig).image(data: data)
          shellLog(
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
      shellLog("[shell:hdr] hdr decode failed, falling back to sdr")
    }
    return downsample(data, to: pixels)
  }

  @available(iOS 17.0, *)
  private static func decodeHDR(_ data: Data, to pixels: CGFloat) -> UIImage? {
    var config = UIImageReader.Configuration()
    config.prefersHighDynamicRange = true
    config.preparesImagesForDisplay = true
    config.preferredThumbnailSize = CGSize(width: pixels, height: pixels)
    let image = UIImageReader(configuration: config).image(data: data)
    if let image {
      shellLog("[shell:hdr] decoded %.0fpx hdr=%@", pixels, image.isHighDynamicRange ? "yes" : "NO")
    }
    return image
  }

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
