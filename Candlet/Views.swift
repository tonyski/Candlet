import SwiftUI

struct WatchlistView: View {
    @Environment(Store.self) private var store
    @Environment(Updater.self) private var updater
    @Environment(\.openURL) private var openURL
    @AppStorage("redUp") private var redUp = true
    @State private var adding = false
    @State private var input = ""
    @State private var suggestions: [Stock] = []
    /// suggestions 对应的输入
    @State private var suggestionsFor = ""
    /// 建议还没跟上输入时按了回车：建议到了再添加
    @State private var submitted = false
    @FocusState private var focused: Bool
    @AppStorage("group") private var groupID = ""
    @State private var naming: Naming?
    @State private var draftName = ""
    @FocusState private var nameFocused: Bool
    /// 正在拖动排序的分组标签，及各标签的位置（用来判断是否越过了相邻标签）
    @State private var tabDrag: TabDrag?
    @State private var tabFrames: [StockGroup.ID: CGRect] = [:]
    /// 点开的自选，面板显示它的详情
    @State private var detail: Stock?
    /// 也可能在系统设置里改，面板打开时重新读取
    @State private var launchAtLogin = LoginItem.isEnabled

    /// 正在编辑的名字：新建分组、重命名分组（记下目标，不依赖当前选中的是哪个）、给股票改名
    private enum Naming: Equatable { case new, rename(StockGroup.ID), stock(String) }

    /// 当前分组；记住的分组被删掉时回到第一个
    private var group: StockGroup { store.groups.first { $0.id.uuidString == groupID } ?? store.groups[0] }

    private struct TabDrag {
        let id: StockGroup.ID
        /// 拖动中与相邻标签换位后，标签的原位跟着移动了这么多，要从鼠标位移里扣掉
        var shift: CGFloat = 0
        var offset: CGFloat = 0
    }

    private let rowHeight: CGFloat = 44
    private let tabSpacing: CGFloat = 2
    /// 面板内容左右边距。List 自带约 8pt 行内边距，行内再补 8pt 对齐到这里
    private let margin: CGFloat = 16

    var body: some View {
        VStack(spacing: 0) {
            if let detail {
                StockDetail(stock: detail) { self.detail = nil }
            } else {
                watchlist
            }
        }
        .frame(width: 360)
        .onAppear(perform: panelOpened)
        // 某些系统版本上 MenuBarExtra 的 onAppear 只在首次打开时触发，用面板成为 key window 兜底
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in panelOpened() }
        // 面板关掉后下次打开回到列表
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            store.panelClosed()
            detail = nil
        }
    }

    /// 刷新行情、按需检查更新；登录项也可能在系统设置里改过，重新读取
    private func panelOpened() {
        store.panelOpened()
        updater.panelOpened()
        launchAtLogin = LoginItem.isEnabled
    }

    @ViewBuilder
    private var watchlist: some View {
        header
        if store.groups.count > 1 || naming == .new { groupTabs }
        if adding { addField }
        // 长桥普通断线时已自动改用免费行情，只在标题栏提示；这里只放需要用户处理的
        if case .offline(_, needsLogin: true) = store.status {
            loginCard
        } else if store.freeFailed {
            freeFailedNotice
        }
        Divider()
        list
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Candlet")
                .font(.system(size: 12, weight: .semibold))
            longbridgeStatus
            Spacer()
            let addTitle = adding ? "取消" : "添加"
            Button(addTitle, systemImage: adding ? "xmark" : "plus") {
                adding ? closeAddField() : openAddField()
            }
            .help(addTitle)
            if case .available(let release) = updater.state {
                Circle().fill(.tint).frame(width: 6, height: 6).help("有新版本 \(release.version)")   // 用强调色，不用红色，免得像涨跌或报错
            }
            Menu {
                Button("新建分组…") { startNaming(.new, "") }
                Divider()
                @Bindable var store = store
                Toggle("使用长桥行情", isOn: $store.longbridge)
                Toggle("登录时打开", isOn: Binding(get: { launchAtLogin }) {
                    LoginItem.set($0)
                    launchAtLogin = LoginItem.isEnabled
                })
                Toggle("红涨绿跌", isOn: $redUp)
                Divider()
                updateItem
                Button("退出") { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("更多")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, margin)
        .frame(height: 36)
    }

    /// 两个以上分组、或正在新建分组时显示；当前分组加粗
    private var groupTabs: some View {
        ScrollViewReader { scroller in
            ScrollView(.horizontal) {
                HStack(spacing: tabSpacing) {
                    ForEach(store.groups) { item in
                        let selected = item.id == group.id
                        if naming == .rename(item.id) {
                            nameTab
                        } else {
                            let active = selected && naming != .new   // 新建时高亮让给正在编辑的标签
                            Button(item.name) { groupID = item.id.uuidString }
                                .buttonStyle(.plain)
                                .foregroundStyle(active ? .primary : .secondary)
                                .groupTab(active: active)
                                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("tabs")) } action: { tabFrames[item.id] = $0 }
                                .offset(x: tabDrag?.id == item.id ? tabDrag?.offset ?? 0 : 0)
                                .zIndex(tabDrag?.id == item.id ? 1 : 0)
                                .highPriorityGesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("tabs"))
                                    .onChanged { dragTab(item.id, $0) }
                                    .onEnded { _ in tabDrag = nil })
                                .contextMenu { tabMenu(item) }
                        }
                    }
                    if naming == .new { nameTab }
                }
                .padding(.horizontal, margin - 8)   // 标签自带 8pt 内边距，文字与标题对齐
                .coordinateSpace(.named("tabs"))
            }
            .scrollIndicators(.never)
            .onChange(of: naming) { if naming != nil { withAnimation { scroller.scrollTo("naming") } } }
        }
        .padding(.bottom, 6)
    }

    /// 分组标签的右键菜单，和自选行的右键菜单一致；至少保留一个分组
    @ViewBuilder
    private func tabMenu(_ item: StockGroup) -> some View {
        Button("重命名…") { startNaming(.rename(item.id), item.name) }
        if store.groups.count > 1 {
            Button(item.stocks.isEmpty ? "删除" : "删除…", role: .destructive) { confirmDelete(item) }
        }
    }

    /// 拖动的标签跟着鼠标走；鼠标越过相邻标签的中线就和它换位，松手即停在新位置
    private func dragTab(_ id: StockGroup.ID, _ value: DragGesture.Value) {
        var drag = tabDrag ?? TabDrag(id: id)
        let ids = store.groups.map(\.id)
        if let i = ids.firstIndex(of: id) {
            let x = value.location.x
            if i + 1 < ids.count, let next = tabFrames[ids[i + 1]], x > next.midX {
                store.moveGroup(id, to: ids[i + 1])
                drag.shift += next.width + tabSpacing
            } else if i > 0, let previous = tabFrames[ids[i - 1]], x < previous.midX {
                store.moveGroup(id, to: ids[i - 1])
                drag.shift -= previous.width + tabSpacing
            }
        }
        drag.offset = value.translation.width - drag.shift
        tabDrag = drag
    }

    /// 新建、重命名都直接在标签上编辑：回车或点别处保存，Esc 取消
    private var nameTab: some View {
        // 无边框输入框的提示文字会跟随正文颜色，自己画一个浅色占位；它也撑起最小宽度
        ZStack(alignment: .leading) {
            Text("分组名称").foregroundStyle(.tertiary).opacity(draftName.isEmpty ? 1 : 0)
            editingName(TextField("分组名称", text: $draftName, prompt: Text(""))
                .textFieldStyle(.plain)
                .foregroundStyle(.primary)
                .fixedSize())
        }
        .groupTab(active: true)
        .id("naming")
    }

    /// 股票改名也在行内：占位是原名，清空后保存即恢复原名
    private func stockNameField(_ stock: Stock) -> some View {
        editingName(TextField(stock.name, text: $draftName)
            .textFieldStyle(.roundedBorder)
            .controlSize(.small))
            .padding(.horizontal, 8)
            .frame(maxHeight: .infinity)
    }

    /// 打开即聚焦；回车或点别处保存，Esc 取消
    private func editingName(_ field: some View) -> some View {
        field
            .focused($nameFocused)
            .onAppear { nameFocused = true }
            .onSubmit(commitName)
            .onExitCommand { naming = nil }
            .onChange(of: nameFocused) { _, focused in if !focused { commitName() } }
    }

    private func startNaming(_ mode: Naming, _ name: String) {
        closeAddField()
        draftName = name
        naming = mode
    }

    private func commitName() {
        guard naming != nil else { return }   // 回车保存后失焦还会再调用一次
        let name = draftName.trimmingCharacters(in: .whitespaces)
        switch naming {
        case .new where !name.isEmpty: groupID = store.createGroup(name).uuidString
        case .rename(let id) where !name.isEmpty: store.renameGroup(id, to: name)
        case .stock(let symbol): store.renameStock(symbol, to: name)
        default: break
        }
        naming = nil
    }

    /// 空分组直接删；有股票时先确认，因为不能撤销。菜单栏面板里的 SwiftUI 弹窗不可靠，用系统提醒框
    private func confirmDelete(_ target: StockGroup) {
        guard !target.stocks.isEmpty else { return store.deleteGroup(target.id) }
        let alert = NSAlert()
        alert.messageText = "删除「\(target.name)」？"
        alert.informativeText = "分组里的 \(target.stocks.count) 只自选会一起删除，且无法撤销。"
        alert.addButton(withTitle: "删除").hasDestructiveAction = true
        alert.addButton(withTitle: "取消")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { store.deleteGroup(target.id) }
    }

    @ViewBuilder
    private var updateItem: some View {
        switch updater.state {
        case .checking: Button("正在检查更新…") {}.disabled(true)
        case .upToDate: Button("已是最新版本（\(updater.current)）", action: updater.check)
        case .failed: Button("检查更新失败，点击重试", action: updater.check)
        case .available(let release):
            Button("更新到 \(release.version)", action: updater.install)
            Button("查看更新内容") { openURL(release.page) }
        case .installing(let release): Button("正在安装 \(release.version)…") {}.disabled(true)
        }
    }

    /// 免费行情取不到时的提示条：会自动重试，这里只给一个立即重试的入口
    private var freeFailedNotice: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("行情暂时取不到，稍后自动重试")
                .foregroundStyle(Color.warning)
            Spacer()
            Button("立即重试", action: store.refreshFreeNow)
                .buttonStyle(.link)
        }
        .font(.caption2)
        .padding(.horizontal, margin)
        .padding(.bottom, 8)
    }

    /// 未登录或登录失效：在面板里直接登录，授权在浏览器中完成
    private var loginCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch store.login {
            case .idle, .failed:
                Text("登录长桥")
                    .font(.system(size: 12, weight: .semibold))
                Text("需要已开通 OpenAPI 的长桥账户")
                    .foregroundStyle(.secondary)
                if case .failed(let message) = store.login {
                    Text(message).foregroundStyle(Color.warning)
                }
                HStack(spacing: 12) {
                    Button("在浏览器中登录", action: store.logIn)
                        .buttonStyle(.borderedProminent)
                    Button("不连接") { store.longbridge = false }
                        .buttonStyle(.link)
                }
            case .waiting(let url):
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("请在浏览器中完成授权…")
                }
                HStack(spacing: 12) {
                    if let url { Button("重新打开授权页") { openURL(url) } }
                    Button("取消", action: store.cancelLogIn)
                }
                .buttonStyle(.link)
            }
        }
        .font(.caption)
        .controlSize(.small)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.primary.opacity(0.05), in: .rect(cornerRadius: 8))
        .padding(.horizontal, margin)
        .padding(.bottom, 10)
    }

    /// 只在连接中、断线时出现，靠形状而不只是颜色区分；绿点会和「红涨绿跌」里的跌混淆，正常连接时不显示。
    /// 未登录时下面有登录卡片，这里不再重复
    @ViewBuilder
    private var longbridgeStatus: some View {
        switch store.status {
        case .off, .live, .offline(_, needsLogin: true): EmptyView()
        case .connecting:
            ProgressView()
                .controlSize(.mini)
                .help("正在连接长桥…")
                .accessibilityLabel("正在连接长桥")
        case .offline(let reason, needsLogin: false):
            Button("长桥已断开，点击立即重连", systemImage: "exclamationmark.triangle.fill", action: store.reconnect)
                .font(.system(size: 10))
                .foregroundStyle(Color.warning)
                .help("长桥：\(reason)\n暂用免费行情，点击立即重连")
        }
    }

    private var addField: some View {
        searchField
            .padding(.horizontal, margin)
            .padding(.bottom, 10)
            .onAppear(perform: store.loadCatalog)
            .onChange(of: input) { _, text in
                submitted = false
                if let stock = suggestions.first(where: { $0.symbol == text }) { add(stock) }
            }
            .task(id: "\(input)|\(store.catalogSize)|\(groupID)") {
                let query = input
                let found = await store.suggestions(for: query, in: group.id)
                guard !Task.isCancelled else { return }
                (suggestions, suggestionsFor) = (found, query)
                if submitted { addFirstSuggestion() }
            }
    }

    /// 回车添加第一条建议；建议还没跟上输入时先记下，到了再加，免得加错或像没反应
    private func addFirstSuggestion() {
        guard !input.isEmpty else { return }
        guard suggestionsFor == input else { submitted = true; return }
        submitted = false
        guard let stock = suggestions.first(where: { $0.symbol == input }) ?? suggestions.first else { return }
        add(stock)
    }

    private func add(_ stock: Stock) {
        store.add(stock, to: group.id)
        input = ""
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            TextField("代码或名称", text: $input)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .focused($focused)
                .onExitCommand(perform: closeAddField)
                .onSubmit(addFirstSuggestion)
                // 系统补全菜单：选中后代码会填进输入框，这时直接添加
                .textInputSuggestions {
                    ForEach(suggestions, id: \.symbol) { stock in
                        HStack {
                            Text(stock.name)
                            Spacer()
                            Text(stock.subtitle)
                                .foregroundStyle(.secondary)
                        }
                        .textInputCompletion(stock.symbol)
                    }
                }
            // 证券目录还没加载完，或在线搜索（没有长桥目录时）还没返回
            if !input.isEmpty, store.catalogLoading || (!store.stocksSearchable && suggestionsFor != input) {
                ProgressView().controlSize(.mini)
            }
        }
    }

    private func openAddField() {
        naming = nil
        input = ""
        adding = true
        focused = true
    }

    private func closeAddField() {
        adding = false
        input = ""
        focused = false
    }

    @ViewBuilder
    private var list: some View {
        let shown = group.stocks
        if shown.isEmpty {
            Text("点 + 添加自选，如「腾讯」「AAPL」「BTC」")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(height: 80)
        } else {
            List {
                ForEach(shown) { stock in
                    Group {
                        if naming == .stock(stock.symbol) {
                            stockNameField(stock)
                        } else {
                            StockRow(stock: stock, quote: store.quotes[stock.symbol],
                                     spark: store.sparks[stock.symbol] ?? [], redUp: redUp,
                                     stale: stock.isCrypto ? !store.cryptoLive : !store.stocksLive,
                                     marketCap: store.marketCap(for: stock.symbol))
                        }
                    }
                    .modifier(HoverHighlight())
                    // 点在整行任意位置都进详情（HoverHighlight 已把整行设为可点区域）；改名时不跳转
                    .onTapGesture { if naming != .stock(stock.symbol) { detail = stock } }
                    .frame(height: rowHeight)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .contextMenu { rowMenu(stock) }
                }
                .onMove { store.move(from: $0, to: $1, in: group.id) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contentMargins(.vertical, 0, for: .scrollContent)
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(CGFloat(shown.count) * rowHeight, 480))
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private func rowMenu(_ stock: Stock) -> some View {
        let others = store.groups.filter { $0.id != group.id }
        if !others.isEmpty {
            Menu("移到") {
                ForEach(others) { target in
                    Button(target.name) { store.move(stock, from: group.id, to: target.id) }
                }
            }
        }
        Button("重命名…") { startNaming(.stock(stock.symbol), stock.displayName) }
        if stock.alias != nil {
            Button("恢复原名「\(stock.name)」") { store.renameStock(stock.symbol, to: "") }
        }
        Button("删除", role: .destructive) { store.remove(stock, from: group.id) }
    }
}
