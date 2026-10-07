// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import SwiftUI
import WebKit

@MainActor
final class RemoteTabController: NSObject, ObservableObject, WKScriptMessageHandler {
    let stream: RemoteStream
    let client: OneClient
    let webView: WKWebView

    @Published var connected = false
    @Published var errorMessage: String?

    private var revision = 0
    private var pollingTask: Task<Void, Never>?

    init(stream: RemoteStream, client: OneClient) {
        self.stream = stream
        self.client = client

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let controller = WKUserContentController()
        configuration.userContentController = controller
        webView = WKWebView(frame: .zero, configuration: configuration)

        super.init()

        controller.add(self, name: "hyrovi")
        controller.addUserScript(
            WKUserScript(
                source: Self.viewerBridge,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )
    }

    deinit {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "hyrovi")
        pollingTask?.cancel()
    }

    func start() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            guard let self else { return }
            await self.poll(initial: true)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 750_000_000)
                if Task.isCancelled { break }
                await self.poll(initial: false)
            }
        }
    }

    func forceRefresh() {
        Task { [weak self] in
            guard let self else { return }
            await self.poll(initial: true)
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func poll(initial: Bool) async {
        do {
            let state = try await client.remoteTab(id: stream.id, since: initial ? 0 : revision)

            if let snapshot = state.snapshot {
                revision = snapshot.revision
                let baseURL = URL(string: snapshot.data.url)
                webView.loadHTMLString(snapshot.data.html ?? "", baseURL: baseURL)
                if let x = snapshot.data.scrollX, let y = snapshot.data.scrollY {
                    let js = "window.setTimeout(()=>window.scrollTo(\(x),\(y)),60)"
                    try? await webView.evaluateJavaScript(js)
                }
            }

            for batch in state.updates where batch.revision > revision {
                try await apply(batch.ops)
                revision = max(revision, batch.revision)
            }

            revision = max(revision, state.latestRevision)
            connected = true
            errorMessage = nil
        } catch {
            connected = false
            errorMessage = error.localizedDescription
        }
    }

    private func apply(_ patches: [RemotePatch]) async throws {
        let data = try JSONEncoder().encode(patches)
        guard let json = String(data: data, encoding: .utf8) else { return }
        _ = try await webView.evaluateJavaScript("window.__hyroviApply(\(json))")
    }

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "hyrovi",
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        var action: [String: Any] = ["type": type]
        for key in ["nodeId", "value", "key", "url"] {
            if let value = body[key] as? String {
                action[key] = value
            }
        }
        for key in ["x", "y"] {
            if let value = body[key] as? NSNumber {
                action[key] = value.doubleValue
            }
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await self.client.sendRemoteAction(streamId: self.stream.id, action: action)
        }
    }

    static let viewerBridge = #"""
    (() => {
      if (window.__hyroviViewerInstalled) return;
      window.__hyroviViewerInstalled = true;
      let scrollState = { timer: null };
      const bridge = window.webkit.messageHandlers.hyrovi;

      const nodeFor = target =>
        target && target.closest ? target.closest('[data-hyrovi-node]') : null;

      document.addEventListener('click', event => {
        const node = nodeFor(event.target);
        if (!node) return;
        event.preventDefault();
        event.stopPropagation();
        bridge.postMessage({type:'click', nodeId:node.dataset.hyroviNode});
      }, true);

      document.addEventListener('input', event => {
        const node = nodeFor(event.target);
        if (!node) return;
        bridge.postMessage({
          type:'input',
          nodeId:node.dataset.hyroviNode,
          value:String(event.target.value ?? '')
        });
      }, true);

      document.addEventListener('keydown', event => {
        if (!['Enter','Escape','ArrowUp','ArrowDown','ArrowLeft','ArrowRight'].includes(event.key)) return;
        const node = nodeFor(event.target);
        if (!node) return;
        bridge.postMessage({type:'key', nodeId:node.dataset.hyroviNode, key:event.key});
      }, true);

      window.addEventListener('scroll', () => {
        if (scrollState.timer) return;
        scrollState.timer = setTimeout(() => {
          scrollState.timer = null;
          bridge.postMessage({type:'scroll', x:window.scrollX, y:window.scrollY});
        }, 160);
      }, {passive:true});

      window.__hyroviApply = ops => {
        for (const op of ops || []) {
          if (op.op === 'scroll') {
            window.scrollTo(Number(op.scrollX)||0, Number(op.scrollY)||0);
            continue;
          }
          const el = op.nodeId
            ? document.querySelector('[data-hyrovi-node="' + CSS.escape(op.nodeId) + '"]')
            : null;
          if (!el) continue;
          if (op.op === 'children') {
            el.innerHTML = op.html || '';
          } else if (op.op === 'text') {
            el.textContent = op.value || '';
          } else if (op.op === 'attr' && op.name) {
            if (op.remove) el.removeAttribute(op.name);
            else el.setAttribute(op.name, op.value || '');
          }
        }
        return true;
      };
    })();
    """#
}

struct RemoteWKWebView: UIViewRepresentable {
    @ObservedObject var controller: RemoteTabController

    func makeUIView(context: Context) -> WKWebView {
        controller.webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct RemoteTabView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var controller: RemoteTabController

    init(stream: RemoteStream, client: OneClient) {
        _controller = StateObject(wrappedValue: RemoteTabController(stream: stream, client: client))
    }

    var body: some View {
        ZStack(alignment: .top) {
            RemoteWKWebView(controller: controller)
                .padding(.top, 38)

            VStack(spacing: 0) {
                statusBar
                errorBanner
            }
        }
        .navigationTitle(controller.stream.title.isEmpty ? controller.stream.host : controller.stream.title)
        .navigationBarTitleDisplayMode(.inline)
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

    private var statusBar: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(controller.connected ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(controller.connected ? "Live verbunden" : "Verbinde ...")
                .fontWeight(.semibold)
            Text("-")
            Text(controller.stream.host)
                .lineLimit(1)
            Spacer()
            refreshButton
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(.ultraThinMaterial)
    }

    private var refreshButton: some View {
        Button {
            controller.forceRefresh()
        } label: {
            Image(systemName: "arrow.clockwise")
                .accessibilityHidden(true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Neu laden")
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let errorMessage = controller.errorMessage {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .accessibilityHidden(true)
                Text(errorMessage)
                    .lineLimit(2)
                Spacer()
                Button("Neu verbinden") {
                    controller.forceRefresh()
                }
            }
            .font(.caption)
            .padding(10)
            .background(.thinMaterial)
        }
    }
}
