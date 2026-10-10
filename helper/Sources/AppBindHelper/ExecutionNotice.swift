import AppKit

/// Transient on-screen notice for a shortcut trigger that produced no input.
///
/// The helper is the only AppBind process alive when a trigger is refused: the Raycast
/// extension spawns the resident service and exits, and Raycast unloads `view`,
/// `no-view` and `menu-bar` commands between launches. `showToast`/`showHUD` exist only
/// inside an extension's JavaScript process, so refusal feedback has to be drawn here.
///
/// The style copies Raycast's own HUD: a blurred dark capsule at the bottom of the
/// screen, an icon tile on the left and white text. Proportions follow Raycast's
/// published HUD reference (icon tile about half the capsule height, ends fully
/// rounded). The extension icon is used when the support directory provides one;
/// otherwise the same tile carries a warning symbol.
///
/// The notice is decorative: it posts no events, never activates another application,
/// ignores the mouse, and disappears on its own. The panel belongs to this process and
/// is therefore excluded from the CG occlusion check (`WindowIdentity.resolve(ownPID:)`);
/// otherwise a retry during the notice's lifetime would fail closed against our overlay.
@MainActor
final class ExecutionNotice {
    static let shared = ExecutionNotice()

    private var panel: NSPanel?
    private var pending: DispatchWorkItem?
    private var prepared = false
    private var generation = 0

    private let lifetime: TimeInterval = 2.5
    private let verticalPadding: CGFloat = 14
    private let horizontalPadding: CGFloat = 20
    private let iconSize: CGFloat = 30
    private let gap: CGFloat = 13
    private let maximumTextWidth: CGFloat = 340
    private let bottomInset: CGFloat = 48

    private init() {}

    func show(code: String, message: String, icon: NSImage?) {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        prepare()
        let view = NoticeView(title: code == "CANCELLED" ? "执行已取消" : "执行被拒绝",
                              message: text,
                              icon: icon,
                              tint: code == "CANCELLED" ? .systemYellow : .systemOrange,
                              iconSize: iconSize,
                              horizontalPadding: horizontalPadding,
                              verticalPadding: verticalPadding,
                              gap: gap,
                              maximumTextWidth: maximumTextWidth)
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // Size the window from the measured body before installing it: installing a
        // content view resizes that view to the window's content rect, so the other
        // order would silently clamp every notice to the panel's initial height.
        panel.setContentSize(view.noticeSize)
        panel.contentView = view
        position(panel)
        panel.orderFrontRegardless()
        // A later notice replaces an earlier one instead of stacking panels.
        generation += 1
        let token = generation
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token else { return }
            self.dismiss()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + lifetime, execute: work)
    }

    /// Hide immediately; called when the service stops.
    func dismiss() {
        pending?.cancel(); pending = nil
        panel?.orderOut(nil)
    }

    /// An unbundled process can order a window front without starting `NSApp.run()`
    /// (verified against the WindowServer); only the accessory policy is needed so the
    /// panel never takes a Dock slot or activation.
    private func prepare() {
        guard !prepared else { return }
        prepared = true
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 60),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return panel
    }

    /// Bottom centre of the display holding the pointer, where Raycast places its HUD.
    private func position(_ panel: NSPanel) {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame, size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.minX + (visible.width - size.width) / 2,
                                     y: visible.minY + bottomInset))
    }
}

/// Fixed-size notice body, measured from its text so the capsule always ends in true
/// semicircles. Layout is manual so it never depends on an event loop this process does
/// not run.
private final class NoticeView: NSView {
    /// Measured size of this notice, used to size the hosting panel.
    let noticeSize: NSSize

    init(title: String, message: String, icon: NSImage?, tint: NSColor, iconSize: CGFloat,
         horizontalPadding: CGFloat, verticalPadding: CGFloat, gap: CGFloat, maximumTextWidth: CGFloat) {
        let titleFont = NSFont.systemFont(ofSize: 16, weight: .semibold)
        let messageFont = NSFont.systemFont(ofSize: 13)
        let titleText = NSAttributedString(string: title, attributes: [
            .font: titleFont,
            .foregroundColor: NSColor.white,
        ])
        let messageText = NSAttributedString(string: message, attributes: [
            .font: messageFont,
            .foregroundColor: NSColor.white.withAlphaComponent(0.72),
        ])
        let textWidth = max(80, min(maximumTextWidth, max(titleText.size().width, messageText.size().width)))
        func measured(_ text: NSAttributedString, lines: Int) -> CGFloat {
            let height = ceil(text.boundingRect(with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
                                                options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
            let font = (text.attributes(at: 0, effectiveRange: nil)[.font] as? NSFont) ?? messageFont
            let line = ceil(font.ascender - font.descender + font.leading)
            return min(height, line * CGFloat(lines))
        }
        let titleHeight = measured(titleText, lines: 1)
        // Three lines: a refusal names the covering window, and truncating that detail
        // would leave the notice saying only that something is in the way.
        let messageHeight = measured(messageText, lines: 3)
        let contentHeight = max(iconSize, titleHeight + 2 + messageHeight)
        let size = NSSize(width: horizontalPadding * 2 + iconSize + gap + textWidth,
                          height: verticalPadding * 2 + contentHeight)
        noticeSize = size
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true

        // Raycast's HUD is a blurred dark capsule with a hairline highlight; the
        // `.hudWindow` material is AppKit's matching backdrop.
        let backdrop = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = size.height / 2
        backdrop.layer?.masksToBounds = true
        backdrop.layer?.borderWidth = 1
        backdrop.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.12).cgColor

        let tile = NSImageView(frame: NSRect(x: horizontalPadding,
                                             y: verticalPadding + (contentHeight - iconSize) / 2,
                                             width: iconSize, height: iconSize))
        tile.imageScaling = .scaleProportionallyUpOrDown
        tile.imageAlignment = .alignCenter
        tile.wantsLayer = true
        tile.layer?.cornerRadius = iconSize * 0.3
        tile.layer?.masksToBounds = true
        tile.layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.06).cgColor
        if let icon {
            tile.image = icon
        } else {
            tile.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
            tile.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: iconSize * 0.55, weight: .semibold)
            tile.contentTintColor = tint
        }

        let textLeft = horizontalPadding + iconSize + gap
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.attributedStringValue = titleText
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.frame = NSRect(x: textLeft, y: verticalPadding, width: textWidth, height: titleHeight)

        let messageLabel = NSTextField(labelWithString: message)
        messageLabel.attributedStringValue = messageText
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 3
        messageLabel.cell?.wraps = true
        messageLabel.cell?.isScrollable = false
        messageLabel.cell?.truncatesLastVisibleLine = true
        messageLabel.frame = NSRect(x: textLeft, y: verticalPadding + titleHeight + 2, width: textWidth, height: messageHeight)

        addSubview(backdrop); addSubview(tile); addSubview(titleLabel); addSubview(messageLabel)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }
}
