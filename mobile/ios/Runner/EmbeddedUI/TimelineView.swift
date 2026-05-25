import SwiftUI
import UIKit

struct NativeTimelineView: View {
  @StateObject private var viewModel = TimelineViewModel()
  let openSettings: () -> Void
  let openLogin: () -> Void

  private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

  var body: some View {
    Group {
      if let errorMessage = viewModel.errorMessage {
        TimelineErrorView(message: errorMessage, openLogin: openLogin)
      } else if viewModel.assets.isEmpty && viewModel.isLoading {
        ProgressView("Loading timeline")
      } else if viewModel.assets.isEmpty {
        TimelineEmptyView()
      } else {
        ScrollView {
          LazyVGrid(columns: columns, spacing: 2) {
            ForEach(viewModel.assets) { asset in
              TimelineThumbnailCell(asset: asset)
                .task {
                  await viewModel.loadMoreIfNeeded(currentAsset: asset)
                }
            }
          }
          .padding(.horizontal, 2)
        }
        .refreshable {
          await viewModel.reload()
        }
      }
    }
    .navigationTitle("Immich")
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button(action: openSettings) {
          Image(systemName: "gearshape")
        }
      }
    }
    .task {
      await viewModel.loadInitial()
    }
  }
}

private struct TimelineEmptyView: View {
  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "photo.on.rectangle.angled")
        .font(.system(size: 36))
        .foregroundStyle(.secondary)
      Text("No timeline assets")
        .font(.headline)
      Text("The native timeline loaded successfully, but Dart returned no assets.")
        .font(.footnote)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct TimelineErrorView: View {
  let message: String
  let openLogin: () -> Void

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "exclamationmark.triangle")
        .font(.system(size: 36))
        .foregroundStyle(.secondary)
      Text("Unable to load timeline")
        .font(.headline)
      Text(message)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal)
      if message.contains("embedded-timeline-auth-unavailable") {
        Button("Log in with Flutter", action: openLogin)
          .buttonStyle(.borderedProminent)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

@MainActor
final class TimelineViewModel: ObservableObject {
  @Published private(set) var assets: [TimelineAssetViewData] = []
  @Published private(set) var isLoading = false
  @Published private(set) var errorMessage: String?

  private let api = ImmichEmbeddedEngine.shared.timelineApi
  private var totalCount = 0
  private var nextOffset = 0
  private let pageSize: Int64 = 90

  func loadInitial() async {
    guard assets.isEmpty, !isLoading else { return }
    await reload()
  }

  func reload() async {
    isLoading = true
    errorMessage = nil
    assets = []
    nextOffset = 0
    do {
      let buckets = try await loadBuckets()
      totalCount = buckets.reduce(0) { $0 + Int($1.count) }
      NSLog("[EmbeddedUI] Native timeline loaded buckets=\(buckets.count) totalAssets=\(totalCount)")
      try await loadNextPage()
    } catch {
      let message = describeTimelineError(error)
      NSLog("[EmbeddedUI] Native timeline reload failed: \(message)")
      errorMessage = message
    }
    isLoading = false
  }

  func loadMoreIfNeeded(currentAsset: TimelineAssetViewData) async {
    guard currentAsset.id == assets.last?.id else { return }
    guard !isLoading, nextOffset < totalCount else { return }
    isLoading = true
    defer { isLoading = false }
    do {
      try await loadNextPage()
    } catch {
      let message = describeTimelineError(error)
      NSLog("[EmbeddedUI] Native timeline pagination failed: \(message)")
      errorMessage = message
    }
  }

  private func loadNextPage() async throws {
    guard nextOffset < totalCount else { return }
    let count = min(Int(pageSize), totalCount - nextOffset)
    let metas = try await loadAssets(offset: Int64(nextOffset), count: Int64(count))
    NSLog("[EmbeddedUI] Native timeline loaded assets offset=\(nextOffset) requested=\(count) returned=\(metas.count)")
    assets.append(contentsOf: metas.map(TimelineAssetViewData.init(meta:)))
    nextOffset += metas.count
  }

  private func loadBuckets() async throws -> [TimelineBucket] {
    try await withCheckedThrowingContinuation { continuation in
      api.loadBuckets { result in
        continuation.resume(with: result)
      }
    }
  }

  private func loadAssets(offset: Int64, count: Int64) async throws -> [AssetMeta] {
    try await withCheckedThrowingContinuation { continuation in
      api.loadAssets(offset: offset, count: count) { result in
        continuation.resume(with: result)
      }
    }
  }
}

private func describeTimelineError(_ error: Error) -> String {
  if let pigeonError = error as? PigeonError {
    return "PigeonError(code: \(pigeonError.code), message: \(pigeonError.message ?? "<nil>"), details: \(String(describing: pigeonError.details)))"
  }
  return String(describing: error)
}

struct TimelineAssetViewData: Identifiable, Equatable {
  let id: String
  let remoteId: String?
  let localId: String?
  let createdAt: Date
  let isFavorite: Bool
  let isVideo: Bool
  let isEdited: Bool
  let thumbhash: String?

  init(meta: AssetMeta) {
    id = meta.id
    remoteId = meta.remoteId
    localId = meta.localId
    createdAt = Date(timeIntervalSince1970: TimeInterval(meta.createdAtEpochMilliseconds) / 1000)
    isFavorite = meta.isFavorite
    isVideo = meta.isVideo
    isEdited = meta.isEdited
    thumbhash = meta.thumbhash
  }
}

private struct TimelineThumbnailCell: View {
  let asset: TimelineAssetViewData

  var body: some View {
    ZStack(alignment: .topTrailing) {
      TimelineThumbnailImage(asset: asset)
        .aspectRatio(1, contentMode: .fill)
        .frame(maxWidth: .infinity)
        .clipped()
        .background(Color.gray.opacity(0.2))

      if asset.isVideo {
        Image(systemName: "play.fill")
          .font(.caption)
          .foregroundStyle(.white)
          .shadow(radius: 2)
          .padding(6)
      }
    }
    .aspectRatio(1, contentMode: .fit)
  }
}

private struct TimelineThumbnailImage: View {
  let asset: TimelineAssetViewData
  @State private var image: UIImage?
  @State private var didFail = false

  var body: some View {
    Group {
      if let image {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
      } else if didFail || asset.remoteId == nil {
        Image(systemName: asset.isVideo ? "video" : "photo")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        Rectangle()
          .fill(Color.gray.opacity(0.15))
          .overlay(ProgressView().controlSize(.mini))
      }
    }
    .task(id: asset.id) {
      await loadImage()
    }
  }

  private func loadImage() async {
    guard image == nil, let remoteId = asset.remoteId else { return }
    do {
      let urlString = try await thumbnailUrl(remoteId: remoteId)
      guard let url = URL(string: urlString) else {
        NSLog("[EmbeddedUI] Native timeline invalid thumbnail URL for asset=\(asset.id): \(urlString)")
        didFail = true
        return
      }
      var request = URLRequest(url: url)
      request.cachePolicy = .returnCacheDataElseLoad
      let (data, _) = try await URLSessionManager.shared.session.data(for: request)
      image = UIImage(data: data)
      didFail = image == nil
      if didFail {
        NSLog("[EmbeddedUI] Native timeline could not decode thumbnail asset=\(asset.id) bytes=\(data.count)")
      }
    } catch {
      NSLog("[EmbeddedUI] Native timeline thumbnail load failed asset=\(asset.id): \(describeTimelineError(error))")
      didFail = true
    }
  }

  private func thumbnailUrl(remoteId: String) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
      ImmichEmbeddedEngine.shared.timelineApi.thumbnailUrl(assetId: remoteId, thumbhash: asset.thumbhash, edited: asset.isEdited) { result in
        continuation.resume(with: result)
      }
    }
  }
}
