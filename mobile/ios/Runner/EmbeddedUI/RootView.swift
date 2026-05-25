import SwiftUI

struct RootView: View {
  @ObservedObject private var embedded = ImmichEmbeddedEngine.shared

  var body: some View {
    Group {
      if embedded.isFlutterReady {
        MainTabView()
      } else {
        VStack(spacing: 16) {
          ProgressView()
          Text("Starting Immich prototype")
            .font(.headline)
          if let lastError = embedded.lastError {
            Text(lastError)
              .font(.footnote.monospaced())
              .foregroundStyle(.red)
              .multilineTextAlignment(.center)
              .padding(.horizontal)
          }
        }
      }
    }
    .onAppear {
      _ = embedded.start()
    }
  }
}
