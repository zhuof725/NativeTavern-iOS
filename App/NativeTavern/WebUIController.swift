import SwiftUI
import WebKit
import SafariServices

/// Hosts the tavern interface in the system browser tab.
///
/// A real browser tab is what the page expects: its origin, module imports,
/// localStorage and cookies behave as they do on a desktop install. The gateway
/// cannot see the app's Bearer token from a browser, so the engine hands out an
/// entry address whose one-time token is exchanged for a session cookie on the
/// first hop (see `webui.session` and the gateway's `/shell` route).
///
/// The tab is configured here and owned by this controller; it takes the whole
/// screen while the interface is in use.
final class WebUIController: UIViewController {
    private let client: LocalEngineClient
    private var safari: SFSafariViewController?

    init(client: LocalEngineClient) {
        self.client = client
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        Task { await open() }
    }

    private func open() async {
        struct Session: Decodable { let browserURL: String; let coreReady: Bool }
        let address: URL
        do {
            let session = try await client.call("webui.session", as: Session.self)
            guard let url = URL(string: session.browserURL) else { throw LocalEngineFailure("引擎没有给出有效地址。") }
            address = url
        } catch {
            let label = UILabel()
            label.numberOfLines = 0
            label.textAlignment = .center
            label.font = .preferredFont(forTextStyle: .footnote)
            label.text = "无法打开酒馆界面：\(error.localizedDescription)"
            label.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                label.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -48),
            ])
            return
        }

        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        configuration.barCollapsingEnabled = false
        let controller = SFSafariViewController(url: address, configuration: configuration)
        controller.dismissButtonStyle = .close
        controller.preferredControlTintColor = .label
        addChild(controller)
        controller.view.frame = view.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(controller.view)
        controller.didMove(toParent: self)
        safari = controller
    }
}
