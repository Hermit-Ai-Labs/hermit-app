import SwiftUI

/// Explore: search, then New, Trending and All. All has category chips and a list; every DApp has a
/// Connect / Connected control.
struct ExplorePage: View {
    @Environment(AppModel.self) private var model
    @State private var tab: Tab = .new
    @State private var q = ""
    @State private var cat = "All"
    @State private var width: CGFloat = 1000
    @FocusState private var searching: Bool

    enum Tab: String, Hashable { case new, trending, all }

    var body: some View {
        let compact = width < 640
        Page(title: "Explore", tabs: [(.new, "New"), (.trending, "Trending"), (.all, "All")], tab: $tab) {
            if !compact { search.frame(width: 240) }
        } content: { t in
            VStack(alignment: .leading, spacing: 0) {
                if compact { search.padding(.bottom, 16) }
                switch t {
                case .new: grid(ExploreData.dapps.filter(\.isNew), compact)
                case .trending: grid(ExploreData.dapps.filter(\.hot), compact)
                case .all: all(compact)
                }
            }
        }
        .payWidth($width)
        .onChange(of: q) { _, v in if !v.isEmpty && tab != .all { tab = .all } }
        .onAppear {
            if let r = model.tabRequest, let v = Tab(rawValue: r) { tab = v; model.tabRequest = nil }
        }
    }

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(Theme.faint)
            TextField("Search", text: $q).textFieldStyle(.plain).focused($searching).autocorrectionDisabled()
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

    private func grid(_ list: [ExploreDapp], _ compact: Bool) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: compact ? 150 : 210), spacing: 14)], spacing: 14) {
            ForEach(list) { ExploreCard(dapp: $0) }
        }
    }

    private func all(_ compact: Bool) -> some View {
        let list = ExploreData.dapps.filter { d in
            (cat == "All" || d.cat == cat || (cat == "New" && d.isNew))
                && (q.isEmpty || "\(d.name) \(d.desc) \(d.cat)".localizedCaseInsensitiveContains(q))
        }
        return VStack(alignment: .leading, spacing: 0) {
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
            if list.isEmpty {
                VStack(spacing: 10) {
                    Text("No results").foregroundStyle(Theme.muted)
                    if !q.isEmpty {
                        Button("Ask Hermit about \"\(q)\"") { model.send("Find DApps for \(q)") }
                            .buttonStyle(OutlineButton())
                    }
                }
                .frame(maxWidth: .infinity).padding(.vertical, 32)
            }
        }
    }
}
