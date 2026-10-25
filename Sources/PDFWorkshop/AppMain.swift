import AppKit
import WorkshopCore
import PDFKit
import UniformTypeIdentifiers

let appName = "PDF 工坊"

final class DropView: NSView {
    var received: (([URL]) -> Void)?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        received?(urls)
        return true
    }
}

final class PageCell: NSTableCellView {
    let thumb = NSImageView()
    let label = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.shadowOpacity = 0.14
        thumb.layer?.shadowRadius = 3
        thumb.layer?.shadowOffset = CGSize(width: 0, height: -1)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        [thumb, label, detail].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        NSLayoutConstraint.activate([
            thumb.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            thumb.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumb.widthAnchor.constraint(equalToConstant: 58), thumb.heightAnchor.constraint(equalToConstant: 76),
            label.leadingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: 14),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 32),
            detail.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            detail.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 6),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation {
    var window: NSWindow!
    let pdfView = PDFView()
    let table = NSTableView()
    let welcome = NSView()
    let status = NSTextField(labelWithString: "所有文件只在本机处理")
    let countLabel = NSTextField(labelWithString: "页面")
    let pageLabel = NSTextField(labelWithString: "")
    let spinner = NSProgressIndicator()
    let dpiPopup = NSPopUpButton()
    let rangePopup = NSPopUpButton()
    var actionButtons: [NSButton] = []
    var document: PDFDocument?
    var sourceURL: URL?
    var changedPages = Set<Int>()
    var busy = false
    var isSelecting = false
    var selectedIndex: Int { max(0, table.selectedRow) }
    var openQueue: [URL] = []
    var splitSheet: SplitSheet?
    var splitCancellation: CancellationFlag?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        setupMenu()
        buildWindow()
        if !openQueue.isEmpty { receive(openQueue); openQueue = [] }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if busy { NSSound.beep(); return .terminateCancel }
        return confirmDiscard() ? .terminateNow : .terminateCancel
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if busy { NSSound.beep(); return false }
        let confirmed = confirmDiscard()
        if confirmed { window.isDocumentEdited = false }
        return confirmed
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        if window == nil { openQueue = urls } else { receive(urls) }
        NSApp.reply(toOpenOrPrint: .success)
    }

    func setupMenu() {
        let main = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于\(appName)", action: #selector(about), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出\(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem(); appItem.submenu = appMenu; main.addItem(appItem)
        let fileMenu = NSMenu(title: "文件")
        fileMenu.addItem(withTitle: "打开 PDF…", action: #selector(openPDF), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "导出图片…", action: #selector(exportImages), keyEquivalent: "e")
        fileMenu.addItem(withTitle: "替换页面图片…", action: #selector(replaceImages), keyEquivalent: "r")
        let splitItem = fileMenu.addItem(withTitle: "按大小拆分 PDF…", action: #selector(splitPDF), keyEquivalent: "d")
        splitItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(withTitle: "另存为 PDF…", action: #selector(savePDF), keyEquivalent: "s")
        let fileItem = NSMenuItem(); fileItem.submenu = fileMenu; main.addItem(fileItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem(); editItem.submenu = editMenu; main.addItem(editItem)
        let helpMenu = NSMenu(title: "帮助")
        helpMenu.addItem(withTitle: "使用方法", action: #selector(showHelp), keyEquivalent: "?")
        let helpItem = NSMenuItem(); helpItem.submenu = helpMenu; main.addItem(helpItem)
        NSApp.mainMenu = main
    }

    func button(_ title: String, symbol: String, action: Selector, primary: Bool = false) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .large
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        b.imagePosition = .imageLeading
        b.font = .systemFont(ofSize: 13, weight: primary ? .semibold : .regular)
        if primary { b.bezelColor = .systemBlue }
        b.setContentHuggingPriority(.required, for: .horizontal)
        return b
    }

    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 810),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = appName
        window.minSize = NSSize(width: 1000, height: 660)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        let root = DropView()
        root.received = { [weak self] urls in self?.receive(urls) }
        window.contentView = root

        let open = button("打开 PDF", symbol: "doc.badge.plus", action: #selector(openPDF))
        let export = button("导出图片", symbol: "square.and.arrow.up", action: #selector(exportImages))
        let replace = button("替换图片", symbol: "arrow.triangle.2.circlepath", action: #selector(replaceImages))
        let save = button("另存 PDF", symbol: "square.and.arrow.down", action: #selector(savePDF), primary: true)
        let divide = button("按大小拆分", symbol: "scissors", action: #selector(splitPDF))
        let help = button("使用方法", symbol: "questionmark.circle", action: #selector(showHelp))
        actionButtons += [export, replace, divide, save]
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let toolbar = NSStackView(views: [open, export, replace, divide, spacer, help, save])
        toolbar.orientation = .horizontal; toolbar.spacing = 10
        toolbar.edgeInsets = NSEdgeInsets(top: 13, left: 18, bottom: 13, right: 18)
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(toolbar)

        let split = NSSplitView()
        split.isVertical = true; split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(split)
        let sidebar = NSView(); sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        let preview = NSView(); preview.wantsLayer = true
        preview.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        split.addArrangedSubview(sidebar); split.addArrangedSubview(preview)
        countLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        countLabel.textColor = .secondaryLabelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(countLabel)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("page")))
        table.headerView = nil; table.rowHeight = 105
        table.style = .sourceList; table.intercellSpacing = .zero
        table.dataSource = self; table.delegate = self
        table.allowsEmptySelection = false
        scroll.documentView = table
        sidebar.addSubview(scroll)
        let up = button("", symbol: "arrow.up", action: #selector(moveUp)); up.toolTip = "将当前页向前移一页"
        let down = button("", symbol: "arrow.down", action: #selector(moveDown)); down.toolTip = "将当前页向后移一页"
        let rotate = button("旋转", symbol: "rotate.right", action: #selector(rotatePage))
        actionButtons += [up, down, rotate]
        let pageTools = NSStackView(views: [up, down, rotate]); pageTools.spacing = 5
        pageTools.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(pageTools)

        pdfView.autoScales = true; pdfView.displayMode = .singlePage
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = NSColor(calibratedWhite: 0.91, alpha: 1)
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        preview.addSubview(pdfView)
        welcome.translatesAutoresizingMaskIntoConstraints = false
        preview.addSubview(welcome)
        buildWelcome()
        NotificationCenter.default.addObserver(self, selector: #selector(previewPageChanged), name: .PDFViewPageChanged, object: pdfView)

        let settings = NSStackView(); settings.orientation = .horizontal; settings.spacing = 10
        settings.edgeInsets = NSEdgeInsets(top: 12, left: 18, bottom: 12, right: 18)
        settings.translatesAutoresizingMaskIntoConstraints = false
        dpiPopup.addItems(withTitles: ["150 DPI · 较小文件", "300 DPI · 推荐", "600 DPI · 超清"])
        dpiPopup.selectItem(at: 1)
        rangePopup.addItems(withTitles: ["全部页面", "仅当前页"])
        let dpiLabel = NSTextField(labelWithString: "导出图片")
        dpiLabel.font = .systemFont(ofSize: 12, weight: .medium)
        let settingsSpacer = NSView()
        pageLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        pageLabel.textColor = .secondaryLabelColor
        [dpiLabel, dpiPopup, rangePopup, settingsSpacer, pageLabel].forEach { settings.addArrangedSubview($0) }
        root.addSubview(settings)
        let footer = NSStackView(); footer.orientation = .horizontal; footer.spacing = 8
        footer.edgeInsets = NSEdgeInsets(top: 0, left: 18, bottom: 10, right: 18)
        footer.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingMiddle
        footer.addArrangedSubview(spinner); footer.addArrangedSubview(status)
        root.addSubview(footer)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor), toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.topAnchor.constraint(equalTo: toolbar.bottomAnchor), split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor), split.bottomAnchor.constraint(equalTo: settings.topAnchor),
            sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 205), sidebar.widthAnchor.constraint(lessThanOrEqualToConstant: 290),
            countLabel.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 16), countLabel.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 18),
            scroll.topAnchor.constraint(equalTo: countLabel.bottomAnchor, constant: 10), scroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: pageTools.topAnchor, constant: -12),
            pageTools.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12), pageTools.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -12),
            pdfView.topAnchor.constraint(equalTo: preview.topAnchor), pdfView.bottomAnchor.constraint(equalTo: preview.bottomAnchor),
            pdfView.leadingAnchor.constraint(equalTo: preview.leadingAnchor), pdfView.trailingAnchor.constraint(equalTo: preview.trailingAnchor),
            welcome.topAnchor.constraint(equalTo: preview.topAnchor), welcome.bottomAnchor.constraint(equalTo: preview.bottomAnchor),
            welcome.leadingAnchor.constraint(equalTo: preview.leadingAnchor), welcome.trailingAnchor.constraint(equalTo: preview.trailingAnchor),
            settings.leadingAnchor.constraint(equalTo: root.leadingAnchor), settings.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.topAnchor.constraint(equalTo: settings.bottomAnchor), footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor), footer.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        split.setPosition(225, ofDividerAt: 0)
        refresh()
        window.makeKeyAndOrderFront(nil)
    }

    func buildWelcome() {
        let icon = NSImageView(image: NSImage(systemSymbolName: "doc.richtext", accessibilityDescription: nil)!)
        icon.contentTintColor = .systemBlue
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 72).isActive = true
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 58, weight: .light)
        let title = NSTextField(labelWithString: "PDF 的图片与大小，一站处理")
        title.font = .systemFont(ofSize: 25, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "导出图片 · 回填页面 · 按大小拆分")
        subtitle.font = .systemFont(ofSize: 15); subtitle.textColor = .secondaryLabelColor
        let open = button("选择 PDF 文件…", symbol: "folder", action: #selector(openPDF), primary: true)
        open.keyEquivalent = "\r"
        let drag = NSTextField(labelWithString: "也可以把 PDF 拖进窗口")
        drag.font = .systemFont(ofSize: 12); drag.textColor = .tertiaryLabelColor
        let steps = NSTextField(wrappingLabelWithString: "① 导出高清 PNG，在外部图片工具中修改\n② 回填图片，旋转页面或调整顺序\n③ 另存 PDF，或直接按指定 MB 上限拆分")
        steps.font = .systemFont(ofSize: 13); steps.textColor = .secondaryLabelColor
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 10
        steps.attributedStringValue = NSAttributedString(string: steps.stringValue, attributes: [.paragraphStyle: paragraph, .font: steps.font!, .foregroundColor: NSColor.secondaryLabelColor])
        let privacy = NSTextField(labelWithString: "离线使用  ·  文件留在本机  ·  保留原文件")
        privacy.font = .systemFont(ofSize: 11); privacy.textColor = .tertiaryLabelColor
        let stack = NSStackView(views: [icon, title, subtitle, open, drag, steps, privacy])
        stack.orientation = .vertical; stack.alignment = .centerX; stack.spacing = 18
        stack.setCustomSpacing(30, after: subtitle); stack.setCustomSpacing(30, after: drag)
        stack.translatesAutoresizingMaskIntoConstraints = false
        welcome.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: welcome.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: welcome.centerYAnchor, constant: -5),
            stack.widthAnchor.constraint(lessThanOrEqualTo: welcome.widthAnchor, constant: -48)
        ])
    }

    func numberOfRows(in tableView: NSTableView) -> Int { document?.pageCount ?? 0 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("PageCell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? PageCell ?? PageCell(frame: .zero)
        cell.identifier = id
        if let page = document?.page(at: row) {
            cell.thumb.image = page.thumbnail(of: NSSize(width: 100, height: 130), for: .mediaBox)
            cell.label.stringValue = "第 \(row + 1) 页"
            cell.detail.stringValue = changedPages.contains(row) ? "已修改" : "原始页面"
            cell.detail.textColor = changedPages.contains(row) ? .systemBlue : .secondaryLabelColor
        }
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSelecting, let page = document?.page(at: selectedIndex) else { return }
        pdfView.go(to: page)
        updatePageLabel()
    }
    @objc func previewPageChanged() {
        guard let document, let page = pdfView.currentPage else { return }
        let index = document.index(for: page)
        guard index != NSNotFound else { return }
        isSelecting = true
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        table.scrollRowToVisible(index)
        isSelecting = false
        updatePageLabel()
    }
    func updatePageLabel() {
        guard let document else { pageLabel.stringValue = ""; return }
        pageLabel.stringValue = "第 \(selectedIndex + 1) / \(document.pageCount) 页"
    }
    func refresh(select index: Int? = nil) {
        let loaded = document != nil
        let selection = index ?? selectedIndex
        actionButtons.forEach { $0.isEnabled = loaded && !busy }
        dpiPopup.isEnabled = !busy; rangePopup.isEnabled = !busy
        table.isEnabled = !busy
        welcome.isHidden = loaded
        pdfView.isHidden = !loaded
        countLabel.stringValue = loaded ? "页面 · \(document!.pageCount)" : "页面"
        isSelecting = true
        table.reloadData()
        if let document, selection < document.pageCount, let page = document.page(at: selection) {
            table.selectRowIndexes(IndexSet(integer: selection), byExtendingSelection: false)
            pdfView.go(to: page)
        }
        isSelecting = false
        updatePageLabel()
        window.title = sourceURL.map { "\($0.lastPathComponent) — \(appName)" } ?? appName
    }
    func setBusy(_ value: Bool, message: String) {
        busy = value; status.stringValue = message
        value ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        refresh()
    }
    func error(_ error: Error) {
        let alert = NSAlert(); alert.messageText = "操作未完成"
        alert.informativeText = error.localizedDescription; alert.alertStyle = .warning
        alert.beginSheetModal(for: window)
    }
    func confirmDiscard() -> Bool {
        guard window?.isDocumentEdited == true else { return true }
        let alert = NSAlert(); alert.messageText = "当前修改尚未另存为 PDF"
        alert.informativeText = "继续操作将放弃窗口中的修改，磁盘上的原 PDF 不受影响。需要保留修改时，请先点「另存 PDF」。"
        alert.addButton(withTitle: "返回保存"); alert.addButton(withTitle: "放弃修改")
        return alert.runModal() == .alertSecondButtonReturn
    }

    @objc func openPDF() {
        guard !busy, confirmDiscard() else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.pdf]
        panel.message = "选择需要处理的 PDF"; panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] result in
            if result == .OK, let url = panel.url { self?.load(url) }
        }
    }
    func load(_ url: URL) {
        guard let doc = PDFDocument(url: url) else { error(WorkshopError.message("无法打开这个 PDF，文件可能已损坏。")); return }
        if doc.isLocked {
            let alert = NSAlert(); alert.messageText = "此 PDF 需要密码"
            alert.informativeText = "请输入文档的打开密码。"
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            alert.accessoryView = field; alert.addButton(withTitle: "解锁"); alert.addButton(withTitle: "取消")
            if alert.runModal() != .alertFirstButtonReturn { return }
            guard doc.unlock(withPassword: field.stringValue) else { error(WorkshopError.message("密码不正确，无法打开 PDF。")); return }
        }
        guard doc.pageCount > 0 else { error(WorkshopError.message("这个 PDF 没有页面。")); return }
        guard doc.allowsPrinting, doc.allowsCopying, doc.allowsDocumentAssembly else {
            error(WorkshopError.message("此 PDF 限制了打印、提取或页面组装。请使用有权限的版本。")); return
        }
        document = doc; sourceURL = url; changedPages = []
        pdfView.document = doc; window.isDocumentEdited = false
        window.representedURL = url
        status.stringValue = "已打开 \(doc.pageCount) 页 · 可导出图片、回填修改，或直接按大小拆分"
        refresh(select: 0)
    }
    func receive(_ urls: [URL]) {
        guard !busy, !urls.isEmpty else { return }
        if let pdf = urls.first(where: { $0.pathExtension.lowercased() == "pdf" }) {
            if confirmDiscard() { load(pdf) }
        } else if document != nil { importReplacements(urls) }
        else { error(WorkshopError.message("请先打开一个 PDF，再拖入修改好的图片。")) }
    }

    @objc func exportImages() {
        guard !busy, let document else { return }
        let indexes = rangePopup.indexOfSelectedItem == 0 ? Array(0..<document.pageCount) : [selectedIndex]
        let dpi = [150, 300, 600][dpiPopup.indexOfSelectedItem]
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.prompt = "导出到这里"
        panel.message = "选择保存位置，将新建文件夹，导出 \(indexes.count) 张 \(dpi) DPI PNG 图片。"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let parent = panel.url, let self else { return }
            let snapshot: Data
            do { snapshot = try PDFEngine.snapshot(document) }
            catch { self.error(error); return }
            let stem = self.sourceURL?.deletingPathExtension().lastPathComponent ?? "PDF"
            self.setBusy(true, message: "正在准备导出 \(indexes.count) 页…")
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    guard let copy = PDFDocument(data: snapshot) else { throw WorkshopError.message("无法读取文档。") }
                    let folder = try PDFEngine.export(copy, indexes: indexes, dpi: dpi, to: parent, stem: stem) { done, total in
                        DispatchQueue.main.async { self.status.stringValue = "正在导出图片 \(done) / \(total)…" }
                    }
                    DispatchQueue.main.async {
                        self.setBusy(false, message: "已导出 \(indexes.count) 张 PNG · 修改后保持 page-0001 等文件名，方便自动匹配")
                        NSWorkspace.shared.open(folder)
                    }
                } catch {
                    DispatchQueue.main.async { self.setBusy(false, message: "导出未完成"); self.error(error) }
                }
            }
        }
    }

    @objc func splitPDF() {
        guard !busy, let document else { return }
        if let splitSheet { splitSheet.panel.makeKeyAndOrderFront(nil); return }
        let sheet = SplitSheet(parent: window, name: sourceURL?.lastPathComponent ?? "当前文档.pdf",
                               pages: document.pageCount, edited: window.isDocumentEdited)
        splitSheet = sheet
        sheet.onClose = { [weak self] in self?.splitSheet = nil }
        sheet.onCancel = { [weak self] in self?.splitCancellation?.cancel() }
        sheet.onStart = { [weak self, weak sheet] limit, destination in
            guard let self, let sheet else { return }
            self.setBusy(true, message: "正在准备拆分当前文档…")
            let snapshot: Data
            do { snapshot = try PDFEngine.snapshot(document) }
            catch { self.setBusy(false, message: "准备拆分失败"); sheet.finish(.failure(error)); return }
            let flag = CancellationFlag(); self.splitCancellation = flag
            let filename = String((self.sourceURL?.deletingPathExtension().lastPathComponent ?? "当前文档").prefix(48)) + ".pdf"
            DispatchQueue.global(qos: .userInitiated).async {
                let result: Result<SplitResult, Error> = Result {
                    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("PDFWorkshop-\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false)
                    defer { try? FileManager.default.removeItem(at: temp) }
                    try flag.check()
                    let input = temp.appendingPathComponent(filename)
                    try snapshot.write(to: input, options: .atomic)
                    return try SplitEngine.run(SplitRequest(source: input, destination: destination, maximumBytes: limit), cancellation: flag) { value in
                        DispatchQueue.main.async {
                            sheet.update(value)
                            self.status.stringValue = "正在拆分 \(value.completedPages) / \(value.totalPages) 页 · \(value.partCount) 份"
                        }
                    }
                }
                DispatchQueue.main.async {
                    self.splitCancellation = nil
                    switch result {
                    case .success(let output): self.setBusy(false, message: "拆分完成 · \(output.parts.count) 份 PDF · 当前修改仍保留在窗口中")
                    case .failure(let error): self.setBusy(false, message: error.localizedDescription)
                    }
                    sheet.finish(result)
                }
            }
        }
        sheet.show()
    }

    @objc func replaceImages() {
        guard !busy, document != nil else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .bmp]
        panel.allowsMultipleSelection = true
        panel.message = "选 1 张替换当前页；选多张时，按 page-0001 等文件名自动匹配原页码。"
        panel.prompt = "选择图片"
        panel.beginSheetModal(for: window) { [weak self] result in
            if result == .OK { self?.importReplacements(panel.urls) }
        }
    }
    func importReplacements(_ urls: [URL]) {
        guard let document, !urls.isEmpty else { return }
        let sorted = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        var assignments: [(URL, Int)] = []
        var method: String
        if sorted.count == 1 {
            assignments = [(sorted[0], selectedIndex)]
            method = "替换当前第 \(selectedIndex + 1) 页。"
        } else {
            let numbers = sorted.map { PDFEngine.pageNumber(in: $0) }
            if numbers.allSatisfy({ $0 != nil && $0! >= 1 && $0! <= document.pageCount }), Set(numbers.compactMap { $0 }).count == sorted.count {
                assignments = zip(sorted, numbers).map { ($0.0, $0.1! - 1) }
                method = "按图片文件名中的页码匹配，共替换 \(sorted.count) 页。"
            } else if sorted.count == document.pageCount {
                assignments = sorted.enumerated().map { ($0.element, $0.offset) }
                method = "按文件名自然排序，依次替换全部 \(sorted.count) 页。"
            } else {
                guard selectedIndex + sorted.count <= document.pageCount else {
                    error(WorkshopError.message("图片数量超过可替换的页数。请使用导出时的 page-0001 等文件名，或从更靠前的页面开始替换。")); return
                }
                assignments = sorted.enumerated().map { ($0.element, selectedIndex + $0.offset) }
                method = "按文件名自然排序，从当前第 \(selectedIndex + 1) 页开始，连续替换 \(sorted.count) 页。"
            }
        }
        let alert = NSAlert(); alert.messageText = "确认页面对应关系"
        let mapping = assignments.prefix(8).map { "\($0.0.lastPathComponent) → 第 \($0.1 + 1) 页" }.joined(separator: "\n")
        alert.informativeText = method + "\n\n" + mapping + (assignments.count > 8 ? "\n…" : "") + "\n\n保持原页面尺寸，图片按比例放入，空白处补白。"
        alert.addButton(withTitle: "替换页面"); alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] result in
            guard result == .alertFirstButtonReturn, let self else { return }
            self.setBusy(true, message: "正在读取替换图片…")
            // Prepare every replacement before touching the document, so one bad image changes nothing.
            let work = assignments.map { (url: $0.0, index: $0.1, size: PDFEngine.displaySize(document.page(at: $0.1)!)) }
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let pages = try work.map { (try PDFEngine.imagePage(from: $0.url, fitting: $0.size), $0.index) }
                    DispatchQueue.main.async {
                        let selected = self.selectedIndex
                        for (page, index) in pages {
                            document.removePage(at: index); document.insert(page, at: index)
                            self.changedPages.insert(index)
                        }
                        self.window.isDocumentEdited = true
                        self.pdfView.document = nil; self.pdfView.document = document
                        self.setBusy(false, message: "已替换 \(pages.count) 页 · 点击「另存 PDF」保存修改")
                        self.refresh(select: selected)
                    }
                } catch {
                    DispatchQueue.main.async { self.setBusy(false, message: "替换未完成，原页面已保留"); self.error(error) }
                }
            }
        }
    }

    @objc func savePDF() {
        guard !busy, let document else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]; panel.canCreateDirectories = true
        panel.nameFieldStringValue = (sourceURL?.deletingPathExtension().lastPathComponent ?? "文档") + "_已修改.pdf"
        panel.message = "保存修改后的 PDF，原文件默认保留。"
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let url = panel.url, let self else { return }
            guard let data = document.dataRepresentation() else { self.error(WorkshopError.message("无法生成 PDF 数据。")); return }
            self.setBusy(true, message: "正在保存 PDF…")
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try data.write(to: url, options: .atomic)
                    DispatchQueue.main.async {
                        self.window.isDocumentEdited = false
                        self.sourceURL = url; self.window.representedURL = url
                        self.setBusy(false, message: "已保存：\(url.lastPathComponent)")
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                } catch {
                    DispatchQueue.main.async { self.setBusy(false, message: "保存失败，修改仍保留在窗口中"); self.error(error) }
                }
            }
        }
    }
    @objc func rotatePage() {
        guard !busy, let page = document?.page(at: selectedIndex) else { return }
        let index = selectedIndex
        page.rotation = (page.rotation + 90) % 360
        changedPages.insert(index); window.isDocumentEdited = true
        pdfView.layoutDocumentView(); refresh(select: index)
        status.stringValue = "当前页已顺时针旋转 90° · 另存 PDF 后生效"
    }
    @objc func moveUp() { move(by: -1) }
    @objc func moveDown() { move(by: 1) }
    func move(by offset: Int) {
        guard !busy, let document else { return }
        let old = selectedIndex; let new = old + offset
        guard new >= 0, new < document.pageCount, let page = document.page(at: old) else { return }
        let wasOld = changedPages.contains(old), wasNew = changedPages.contains(new)
        changedPages.remove(old); changedPages.remove(new)
        if wasOld { changedPages.insert(new) }; if wasNew { changedPages.insert(old) }
        document.removePage(at: old); document.insert(page, at: new)
        window.isDocumentEdited = true
        pdfView.document = nil; pdfView.document = document
        refresh(select: new)
        status.stringValue = "页面顺序已调整 · 另存 PDF 后生效"
    }
    @objc func showHelp() {
        let alert = NSAlert(); alert.messageText = "PDF 工坊使用方法"
        alert.informativeText = "1. 打开 PDF，选择 300 DPI，点击「导出图片」。\n2. 在系统预览、Photoshop 等工具中修改 PNG 并保存。\n3. 回到本 App，选中目标页，点击「替换图片」。\n4. 点击「另存 PDF」，生成修改后的文档。\n\n批量回填：同时选择多张图片，保留 page-0001.png 这样的文件名即可自动匹配页码。只选一张时替换当前页。\n\n原页面尺寸保持不变，图片按比例居中放置。旋转和顺序调整会体现在导出的图片和 PDF 中。\n\n所有处理在本机完成。此工具不包含 OCR 和图片绘画编辑器；扫描清晰度取决于原文件，增大 DPI 无法恢复模糊细节。"
        alert.informativeText += "\n\n按大小拆分：点击工具栏「按大小拆分」，设置 MB 上限和输出目录，再开始拆分。会使用当前窗口中的页面，包含未另存的图片替换、旋转与页序调整。若一页已超限，整次任务会取消并清理未完成结果。1 MB = 1,000,000 字节。\n\n加密文档解锁后，输出不设密码。数字签名、复杂表单与文档级书签不保证保留。"
        alert.addButton(withTitle: "知道了"); alert.beginSheetModal(for: window)
    }
    @objc func about() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: appName, .applicationVersion: "2.0.0",
            .credits: NSAttributedString(string: "PDF 转图片 · 图片回填 · 按大小拆分\n原生 PDFKit，本地处理。MIT 开源许可。")
        ])
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if [#selector(exportImages), #selector(replaceImages), #selector(savePDF), #selector(splitPDF)].contains(item.action) {
            return document != nil && !busy && splitSheet == nil
        }
        if item.action == #selector(openPDF) { return !busy && splitSheet == nil }
        return true
    }
}

@main struct PDFWorkshopApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
