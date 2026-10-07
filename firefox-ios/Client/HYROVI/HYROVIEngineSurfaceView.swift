// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

// HYROVI Engine native surface viewer.
// This path deliberately does not import WebKit.

import SwiftUI
import UIKit

@MainActor
final class HYROVIEngineSurfaceController: ObservableObject {
    enum Mode {
        case probing
        case servo
        case privateLocked
        case compatibility
    }

    let stream: RemoteStream
    let client: OneClient

    @Published var mode: Mode = .probing
    @Published var image: UIImage?
    @Published var connected = false
    @Published var errorMessage: String?

    private var pollingTask: Task<Void, Never>?
    private var revision = 0
    private var relayKey: String?
    private var sealIdentity: String?
    private var sealKeyId: String?
    private var actionCounter: UInt64 = 0

    init(stream: RemoteStream, client: OneClient) {
        self.stream = stream
        self.client = client
    }

    func start() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.poll()
                if self.mode == .compatibility { return }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func refresh() {
        revision = 0
        Task { [weak self] in await self?.poll() }
    }

    func sendScroll(x: Double, y: Double) {
        sendAction(["type": "scroll", "x": x, "y": y])
    }

    func sendTap(x: Double, y: Double) {
        sendAction(["type": "click", "x": x, "y": y])
    }

    private func sendAction(_ action: [String: Any]) {
        Task { [weak self] in
            guard let self else { return }
            do {
                if self.stream.privateMode == true {
                    guard let relayKey = self.relayKey else { return }
                    let wallClock = UInt64(max(0, Date().timeIntervalSince1970 * 1_000_000))
                    self.actionCounter = max(self.actionCounter &+ 1, wallClock)
                    let sealed = try HYROVIEngineCore.shared.sealRelayAction(
                        relayKey: relayKey,
                        counter: self.actionCounter,
                        action: action
                    )
                    try await self.client.sendPrivateRemoteAction(
                        streamId: self.stream.id,
                        sealedAction: sealed
                    )
                } else {
                    try await self.client.sendRemoteAction(
                        streamId: self.stream.id,
                        action: action
                    )
                }
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func poll() async {
        do {
            // Ask One only for data newer than the last frame. The server sends a
            // complete Servo snapshot only when snapshotRevision advanced.
            let state = try await client.remoteTab(id: stream.id, since: revision)

            if state.stream.privateMode == true || state.sealedSnapshot != nil {
                try await pollPrivate(state)
                return
            }

            revision = max(revision, state.latestRevision)
            guard let snapshot = state.snapshot?.data else {
                connected = true
                return
            }

            if try applyServoSnapshot(snapshot) {
                return
            }

            mode = .compatibility
            connected = true
            errorMessage = nil
        } catch {
            connected = false
            errorMessage = error.localizedDescription
        }
    }

    private func pollPrivate(_ state: RemoteStreamState) async throws {
        if sealIdentity == nil || sealKeyId == nil {
            let identity = try await client.ensurePrivateSealIdentityRegistered()
            sealIdentity = identity.identity
            sealKeyId = identity.key.keyId
        }

        if relayKey == nil {
            guard let keyId = sealKeyId,
                  let identity = sealIdentity,
                  let grant = state.keyGrants?.first(where: { $0.keyId == keyId }) else {
                image = nil
                mode = .privateLocked
                connected = true
                errorMessage = nil
                // Do not advance revision while locked. As soon as the compute
                // host publishes this device's wrapped key, One will resend the
                // current encrypted snapshot as well.
                return
            }
            relayKey = try HYROVIEngineCore.shared.openRelayKey(
                identity: identity,
                sealedKey: grant.sealedKey
            )
        }

        guard let relayKey else {
            throw HYROVIEngineSurfaceError.privateKeyUnavailable
        }

        guard let envelope = state.sealedSnapshot else {
            if image != nil {
                mode = .servo
                connected = true
                errorMessage = nil
                revision = max(revision, state.latestRevision)
            } else {
                mode = .privateLocked
                connected = true
            }
            return
        }

        let snapshot = try HYROVIEngineCore.shared.openRelaySnapshot(
            relayKey: relayKey,
            sealed: envelope.data
        )
        guard try applyServoSnapshot(snapshot) else {
            throw HYROVIEngineSurfaceError.privateSurfaceNotServo
        }
        revision = max(revision, state.latestRevision)
    }

    @discardableResult
    private func applyServoSnapshot(_ snapshot: RemoteSnapshot) throws -> Bool {
        guard snapshot.engine == "servo", let surface = snapshot.surface else {
            return false
        }
        guard ["png", "jpeg", "jpg"].contains(surface.codec.lowercased()),
              let data = Data(base64Encoded: surface.dataBase64),
              let decoded = UIImage(data: data) else {
            throw HYROVIEngineSurfaceError.invalidSurface
        }
        image = decoded
        mode = .servo
        connected = true
        errorMessage = nil
        return true
    }
}

enum HYROVIEngineSurfaceError: LocalizedError {
    case invalidSurface
    case privateKeyUnavailable
    case privateSurfaceNotServo

    var errorDescription: String? {
        switch self {
        case .invalidSurface:
            return "Ungültiger HYROVI-Engine-Surface."
        case .privateKeyUnavailable:
            return "Der private Session-Schlüssel ist auf diesem Gerät nicht verfügbar."
        case .privateSurfaceNotServo:
            return "Eine private HYROVI Session darf nicht in den WebKit-Kompatibilitätsmodus wechseln."
        }
    }
}

struct HYROVIEngineAwareRemoteTabView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var controller: HYROVIEngineSurfaceController

    private let stream: RemoteStream
    private let client: OneClient

    init(stream: RemoteStream, client: OneClient) {
        self.stream = stream
        self.client = client
        _controller = StateObject(
            wrappedValue: HYROVIEngineSurfaceController(stream: stream, client: client)
        )
    }

    var body: some View {
        Group {
            switch controller.mode {
            case .probing:
                ProgressView("HYROVI Engine verbinden …")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .servo:
                HYROVINativeSurfaceView(controller: controller)

            case .privateLocked:
                VStack(spacing: 12) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 34, weight: .semibold))
                        .accessibilityHidden(true)
                    Text("Private HYROVI Session")
                        .font(.headline)
                    Text("Der verschlüsselte Geräteschlüssel wird sicher vom Compute-Host freigegeben …")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 28)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .compatibility:
                // Only legacy Gecko/HTML streams enter the old compatibility
                // viewer. Servo sessions never instantiate WKWebView.
                RemoteTabView(stream: stream, client: client)
            }
        }
        .onAppear { controller.start() }
        .onDisappear { controller.stop() }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                controller.start()
            } else {
                controller.stop()
            }
        }
    }
}

private struct HYROVINativeSurfaceView: View {
    @ObservedObject var controller: HYROVIEngineSurfaceController
    @State private var dragOrigin: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                Color.black.opacity(0.02)
                surface(viewSize: proxy.size)
                statusBar
            }
        }
    }

    @ViewBuilder
    private func surface(viewSize: CGSize) -> some View {
        if let image = controller.image {
            let fit = fittedSurface(imageSize: image.size, viewSize: viewSize)

            Image(uiImage: image)
                .resizable()
                .interpolation(.none)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .accessibilityLabel("Gerenderte Webseite")
                .gesture(scrollGesture(fit: fit))
                .simultaneousGesture(tapGesture(fit: fit))
        } else {
            ProgressView()
        }
    }

    private var statusBar: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(controller.connected ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text("HYROVI Engine · Servo")
                .fontWeight(.semibold)
            Spacer()
            Button {
                controller.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .accessibilityHidden(true)
            }
            .accessibilityLabel("Neu laden")
            .buttonStyle(.plain)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(.ultraThinMaterial)
    }

    private func scrollGesture(fit: (scale: CGFloat, rect: CGRect)) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let dx = value.translation.width - dragOrigin.width
                let dy = value.translation.height - dragOrigin.height
                dragOrigin = value.translation
                let scale = max(fit.scale, 0.001)
                controller.sendScroll(x: -Double(dx / scale), y: -Double(dy / scale))
            }
            .onEnded { _ in dragOrigin = .zero }
    }

    private func tapGesture(fit: (scale: CGFloat, rect: CGRect)) -> some Gesture {
        DragGesture(minimumDistance: 0).onEnded { value in
            guard abs(value.translation.width) <= 8, abs(value.translation.height) <= 8 else { return }
            guard fit.rect.contains(value.location) else { return }
            let x = Double((value.location.x - fit.rect.minX) / fit.scale)
            let y = Double((value.location.y - fit.rect.minY) / fit.scale)
            controller.sendTap(x: x, y: y)
        }
    }

    private func fittedSurface(imageSize: CGSize, viewSize: CGSize) -> (scale: CGFloat, rect: CGRect) {
        guard imageSize.width > 0, imageSize.height > 0,
              viewSize.width > 0, viewSize.height > 0 else {
            return (1, .zero)
        }

        let scale = min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        let rect = CGRect(
            x: (viewSize.width - width) / 2,
            y: (viewSize.height - height) / 2,
            width: width,
            height: height
        )
        return (scale, rect)
    }
}
