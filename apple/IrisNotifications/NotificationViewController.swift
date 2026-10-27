import IrisUI
import SwiftUI
import UIKit
import UserNotifications
import UserNotificationsUI

/// What the card shows: the push alert's title is the route chip, its body the headline.
@Observable
final class NotificationCardModel {
  var routeChip = ""
  var headline = ""
}

final class NotificationViewController: UIViewController, UNNotificationContentExtension {
  private let model = NotificationCardModel()

  override func viewDidLoad() {
    super.viewDidLoad()
    let host = UIHostingController(rootView: NotificationCard(model: model))
    host.view.backgroundColor = .clear
    host.view.translatesAutoresizingMaskIntoConstraints = false
    addChild(host)
    view.addSubview(host.view)
    NSLayoutConstraint.activate([
      host.view.topAnchor.constraint(equalTo: view.topAnchor),
      host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    ])
    host.didMove(toParent: self)
  }

  func didReceive(_ notification: UNNotification) {
    let content = notification.request.content
    model.routeChip = content.title
    model.headline = content.body
  }
}

private struct NotificationCard: View {
  let model: NotificationCardModel

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
      if !model.routeChip.isEmpty {
        RouteChip(label: model.routeChip, systemImage: "arrow.triangle.branch")
      }
      Text(model.headline)
        .themeFont(.subheadline, weight: .semibold)
        .foregroundStyle(Theme.Ink.primary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(Theme.Spacing.lg)
  }
}
