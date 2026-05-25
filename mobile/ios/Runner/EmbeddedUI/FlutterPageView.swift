import Flutter
import SwiftUI

struct FlutterPageView: UIViewControllerRepresentable {
  let routeName: String

  func makeUIViewController(context: Context) -> LoggingFlutterViewController {
    NSLog("[EmbeddedUI] makeUIViewController route=\(routeName)")
    let controller = LoggingFlutterViewController(
      engine: ImmichEmbeddedEngine.shared.engine,
      nibName: nil,
      bundle: nil
    )
    controller.embeddedRouteName = routeName
    return controller
  }

  func updateUIViewController(_ uiViewController: LoggingFlutterViewController, context: Context) {
    NSLog("[EmbeddedUI] updateUIViewController route=\(routeName)")
    uiViewController.embeddedRouteName = routeName
    ImmichEmbeddedEngine.shared.setEmbeddedMode(hideChrome: true)
  }

  static func dismantleUIViewController(_ uiViewController: LoggingFlutterViewController, coordinator: ()) {
    NSLog("[EmbeddedUI] dismantleUIViewController route=\(uiViewController.embeddedRouteName ?? "<nil>")")
  }
}

final class LoggingFlutterViewController: FlutterViewController {
  var embeddedRouteName: String?

  override func viewDidLoad() {
    super.viewDidLoad()
    NSLog("[EmbeddedUI] FVC viewDidLoad route=\(embeddedRouteName ?? "<nil>")")
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    NSLog("[EmbeddedUI] FVC viewWillAppear route=\(embeddedRouteName ?? "<nil>") animated=\(animated)")
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    NSLog("[EmbeddedUI] FVC viewDidAppear route=\(embeddedRouteName ?? "<nil>") animated=\(animated)")
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    NSLog("[EmbeddedUI] FVC viewWillDisappear route=\(embeddedRouteName ?? "<nil>") animated=\(animated)")
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    NSLog("[EmbeddedUI] FVC viewDidDisappear route=\(embeddedRouteName ?? "<nil>") animated=\(animated)")
  }

  deinit {
    NSLog("[EmbeddedUI] FVC deinit route=\(embeddedRouteName ?? "<nil>")")
  }
}
