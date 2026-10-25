import AppKit
import WorkshopCore

@MainActor final class SplitSheet: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    let panel: NSPanel
    private let parent: NSWindow
    private let limitField = NSTextField(string: "10")
    private let presets = NSSegmentedControl(labels: ["5 MB", "10 MB", "20 MB", "50 MB"], trackingMode: .selectOne, target: nil, action: nil)
    private let folderLabel = NSTextField(labelWithString: "")
    private let chooseButton = NSButton(title: "更改…", target: nil, action: nil)
    private let message = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let resultView = NSTextView()
    private let resultScroll = NSScrollView()
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    private let startButton = NSButton(title: "开始拆分", target: nil, action: nil)
    private var running = false
    private var output: URL?
    var destination = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    var onStart: ((Int, URL) -> Void)?
    var onCancel: (() -> Void)?
    var onClose: (() -> Void)?

    init(parent: NSWindow, name: String, pages: Int, edited: Bool) {
        self.parent = parent
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 570, height: 390),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        panel.title = "按大小拆分 PDF"
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        let title = NSTextField(labelWithString: "让每一份，都刚刚好")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString: "\(name) · \(pages) 页" + (edited ? "\n将包含当前尚未另存的图片替换、旋转和页序调整。" : "\n按当前页面顺序拆分，不压缩页面画质。"))
        detail.font = .systemFont(ofSize: 12); detail.textColor = .secondaryLabelColor
        presets.target = self; presets.action = #selector(presetChanged)
        presets.selectedSegment = 1
        limitField.delegate = self
        limitField.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        limitField.widthAnchor.constraint(equalToConstant: 105).isActive = true
        limitField.setAccessibilityLabel("每份最大 MB")
        let limitRow = NSStackView(views: [NSTextField(labelWithString: "每份文件最大"), limitField, NSTextField(labelWithString: "MB")])
        limitRow.spacing = 10
        let units = NSTextField(labelWithString: "支持自定义 0.01–100,000 MB，1 MB = 1,000,000 字节。")
        units.font = .systemFont(ofSize: 10); units.textColor = .secondaryLabelColor
        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.font = .systemFont(ofSize: 11)
        folderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        chooseButton.target = self; chooseButton.action = #selector(chooseFolder)
        let folderRow = NSStackView(views: [NSImageView(image: NSImage(systemSymbolName: "folder", accessibilityDescription: nil)!), folderLabel, chooseButton])
        folderRow.spacing = 10
        chooseButton.setContentHuggingPriority(.required, for: .horizontal)
        message.font = .systemFont(ofSize: 11); message.textColor = .secondaryLabelColor
        message.stringValue = "按完整页面拆分，每份按实际大小校验。单页超限会提示调整；原文件保持不变。加密文档解锁后，导出的副本不设密码。"
        progress.style = .bar; progress.isIndeterminate = false; progress.maxValue = Double(max(1, pages)); progress.isHidden = true
        resultView.isEditable = false; resultView.isSelectable = true
        resultView.frame = NSRect(x: 0, y: 0, width: 510, height: 100)
        resultView.isVerticallyResizable = true; resultView.isHorizontallyResizable = false
        resultView.autoresizingMask = [.width]
        resultView.textContainer?.containerSize = NSSize(width: 510, height: CGFloat.greatestFiniteMagnitude)
        resultView.textContainer?.widthTracksTextView = true
        resultView.textColor = .labelColor
        resultView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        resultView.textContainerInset = NSSize(width: 8, height: 8)
        resultScroll.documentView = resultView; resultScroll.hasVerticalScroller = true
        resultScroll.borderType = .bezelBorder; resultScroll.isHidden = true
        resultScroll.heightAnchor.constraint(equalToConstant: 100).isActive = true
        cancelButton.target = self; cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        startButton.target = self; startButton.action = #selector(start)
        startButton.bezelStyle = .rounded; startButton.keyEquivalent = "\r"; startButton.bezelColor = .systemBlue
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actions = NSStackView(views: [spacer, cancelButton, startButton]); actions.spacing = 10
        let stack = NSStackView(views: [title, detail, presets, limitRow, units, folderRow, message, progress, resultScroll, actions])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 15
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 26),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -26),
            stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 23),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: panel.contentView!.bottomAnchor, constant: -23),
            detail.widthAnchor.constraint(equalTo: stack.widthAnchor),
            folderRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            message.widthAnchor.constraint(equalTo: stack.widthAnchor),
            progress.widthAnchor.constraint(equalTo: stack.widthAnchor),
            resultScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        updateFolder()
    }

    func show() { parent.beginSheet(panel) }
    private func updateFolder() {
        folderLabel.stringValue = destination.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        folderLabel.toolTip = destination.path
    }
    @objc private func presetChanged() {
        guard presets.selectedSegment >= 0 else { return }
        limitField.stringValue = String([5, 10, 20, 50][presets.selectedSegment])
    }
    func controlTextDidChange(_ obj: Notification) { presets.selectedSegment = -1 }
    @objc private func chooseFolder() {
        let picker = NSOpenPanel()
        picker.canChooseFiles = false; picker.canChooseDirectories = true; picker.canCreateDirectories = true
        picker.directoryURL = destination; picker.prompt = "选择此文件夹"
        picker.beginSheetModal(for: panel) { [weak self] response in
            if response == .OK, let url = picker.url { self?.destination = url; self?.updateFolder() }
        }
    }
    @objc private func start() {
        if let output { NSWorkspace.shared.open(output); return }
        guard let value = Double(limitField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              value.isFinite, value >= 0.01, value <= 100_000 else {
            message.stringValue = SplitError.invalidLimit.localizedDescription; message.textColor = .systemRed; return
        }
        running = true
        [limitField, presets, chooseButton, startButton].forEach { $0.isEnabled = false }
        cancelButton.title = "取消任务"
        progress.doubleValue = 0; progress.isHidden = false
        message.textColor = .secondaryLabelColor; message.stringValue = "正在准备当前文档副本…"
        onStart?(Int((value * 1_000_000).rounded(.down)), destination)
    }
    @objc private func cancel() {
        if running {
            onCancel?(); cancelButton.isEnabled = false; message.stringValue = "正在取消，将清理未完成结果…"
        } else {
            parent.endSheet(panel); onClose?()
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { cancel(); return false }
    func update(_ value: SplitProgress) {
        progress.doubleValue = Double(value.completedPages)
        message.stringValue = "已处理 \(value.completedPages) / \(value.totalPages) 页 · 已校验 \(value.partCount) 份"
    }
    func finish(_ result: Result<SplitResult, Error>) {
        running = false; cancelButton.isEnabled = true; cancelButton.title = "关闭"
        startButton.isEnabled = true
        switch result {
        case .success(let result):
            output = result.folder; progress.isHidden = true
            message.textColor = .systemGreen
            message.stringValue = "已导出 \(result.parts.count) 份，共 \(result.sourcePageCount) 页，全部通过大小校验。"
            resultView.string = result.parts.map { part in
                "\(part.url.lastPathComponent)\n" + (part.pageCount == 1 ? "第 \(part.firstPage) 页" : "第 \(part.firstPage)–\(part.lastPage) 页") + " · \(SplitError.size(part.byteCount))"
            }.joined(separator: "\n\n")
            resultScroll.isHidden = false
            startButton.title = "打开导出文件夹"
            panel.setContentSize(NSSize(width: 570, height: 500))
        case .failure(let error):
            progress.isHidden = true
            message.textColor = .systemRed; message.stringValue = error.localizedDescription
            [limitField, presets, chooseButton].forEach { $0.isEnabled = true }
            cancelButton.title = "取消"
        }
    }
}
