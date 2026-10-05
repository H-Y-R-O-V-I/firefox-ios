// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation

struct OneSession: Codable, Equatable {
    let authenticated: Bool
    let user: String?
    let role: String?
    let permissions: [String]?
    let authType: String?
    let expiresAt: Int?
    let clientId: String?
    let scopes: [String]?
}

struct RemoteStream: Codable, Identifiable, Hashable {
    let id: String
    let deviceId: String
    let tabId: String
    let url: String
    let title: String
    let revision: Int
    let createdAt: Int64
    let lastSeenAt: Int64

    var host: String {
        URL(string: url)?.host ?? url
    }
}

struct RemoteStreamList: Codable {
    let streams: [RemoteStream]
    let ttlMs: Int?
}

struct RemoteViewport: Codable {
    let width: Double
    let height: Double
    let scale: Double?
}

struct RemoteSnapshot: Codable {
    let url: String
    let title: String?
    let html: String
    let scrollX: Double?
    let scrollY: Double?
    let viewport: RemoteViewport?
    let capturedAt: Int64?
}

struct RemoteSnapshotEnvelope: Codable {
    let revision: Int
    let data: RemoteSnapshot
}

struct RemotePatch: Codable {
    let op: String
    let nodeId: String?
    let name: String?
    let value: String?
    let html: String?
    let remove: Bool?
    let scrollX: Double?
    let scrollY: Double?
}

struct RemotePatchBatch: Codable {
    let revision: Int
    let at: Int64
    let ops: [RemotePatch]
}

struct RemoteStreamState: Codable {
    let stream: RemoteStream
    let snapshot: RemoteSnapshotEnvelope?
    let updates: [RemotePatchBatch]
    let latestRevision: Int
}

struct SyncBookmark: Codable, Identifiable, Hashable {
    let key: String
    let title: String
    let url: String
    let path: [String]?
    let updatedAt: Int64?

    var id: String { key }
}

struct SyncedTab: Codable, Hashable {
    let url: String
    let pinned: Bool?
    let lastAccessed: Int64?

    var host: String {
        URL(string: url)?.host ?? url
    }
}

struct SyncDevice: Codable, Hashable {
    let name: String?
    let os: String?
    let arch: String?
    let updatedAt: Int64?
}

struct BrowserSyncData: Codable {
    let schemaVersion: Int?
    let bookmarks: [SyncBookmark]?
    let tabsByDevice: [String: [SyncedTab]]?
    let devices: [String: SyncDevice]?
}

struct BrowserSyncState: Codable {
    let revision: Int
    let updatedAt: Int64?
    let data: BrowserSyncData
}

struct QueuedActionResponse: Codable {
    struct Queued: Codable {
        let seq: Int
        let at: Int64
    }

    let queued: Queued
}

struct TokenResponse: Codable {
    let accessToken: String
    let tokenType: String
    let expiresIn: Int
}
