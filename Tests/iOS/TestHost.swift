import UIKit
import SwiftUI
import BugKit

// UIApplication dispatches UIControl target actions; a hostless logic-test runner cannot exercise them.
@main
final class DiagnosticsAppDelegate: UIResponder, UIApplicationDelegate {
  func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                   options: UIScene.ConnectionOptions) -> UISceneConfiguration {
    let configuration = UISceneConfiguration(name: "Diagnostics", sessionRole: session.role)
    configuration.delegateClass = DiagnosticsSceneDelegate.self
    return configuration
  }
}

final class DiagnosticsSceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?

  func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
    guard let scene = scene as? UIWindowScene else { return }
    let window = UIWindow(windowScene: scene)
    if CommandLine.arguments.contains("--whats-new-test") {
      window.rootViewController = UIHostingController(rootView: WhatsNewTestScreen())
    } else {
      window.rootViewController = UIViewController()
    }
    window.makeKeyAndVisible()
    self.window = window
  }
}

private struct WhatsNewTestScreen: View {
  private let defaults = UserDefaults(suiteName: "bugkit.whats-new-ui-test")!
  private let feed = WhatsNewFeed(generated: "fixture", days: [
    .init(day: "2026-10-11", items: [.init(story: 1, text: "A visible change", sha: "fixture")])
  ])
  private var dark: Bool { CommandLine.arguments.contains("--dark") }

  init() { defaults.removePersistentDomain(forName: "bugkit.whats-new-ui-test") }

  var body: some View {
    VStack {
      WhatsNewRow(feed: feed, seen: WhatsNewSeen(defaults: defaults), logger: { _, _ in }, open: {})
        .padding()
        .background(dark ? Color.black : Color.white)
      Spacer()
    }
    .padding()
    .preferredColorScheme(dark ? .dark : .light)
  }
}
