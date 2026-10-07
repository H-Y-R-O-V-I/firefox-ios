// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import UIKit
import SwiftUI
import Common
import Redux
import SafariServices

final class HYROVISharedTabsPanel: UIViewController,
                                  UITableViewDelegate,
                                  UITableViewDataSource,
                                  Themeable,
                                  TabTrayThemeable {
    private enum UX {
        static let cellIdentifier = "HYROVISharedTabCell"
    }

    private let windowUUID: WindowUUID
    private let showsNavigationBar: Bool
    private let one = OneClient()
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)

    private var session: OneSession?
    private var liveStreams: [RemoteStream] = []
    private var syncState: BrowserSyncState?
    private var loading = false
    private var errorMessage: String?
    private var autoRefreshTask: Task<Void, Never>?

    var themeManager: ThemeManager
    var themeListenerCancellable: Any?
    var notificationCenter: NotificationProtocol

    init(windowUUID: WindowUUID,
         showsNavigationBar: Bool = false,
         themeManager: ThemeManager = AppContainer.shared.resolve(),
         notificationCenter: NotificationProtocol = NotificationCenter.default) {
        self.windowUUID = windowUUID
        self.showsNavigationBar = showsNavigationBar
        self.themeManager = themeManager
        self.notificationCenter = notificationCenter
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var currentWindowUUID: UUID? { windowUUID }
    var shouldUsePrivateOverride: Bool { true }
    var shouldBeInPrivateTheme: Bool { false }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        if showsNavigationBar {
            title = "HYROVI One"
            navigationItem.largeTitleDisplayMode = .never
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .done,
                target: self,
                action: #selector(dismissHub)
            )
        }
        listenForThemeChanges(withNotificationCenter: notificationCenter)
        applyTheme()

        Task { @MainActor [weak self] in
            await self?.restoreAndRefresh()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(!showsNavigationBar, animated: false)
        applyTheme()
        startAutoRefresh()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
    }

    private func startAutoRefresh() {
        guard autoRefreshTask == nil else { return }
        autoRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled, let self, self.signedIn, !self.loading else { continue }
                await self.refresh()
            }
        }
    }

    @objc private func dismissHub() {
        dismiss(animated: true)
    }

    private func setupUI() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.delegate = self
        tableView.dataSource = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 76
        tableView.separatorStyle = .none
        tableView.sectionHeaderTopPadding = 14
        tableView.accessibilityIdentifier = "hyrovi.sharedTabs"
        tableView.tableHeaderView = makeSharedTabsHeader()

        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(refreshPulled), for: .valueChanged)
        tableView.refreshControl = refresh

        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func makeSharedTabsHeader() -> UIView {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 92))
        let logo = UIImageView(image: UIImage(named: "hyroviBrandLogo"))
        logo.translatesAutoresizingMaskIntoConstraints = false
        logo.contentMode = .scaleAspectFit

        let title = UILabel()
        title.translatesAutoresizingMaskIntoConstraints = false
        title.text = "Shared Tabs"
        title.font = .systemFont(ofSize: 24, weight: .bold)

        let subtitle = UILabel()
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        subtitle.text = "Live weiterarbeiten · Geräte synchronisieren"
        subtitle.font = .systemFont(ofSize: 13, weight: .medium)
        subtitle.textColor = .secondaryLabel

        let labels = UIStackView(arrangedSubviews: [title, subtitle])
        labels.translatesAutoresizingMaskIntoConstraints = false
        labels.axis = .vertical
        labels.spacing = 3

        container.addSubview(logo)
        container.addSubview(labels)
        NSLayoutConstraint.activate([
            logo.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            logo.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            logo.widthAnchor.constraint(equalToConstant: 44),
            logo.heightAnchor.constraint(equalToConstant: 44),
            labels.leadingAnchor.constraint(equalTo: logo.trailingAnchor, constant: 12),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -18),
            labels.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        return container
    }

    @objc private func refreshPulled() {
        Task { @MainActor [weak self] in
            await self?.refresh()
        }
    }

    private func restoreAndRefresh() async {
        session = await one.restoreSession()
        if session?.authenticated == true {
            await refresh()
        } else {
            tableView.reloadData()
        }
    }

    private func refresh() async {
        guard !loading else { return }
        guard session?.authenticated == true else {
            tableView.refreshControl?.endRefreshing()
            tableView.reloadData()
            return
        }

        loading = true
        errorMessage = nil
        defer {
            loading = false
            tableView.refreshControl?.endRefreshing()
            tableView.reloadData()
        }

        do {
            liveStreams = try await one.listRemoteTabs()
            syncState = try await one.browserSync()
        } catch {
            errorMessage = error.localizedDescription
            if await one.restoreSession() == nil {
                session = nil
                liveStreams = []
                syncState = nil
            }
        }
    }

    private func signIn() {
        guard !loading else { return }
        loading = true
        errorMessage = nil
        tableView.reloadData()

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                session = try await one.signIn()
                loading = false
                tableView.reloadData()
                await refresh()
            } catch {
                loading = false
                errorMessage = error.localizedDescription
                tableView.reloadData()
            }
        }
    }

    private func signOut() {
        guard !loading else { return }
        loading = true
        tableView.reloadData()

        Task { @MainActor [weak self] in
            guard let self else { return }
            await one.signOut()
            session = nil
            liveStreams = []
            syncState = nil
            errorMessage = nil
            loading = false
            tableView.reloadData()
        }
    }

    private var signedIn: Bool {
        session?.authenticated == true
    }

    private var deviceIDs: [String] {
        let tabsByDevice = syncState?.data.tabsByDevice ?? [:]
        return tabsByDevice.keys
            .filter { !(tabsByDevice[$0] ?? []).isEmpty }
            .sorted { deviceName($0).localizedCaseInsensitiveCompare(deviceName($1)) == .orderedAscending }
    }

    private func deviceName(_ id: String) -> String {
        syncState?.data.devices?[id]?.name ?? id
    }

    private func syncedTabs(forDevice id: String) -> [SyncedTab] {
        syncState?.data.tabsByDevice?[id] ?? []
    }

    func numberOfSections(in tableView: UITableView) -> Int {
        guard signedIn else { return 1 }
        return 2 + deviceIDs.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard signedIn else {
            return errorMessage == nil ? 1 : 2
        }

        switch section {
        case 0:
            return errorMessage == nil ? 3 : 4
        case 1:
            return max(1, liveStreams.count)
        default:
            return syncedTabs(forDevice: deviceIDs[section - 2]).count
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard signedIn else { return "HYROVI One" }

        switch section {
        case 0:
            return "HYROVI One"
        case 1:
            return "Live Shared Tabs"
        default:
            return deviceName(deviceIDs[section - 2])
        }
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if !signedIn && section == 0 {
            return "Ein Account für Shared Tabs, Geräte und Browser-Sync."
        }
        if signedIn && section == 1 {
            return "Live-Tabs laufen auf dem Hostgerät. "
                + "Das iPhone erhält DOM-Zustand und Änderungen statt eines Videostreams."
        }
        return nil
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: UX.cellIdentifier)
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: UX.cellIdentifier)

        cell.accessoryType = .none
        cell.selectionStyle = .default
        cell.imageView?.image = nil
        cell.textLabel?.textColor = nil
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.backgroundColor = .secondarySystemGroupedBackground
        cell.layer.cornerRadius = 14
        cell.layer.masksToBounds = true

        guard signedIn else {
            if indexPath.row == 0 {
                cell.textLabel?.text = loading ? "HYROVI One wird geöffnet …" : "Mit HYROVI One anmelden"
                cell.detailTextLabel?.text = "Browser, Shared Tabs und Geräte verbinden"
                cell.imageView?.image = UIImage(systemName: "person.crop.circle")
                cell.accessoryType = .disclosureIndicator
                cell.selectionStyle = loading ? .none : .default
            } else {
                cell.textLabel?.text = errorMessage
                cell.detailTextLabel?.text = nil
                cell.imageView?.image = UIImage(systemName: "exclamationmark.triangle")
                cell.selectionStyle = .none
            }
            return cell
        }

        switch indexPath.section {
        case 0:
            switch indexPath.row {
            case 0:
                cell.textLabel?.text = session?.user ?? "HYROVI One"
                let deviceSummary = String(liveStreams.count) + " Live · "
                    + String(deviceIDs.count) + " Geräte"
                cell.detailTextLabel?.text = [session?.role, deviceSummary]
                    .compactMap { $0 }
                    .joined(separator: " · ")
                cell.imageView?.image = UIImage(systemName: "person.crop.circle.fill")
                cell.selectionStyle = .none
            case 1:
                cell.textLabel?.text = loading ? "Synchronisiere …" : "Jetzt synchronisieren"
                cell.detailTextLabel?.text = syncState.map { "Revision " + String($0.revision) }
                    ?? "Shared Tabs und Geräte aktualisieren"
                cell.imageView?.image = UIImage(systemName: "arrow.clockwise")
            case 2:
                cell.textLabel?.text = "HYROVI One öffnen"
                cell.detailTextLabel?.text = "Account und Geräte verwalten"
                cell.imageView?.image = UIImage(systemName: "arrow.up.right.square")
                cell.accessoryType = .disclosureIndicator
            default:
                cell.textLabel?.text = errorMessage
                cell.detailTextLabel?.text = nil
                cell.imageView?.image = UIImage(systemName: "exclamationmark.triangle")
                cell.selectionStyle = .none
            }

        case 1:
            guard !liveStreams.isEmpty else {
                cell.textLabel?.text = "Keine Live Shared Tabs"
                cell.detailTextLabel?.text = "Starte auf einem anderen Gerät einen Shared Tab."
                cell.imageView?.image = UIImage(systemName: "rectangle.stack")
                cell.selectionStyle = .none
                return cell
            }

            let stream = liveStreams[indexPath.row]
            cell.textLabel?.text = stream.title.isEmpty ? stream.host : stream.title
            cell.detailTextLabel?.text = "LIVE · " + deviceName(stream.deviceId) + " · " + stream.host
            cell.imageView?.image = UIImage(systemName: "dot.radiowaves.left.and.right")
            cell.imageView?.tintColor = .systemGreen
            cell.accessoryType = .disclosureIndicator

        default:
            let deviceId = deviceIDs[indexPath.section - 2]
            let tab = syncedTabs(forDevice: deviceId)[indexPath.row]
            cell.textLabel?.text = tab.host
            cell.detailTextLabel?.text = "Von " + deviceName(deviceId) + " · " + tab.url
            cell.imageView?.image = UIImage(systemName: "laptopcomputer.and.iphone")
            cell.accessoryType = .disclosureIndicator
        }

        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        guard signedIn else {
            if indexPath.row == 0 && !loading {
                signIn()
            }
            return
        }

        switch indexPath.section {
        case 0:
            if indexPath.row == 1 {
                Task { @MainActor [weak self] in
                    await self?.refresh()
                }
            } else if indexPath.row == 2,
                      let url = URL(string: "https://one.hyrovi.com/") {
                let browser = SFSafariViewController(url: url)
                browser.dismissButtonStyle = .close
                present(browser, animated: true)
            }

        case 1:
            guard !liveStreams.isEmpty else { return }
            let stream = liveStreams[indexPath.row]
            let view = HYROVIEngineAwareRemoteTabView(stream: stream, client: one)
            let host = UIHostingController(rootView: view)
            host.title = stream.title.isEmpty ? stream.host : stream.title
            navigationController?.setNavigationBarHidden(false, animated: true)
            navigationController?.pushViewController(host, animated: true)

        default:
            let deviceId = deviceIDs[indexPath.section - 2]
            let tab = syncedTabs(forDevice: deviceId)[indexPath.row]
            guard let url = URL(string: tab.url) else { return }

            let action = RemoteTabsPanelAction(
                url: url,
                windowUUID: windowUUID,
                actionType: RemoteTabsPanelActionType.openSelectedURL
            )
            store.dispatch(action)
        }
    }

    func tableView(_ tableView: UITableView,
                   trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard signedIn, indexPath.section == 0, indexPath.row == 0 else { return nil }

        let action = UIContextualAction(style: .destructive, title: "Abmelden") { [weak self] _, _, completion in
            self?.signOut()
            completion(true)
        }
        return UISwipeActionsConfiguration(actions: [action])
    }

    func retrieveTheme() -> Theme {
        themeManager.resolvedTheme(with: false)
    }

    func applyTheme(_ theme: Theme) {
        view.backgroundColor = theme.isNova ? theme.colors.layer1 : theme.colors.layer3
        tableView.backgroundColor = theme.isNova ? theme.colors.layer1 : theme.colors.layer3
        tableView.separatorColor = theme.colors.borderPrimary
    }

    func applyTheme() {
        applyTheme(retrieveTheme())
    }
}
