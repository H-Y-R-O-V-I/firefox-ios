// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import Foundation
import SafariServices
import UIKit

@MainActor
final class HYROVIOneSetting: Setting {
    private let windowUUID: WindowUUID

    init(windowUUID: WindowUUID) {
        self.windowUUID = windowUUID
        super.init(title: nil)
    }

    override var title: NSAttributedString? {
        guard let theme else { return nil }
        return NSAttributedString(
            string: "HYROVI One",
            attributes: [.foregroundColor: theme.colors.textPrimary]
        )
    }

    override var status: NSAttributedString? {
        guard let theme else { return nil }
        return NSAttributedString(
            string: "Account, Geräte, Sync & Shared Tabs",
            attributes: [.foregroundColor: theme.colors.textSecondary]
        )
    }

    override var accessoryView: UIImageView? {
        guard let theme else { return nil }
        return SettingDisclosureUtility.buildDisclosureIndicator(theme: theme)
    }

    override func onConfigureCell(_ cell: UITableViewCell, theme: Theme) {
        super.onConfigureCell(cell, theme: theme)
        cell.imageView?.image = UIImage(named: "hyroviBrandLogo")
        cell.imageView?.tintColor = theme.colors.iconPrimary
    }

    override func onClick(_ navigationController: UINavigationController?) {
        let hub = HYROVISharedTabsPanel(windowUUID: windowUUID, showsNavigationBar: true)
        let nav = UINavigationController(rootViewController: hub)
        nav.modalPresentationStyle = .pageSheet
        nav.sheetPresentationController?.detents = [.medium(), .large()]
        nav.sheetPresentationController?.prefersGrabberVisible = true
        navigationController?.present(nav, animated: true)
    }
}

@MainActor
final class HYROVIWebSetting: Setting {
    private let rowTitle: String
    private let rowSubtitle: String?
    private let targetURL: URL

    init(title: String, subtitle: String? = nil, url: URL) {
        rowTitle = title
        rowSubtitle = subtitle
        targetURL = url
        super.init(title: nil)
    }

    override var title: NSAttributedString? {
        guard let theme else { return nil }
        return NSAttributedString(
            string: rowTitle,
            attributes: [.foregroundColor: theme.colors.textPrimary]
        )
    }

    override var status: NSAttributedString? {
        guard let theme, let rowSubtitle else { return nil }
        return NSAttributedString(
            string: rowSubtitle,
            attributes: [.foregroundColor: theme.colors.textSecondary]
        )
    }

    override var accessoryView: UIImageView? {
        guard let theme else { return nil }
        return SettingDisclosureUtility.buildDisclosureIndicator(theme: theme)
    }

    override func onConfigureCell(_ cell: UITableViewCell, theme: Theme) {
        super.onConfigureCell(cell, theme: theme)
        cell.imageView?.image = UIImage(systemName: "arrow.up.right.square")
        cell.imageView?.tintColor = theme.colors.iconPrimary
    }

    override func onClick(_ navigationController: UINavigationController?) {
        let browser = SFSafariViewController(url: targetURL)
        browser.dismissButtonStyle = .close
        navigationController?.present(browser, animated: true)
    }
}

@MainActor
final class HYROVIPrivacySetting: Setting {
    init(theme: Theme) {
        super.init(
            title: NSAttributedString(
                string: "Datenschutz & Daten",
                attributes: [.foregroundColor: theme.colors.textPrimary]
            )
        )
    }

    override var accessoryView: UIImageView? {
        guard let theme else { return nil }
        return SettingDisclosureUtility.buildDisclosureIndicator(theme: theme)
    }

    override func onConfigureCell(_ cell: UITableViewCell, theme: Theme) {
        super.onConfigureCell(cell, theme: theme)
        cell.imageView?.image = UIImage(systemName: "hand.raised.fill")
        cell.imageView?.tintColor = theme.colors.iconPrimary
    }

    override func onClick(_ navigationController: UINavigationController?) {
        navigationController?.pushViewController(HYROVIPrivacyViewController(), animated: true)
    }
}

// swiftlint:disable line_length
@MainActor
final class HYROVIPrivacyViewController: UIViewController {
    private let textView: UITextView = {
        let view = UITextView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isEditable = false
        view.isScrollEnabled = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 20, left: 18, bottom: 32, right: 18)
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        return view
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Datenschutz & Daten"
        view.backgroundColor = .systemBackground
        view.addSubview(textView)

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        textView.text = """
        HYROVI Browser

        HYROVI Browser basiert auf dem Open-Source-Projekt Firefox für iOS und nutzt Apples WebKit für Webseiten.

        Browserdaten wie Verlauf, Tabs und Einstellungen bleiben grundsätzlich auf deinem Gerät, solange du keine HYROVI-One-Funktion verwendest.

        HYROVI One
        Wenn du HYROVI One verbindest, werden die für Account, Geräte-Synchronisierung und Shared Tabs benötigten Daten mit HYROVI One ausgetauscht. Shared Tabs übertragen Browserzustand und Interaktionen über die HYROVI-One-Infrastruktur.

        Mozilla-Datenübertragung
        Im HYROVI-Build sind Mozilla-Nutzungsdaten, Crash-Reports, Studies/Experimente, gesponserte Firefox-Vorschläge und gesponserte Firefox-Shortcuts standardmäßig deaktiviert.

        Webseiten
        Webseiten können unabhängig davon eigene Daten verarbeiten, Cookies setzen oder Berechtigungen anfragen. Das hängt von der jeweils besuchten Website ab.

        Open Source
        Die verwendeten Open-Source-Komponenten und Lizenzen findest du unter „Über HYROVI Browser“.
        """
    }
}
// swiftlint:enable line_length
