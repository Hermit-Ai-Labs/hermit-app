import Foundation

/// Moving a person from the model they have to the one that replaced it. Hermit keeps answering with `from` the
/// whole time: `to` only takes over once every one of its files is on the device and passed its check, and `from`'s
/// files only go after that.
public struct ModelUpgrade: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// The card with Download and Not now. Shown until one of them is tapped.
        case offered
        /// Download was tapped: the card shows the download (running, paused, waiting for Wi-Fi or stopped).
        case inProgress
        /// Downloaded and checked. It takes over when no chat is using the old model (at once if none is).
        case landed
    }
    /// The model in use, which keeps answering.
    public let from: ModelSpec
    /// The model that replaced it.
    public let to: ModelSpec
    public let phase: Phase

    public init(from: ModelSpec, to: ModelSpec, phase: Phase) { self.from = from; self.to = to; self.phase = phase }
}

/// The models a build knows, the two a new install starts with, and the device's memory: everything the rules for
/// "which model by default" and "which model replaces which" need, and nothing else, so they can be checked with
/// made-up models. `ModelCatalog.lineup(memoryGB:)` is the app's own.
public struct ModelLineup: Sendable {
    public let all: [ModelSpec]
    /// The full model a new install gets, and the Lite one.
    public let fullID: String
    public let liteID: String
    public let memoryGB: Int

    public init(all: [ModelSpec], fullID: String, liteID: String, memoryGB: Int) {
        self.all = all; self.fullID = fullID; self.liteID = liteID; self.memoryGB = memoryGB
    }

    /// The app's catalog on this device.
    public static var shipped: ModelLineup { ModelCatalog.lineup(memoryGB: ModelCatalog.deviceMemoryGB) }

    public var ids: Set<String> { Set(all.map(\.id)) }

    /// The spec for an id, or a plain one built from the repo name if it isn't in the list.
    public func spec(_ id: String) -> ModelSpec { all.first { $0.id == id } ?? ModelCatalog.unlisted(id) }

    public func fits(_ spec: ModelSpec) -> Bool { memoryGB >= spec.minMemoryGB }

    /// Listed, runnable by the MLX library, and small enough for this device.
    public func usable(_ spec: ModelSpec) -> Bool { all.contains(where: { $0.id == spec.id }) && spec.supported && fits(spec) }

    /// The model a new install starts with: the full one where it fits, Lite elsewhere.
    public var defaultID: String { fits(spec(fullID)) ? fullID : liteID }

    /// One of the two models this build installs. The others are older releases, kept for the people who have them.
    public func isCurrent(_ spec: ModelSpec) -> Bool { spec.id == fullID || spec.id == liteID }

    /// The model that replaced `spec`: this build's model of the same line (Lite for a Lite, the full model for a
    /// full one). nil when `spec` is that model already, or this device can't run the newer one.
    public func successor(of spec: ModelSpec) -> ModelSpec? {
        let next = self.spec(spec.isLite ? liteID : fullID)
        guard next.id != spec.id, usable(next) else { return nil }
        return next
    }

    /// The model chat uses when the app opens.
    /// - A saved choice this device can run wins. One exception: an older model that is no longer on the device and
    ///   isn't on its way (`pending`) is not downloaded again, the model that replaced it is the one to get.
    /// - With none saved (the first model was downloaded and never picked by hand), a model that is already on the
    ///   device wins over a default that isn't, so a build with a newer default never takes a working model away.
    ///   Of several, the one in the default's line is taken.
    /// - With nothing on the device but a download under way or waiting for Wi-Fi (`pending`: the first download was
    ///   interrupted before this build), that model: it continues by itself, so it must be the one in use when it
    ///   lands, not a file beside a default nobody downloaded.
    /// - With nothing on the device and nothing on its way, the default.
    public func initialSelection(saved: String?, pending: String? = nil, isReady: (String) -> Bool) -> String {
        if let saved, usable(spec(saved)) {
            if !isReady(saved), saved != pending, let next = successor(of: spec(saved)) { return next.id }
            return saved
        }
        let preferred = defaultID
        if isReady(preferred) { return preferred }
        let have = all.filter { usable($0) && isReady($0.id) }
        let line = spec(preferred).isLite
        if let pick = have.first(where: { $0.isLite == line }) ?? have.first { return pick.id }
        if let pending, usable(spec(pending)) { return pending }
        return preferred
    }

    /// Whether to show the upgrade card, and in which state.
    /// - Only for a person whose model is downloaded and working (a new install just gets the default).
    /// - Offered once per newer model: after "Not now" (`dismissed`, every model answered so far) it is not offered
    ///   again, a later model is.
    /// - After "Download" (`accepted`) it is in progress until the files are in, then landed until it takes over.
    public func upgrade(selectedID: String, isReady: (String) -> Bool, accepted: String?, dismissed: Set<String>) -> ModelUpgrade? {
        let from = spec(selectedID)
        guard isReady(selectedID), let to = successor(of: from) else { return nil }
        if accepted == to.id { return ModelUpgrade(from: from, to: to, phase: isReady(to.id) ? .landed : .inProgress) }
        // Downloaded by hand in Settings: nothing to offer, "Use" is there.
        if isReady(to.id) || dismissed.contains(to.id) { return nil }
        return ModelUpgrade(from: from, to: to, phase: .offered)
    }
}
