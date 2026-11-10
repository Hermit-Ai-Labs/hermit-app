import SwiftUI

/// Explore: search (or type any site's address to open it), Your sites (ones you added), then New, Trending and All. All has category chips and a list. TVL comes live from DefiLlama;
/// Trending is the biggest 7-day TVL growth. Open shows the app in Hermit's browser (Pages/Browser), which takes the
/// page's place until it's closed.
struct ExplorePage: View {
    @Environment(AppModel.self) private var model
    @State private var tab: Tab = .new
    @State private var q = ""
    @State private var cat = "All"
    @State private var width: CGFloat = 1000
    @FocusState private var searching: Bool
    @State private var adding = false
    private var store: ExploreStore { .shared }

    enum Tab: String, Hashable { case new, trending, all }

    var body: some View {
        if let s = DappBrowser.shared.session { DappBrowserView(session: s) } else { directory }
    }

    @ViewBuilder private var directory: some View {
        let compact = width < 640
        Page(title: "Explore", tabs: [(.new, "New"), (.trending, "Trending"), (.all, "All")], tab: $tab) {
            if !compact { search.frame(width: 240) }
        } content: { t in
            VStack(alignment: .leading, spacing: 0) {
                if compact { search.padding(.bottom, 16) }
                SavedSitesRow { adding = true }
                switch t {
                case .new: grid(ExploreData.dapps.filter(\.isNew), compact)
                case .trending: trending(compact)
                case .all: all(compact)
                }
            }
        }
        .payWidth($width)
        .sheet(isPresented: $adding) { AddSiteSheet().environment(model).tint(Theme.text) }
        .marketPoll(every: 900) { await store.refresh() }
        .onChange(of: q) { _, v in if !v.isEmpty && tab != .all { tab = .all } }
        .onAppear {
            if let r = model.tabRequest, let v = Tab(rawValue: r) { tab = v; model.tabRequest = nil }
            #if DEBUG
            DappBrowser.shared.debugLaunch(model)
            #endif
        }
    }

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(Theme.faint)
            TextField("Search or type a site", text: $q).textFieldStyle(.plain).focused($searching).autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never).submitLabel(.go)
                #endif
                .onSubmit(submit)
            if !q.isEmpty {
                Button { q = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.faint) }
                    .buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .font(.system(size: 14))
        .padding(.horizontal, 12).frame(height: 36)
        .background(Theme.hover, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(searching ? Theme.text.opacity(0.25) : .clear))
        .animation(.snappy(duration: 0.15), value: searching)
    }

    /// What's typed, as a site, when it looks like an address ("uniswap.org", "https://…") rather than a search.
    private var typedSite: URL? {
        let t = q.trimmingCharacters(in: .whitespaces)
        guard t.contains("."), !t.hasSuffix(".") else { return nil }
        return DappBrowserSession.normalize(t)
    }

    /// Enter: a typed address opens; a search with no app matching opens the closest app, else a web search.
    private func submit() {
        let t = q.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        if let u = typedSite { DappBrowser.shared.open(u, model: model); q = ""; return }
        if !matches(t).isEmpty { return }
        if let d = ExploreData.fuzzy(t, in: ExploreData.dapps).first, let u = d.url {
            DappBrowser.shared.open(u, dapp: d, model: model); q = ""
        } else if let u = ExploreData.webSearch(t) {
            DappBrowser.shared.open(u, model: model); q = ""
        }
    }

    private func matches(_ text: String) -> [ExploreDapp] {
        ExploreData.dapps.filter { "\($0.name) \($0.desc) \($0.cat)".localizedCaseInsensitiveContains(text) }
    }

    private func addSite(_ text: String) {
        guard let u = DappBrowserSession.normalize(text) else { model.toast("That isn't a web address"); return }
        withAnimation(.snappy) { SavedSites.shared.add(u) }
        model.toast("Added \(u.host() ?? "")")
    }

    private func grid(_ list: [ExploreDapp], _ compact: Bool) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: compact ? 150 : 210), spacing: 14)], spacing: 14) {
            ForEach(list) { ExploreCard(dapp: $0) }
        }
    }

    /// Apps whose TVL grew most over the last 7 days (at least $10M deep, so tiny pools don't top the list).
    @ViewBuilder private func trending(_ compact: Bool) -> some View {
        let list = ExploreData.dapps.compactMap { d in store.value(d).flatMap { v in v.tvl >= 10_000_000 ? v.change7d.map { (d, $0) } : nil } }
            .sorted { $0.1 > $1.1 }.prefix(9).map(\.0)
        if list.isEmpty {
            MarketStatus(kind: store.state == .failed ? .failed("Couldn't reach DefiLlama") : .loading("Loading TVL from DefiLlama")) {
                Task { await store.refresh(force: true) }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                grid(Array(list), compact)
                MarketSource(text: "Biggest 7-day TVL growth, from DefiLlama")
            }
        }
    }

    private func all(_ compact: Bool) -> some View {
        let list = ExploreData.dapps.filter { d in
            (cat == "All" || d.cat == cat || (cat == "New" && d.isNew))
                && (q.isEmpty || "\(d.name) \(d.desc) \(d.cat)".localizedCaseInsensitiveContains(q))
        }
        return VStack(alignment: .leading, spacing: 0) {
            if let u = typedSite {
                HStack(spacing: 10) {
                    Image(systemName: "globe").font(.system(size: 15)).foregroundStyle(Theme.muted)
                    Text(u.host() ?? "").font(.system(size: 14, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 8)
                    if !SavedSites.shared.contains(u) {
                        Button("Add to Your sites") { addSite(q) }.buttonStyle(PayPillButton(kind: .outline))
                    }
                    Button("Open") { DappBrowser.shared.open(u, model: model); q = "" }.buttonStyle(PayPillButton(kind: .black))
                }
                .padding(12)
                .background(Theme.hover, in: RoundedRectangle(cornerRadius: 12))
                .padding(.bottom, 14)
            }
            PayFlow(spacing: 6) {
                ForEach(ExploreData.categories, id: \.self) { c in
                    PayChip(c, on: c == cat) { cat = c }
                }
            }
            .padding(.bottom, 10)
            LazyVStack(spacing: 0) {
                ForEach(Array(list.enumerated()), id: \.element.id) { i, d in
                    ExploreRow(dapp: d, compact: compact).payLine(i > 0)
                }
            }
            .animation(.snappy(duration: 0.25), value: cat)
            if list.isEmpty && !q.isEmpty {
                let close = ExploreData.fuzzy(q, in: ExploreData.dapps)
                if !close.isEmpty {
                    Text("Did you mean").font(.system(size: 13)).foregroundStyle(Theme.muted).padding(.top, 6).padding(.bottom, 4)
                    LazyVStack(spacing: 0) {
                        ForEach(Array(close.enumerated()), id: \.element.id) { i, d in
                            ExploreRow(dapp: d, compact: compact).payLine(i > 0)
                        }
                    }
                }
                VStack(spacing: 10) {
                    if close.isEmpty && typedSite == nil { Text("No apps match").foregroundStyle(Theme.muted) }
                    HStack(spacing: 8) {
                        if let u = ExploreData.webSearch(q) {
                            Button("Search the web for \"\(q)\"") { DappBrowser.shared.open(u, model: model); q = "" }
                                .buttonStyle(OutlineButton())
                        }
                        Button("Ask Hermit") { model.send("Find DApps for \(q)") }.buttonStyle(OutlineButton())
                    }
                }
                .frame(maxWidth: .infinity).padding(.vertical, 24)
            }
        }
    }
}
