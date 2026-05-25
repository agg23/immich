import SwiftUI

private enum EmbeddedDestination: Hashable {
  case settings
  case login
}

struct MainTabView: View {
  @ObservedObject private var embeddedEngine = ImmichEmbeddedEngine.shared
  @State private var path: [EmbeddedDestination] = []
  @State private var selectedTab = 0
  @State private var isOpeningSettings = false

  var body: some View {
    TabView(selection: $selectedTab) {
      NavigationStack(path: $path) {
        NativeTimelineView(openSettings: openSettings, openLogin: openLogin)
          .id(embeddedEngine.isAuthenticated)
          .navigationDestination(for: EmbeddedDestination.self) { destination in
            switch destination {
            case .settings:
              EmbeddedSettingsView(path: $path)
            case .login:
              EmbeddedLoginView(path: $path)
            }
          }
      }
      .tabItem {
        Label("Photos", systemImage: "photo.on.rectangle")
      }
      .tag(0)

      NavigationStack {
        PlaceholderTab(title: "Search")
          .navigationTitle("Search")
      }
      .tabItem {
        Label("Search", systemImage: "magnifyingglass")
      }
      .tag(1)

      NavigationStack {
        PlaceholderTab(title: "Albums")
          .navigationTitle("Albums")
      }
      .tabItem {
        Label("Albums", systemImage: "square.stack")
      }
      .tag(2)

      NavigationStack {
        PlaceholderTab(title: "Library")
          .navigationTitle("Library")
      }
      .tabItem {
        Label("Library", systemImage: "rectangle.stack.person.crop")
      }
      .tag(3)
    }
    .onAppear {
      embeddedEngine.requestNativePop = popNativeDestination
      embeddedEngine.didAuthenticate = handleEmbeddedAuthentication
    }
    .onDisappear {
      embeddedEngine.requestNativePop = nil
      embeddedEngine.didAuthenticate = nil
    }
  }

  private func openSettings() {
    guard !isOpeningSettings else { return }
    isOpeningSettings = true
    embeddedEngine.setEmbeddedMode(hideChrome: true)
    embeddedEngine.navigate(to: "/settings") { didNavigate in
      isOpeningSettings = false
      if didNavigate, path.last != .settings {
        path.append(.settings)
      }
    }
  }

  private func openLogin() {
    guard path.last != .login else { return }
    embeddedEngine.setEmbeddedMode(hideChrome: true)
    embeddedEngine.navigate(to: "/login") { didNavigate in
      if didNavigate, path.last != .login {
        path.append(.login)
      }
    }
  }

  private func popNativeDestination() {
    if path.last != nil {
      path.removeLast()
    }
  }

  private func handleEmbeddedAuthentication() {
    if path.last == .login {
      path.removeLast()
    }
  }
}

private struct EmbeddedLoginView: View {
  @ObservedObject private var embeddedEngine = ImmichEmbeddedEngine.shared
  @Binding var path: [EmbeddedDestination]
  @State private var isHandlingBack = false

  var body: some View {
    FlutterPageView(routeName: "/login")
      .navigationTitle(embeddedEngine.embeddedTitle.isEmpty ? "Log In" : embeddedEngine.embeddedTitle)
      .navigationBarTitleDisplayMode(.inline)
      .navigationBarBackButtonHidden(true)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button(action: handleBack) {
            HStack(spacing: 4) {
              Image(systemName: "chevron.left")
              Text("Back")
            }
          }
          .disabled(isHandlingBack)
        }
      }
      .interactiveDismissDisabled(embeddedEngine.embeddedCanPop)
      .background(InteractivePopPolicyView(isEnabled: !embeddedEngine.embeddedCanPop))
  }

  private func handleBack() {
    guard !isHandlingBack else { return }
    isHandlingBack = true
    embeddedEngine.maybePop { didPop in
      isHandlingBack = false
      if !didPop, path.last == .login {
        path.removeLast()
      }
    }
  }
}

private struct EmbeddedSettingsView: View {
  @ObservedObject private var embeddedEngine = ImmichEmbeddedEngine.shared
  @Binding var path: [EmbeddedDestination]
  @State private var isHandlingBack = false

  var body: some View {
    FlutterPageView(routeName: "/settings")
      .navigationTitle(embeddedEngine.embeddedTitle)
      .navigationBarTitleDisplayMode(.inline)
      .navigationBarBackButtonHidden(true)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button(action: handleBack) {
            HStack(spacing: 4) {
              Image(systemName: "chevron.left")
              Text("Back")
            }
          }
          .disabled(isHandlingBack)
        }
      }
      .interactiveDismissDisabled(embeddedEngine.embeddedCanPop)
      .background(InteractivePopPolicyView(isEnabled: !embeddedEngine.embeddedCanPop))
  }

  private func handleBack() {
    guard !isHandlingBack else { return }
    isHandlingBack = true
    embeddedEngine.maybePop { didPop in
      isHandlingBack = false
      if !didPop, path.last == .settings {
        path.removeLast()
      }
    }
  }
}

private struct InteractivePopPolicyView: UIViewControllerRepresentable {
  let isEnabled: Bool

  func makeUIViewController(context: Context) -> UIViewController {
    UIViewController()
  }

  func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
    DispatchQueue.main.async {
      uiViewController.navigationController?.interactivePopGestureRecognizer?.isEnabled = isEnabled
    }
  }

  static func dismantleUIViewController(_ uiViewController: UIViewController, coordinator: ()) {
    uiViewController.navigationController?.interactivePopGestureRecognizer?.isEnabled = true
  }
}

private struct PlaceholderTab: View {
  let title: String

  var body: some View {
    VStack(spacing: 12) {
      Text(title)
        .font(.headline)
      Text("Placeholder until the single embedded destination gate is green.")
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
