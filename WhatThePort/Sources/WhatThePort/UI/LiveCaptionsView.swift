import AppKit
import SwiftUI

struct LiveCaptionsView: View {
    @ObservedObject var captions: LiveCaptions
    @State private var settingsOpen = false
    @State private var historyOpen = false
    @State private var history: [CaptionSegment] = []
    var previewTransparent: Bool? = nil
    var previewControls = false
    var resize: (CGFloat) -> Void = { _ in }
    @State private var contentHeight: CGFloat = 100
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(Preferences.captionTransparent) private var transparentPreference = false
    @AppStorage(Preferences.captionShowOriginal) private var showOriginal = true
    @FocusState private var focusedControl: Control?
    private enum Control { case settings, history, close }
    private var transparent: Bool { previewTransparent ?? transparentPreference }
    private var primaryText: Color { transparent ? .white : Theme.text1 }
    private var secondaryText: Color { transparent ? Color.white.opacity(0.78) : Theme.text2 }

    private var secondaryControlsVisible: Bool { previewControls || hovered || focusedControl != nil || settingsOpen || historyOpen }
    private var canConfigure: Bool { captions.phase == .idle || captions.phase == .failed }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Circle().fill(captions.receivesAudio ? Color.green : Theme.text3).frame(width: 6, height: 6)
                Text(L10n.text(status)).font(.system(size: 13)).foregroundStyle(secondaryText).lineLimit(1)
                Text(L10n.text(route)).font(.system(size: 12)).foregroundStyle(secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button {
                    history = Array(captions.segments.reversed())
                    historyOpen = true
                } label: { Image(systemName: "clock.arrow.circlepath").font(.system(size: 13)) }
                .buttonStyle(.plain).foregroundStyle(secondaryText).padding(5)
                .opacity(secondaryControlsVisible ? 1 : 0)
                .focused($focusedControl, equals: .history)
                .accessibilityLabel(L10n.text("Review"))
                .help(L10n.text("Review"))
                .disabled(captions.segments.isEmpty)
                .popover(isPresented: $historyOpen, arrowEdge: .top) { historyView }
                Button { settingsOpen.toggle() } label: {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .foregroundStyle(secondaryText)
                .padding(5)
                .opacity(secondaryControlsVisible ? 1 : 0)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: secondaryControlsVisible)
                .focused($focusedControl, equals: .settings)
                .accessibilityLabel(L10n.text("Caption settings"))
                .help(L10n.text("Caption settings"))
                .popover(isPresented: $settingsOpen, arrowEdge: .top) { settings }
                Button(L10n.text(captions.isActive ? "Stop" : "Start")) {
                    if captions.isActive { captions.stop() } else { captions.start() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12)).foregroundStyle(secondaryText)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7).strokeBorder(secondaryText.opacity(0.3)))
                .disabled(captions.phase == .stopping)
                Button { LiveCaptionsWindow.shared.close() } label: {
                    Image(systemName: "xmark").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(secondaryText)
                .padding(5)
                .opacity(secondaryControlsVisible ? 1 : 0)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: secondaryControlsVisible)
                .focused($focusedControl, equals: .close)
                .accessibilityLabel(L10n.text("Close and stop captions"))
                .help(L10n.text("Close and stop captions"))
                .keyboardShortcut("w", modifiers: .command)
            }
            .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 14)
            .opacity(!transparent || secondaryControlsVisible ? 1 : 0)

            Group {
                if contentHeight > 420 {
                    ScrollView(showsIndicators: false) { captionContent }.frame(height: 420)
                } else {
                    captionContent
                }
            }
        }
        .background(transparent ? Color.clear : Theme.adaptive(light: 0xF0F0F0, dark: 0x242426))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(transparent ? Color.clear : Theme.separator, lineWidth: 1))
        .shadow(color: transparent ? .black.opacity(0.85) : .clear, radius: 2, y: 1)
        .frame(minWidth: 420)
        .onPreferenceChange(CaptionContentHeight.self) { height in
            guard height > 0 else { return }
            contentHeight = height
            resize(min(height, 420) + 54)
        }
        .onHover { hovered = $0 }
    }

    private var captionContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let segment = captions.segments.last {
                subtitle(segment, history: false)
            } else {
                Text(L10n.text(captions.isActive ? "Waiting for speech…" : "Ready when you are"))
                    .font(.system(size: 24, weight: .medium)).foregroundStyle(primaryText)
                Text(L10n.text("Play computer audio to see captions here."))
                    .font(.system(size: 14)).foregroundStyle(secondaryText)
            }
            if let error = captions.error {
                Text(error).font(.system(size: 13)).foregroundStyle(Theme.red).textSelection(.enabled)
                if let url = captions.permissionURL {
                    Button(L10n.text("System Settings…")) { NSWorkspace.shared.open(url) }
                }
            }
            if captions.segments.isEmpty && !captions.isActive {
                Text(L10n.text(disclosure)).font(.system(size: 12)).foregroundStyle(secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20).padding(.bottom, 20)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: CaptionContentHeight.self, value: proxy.size.height)
        })
    }

    private var historyView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("Recent captions")).font(.system(size: 14, weight: .medium))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(history) { segment in subtitle(segment, history: true) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(18).frame(width: 420, height: 280)
    }

    @ViewBuilder private func subtitle(_ segment: CaptionSegment, history: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if segment.language == .chinese {
                Text(segment.original).font(.system(size: history ? 18 : 24, weight: .medium))
                    .foregroundStyle(history ? Theme.text1 : primaryText).textSelection(.enabled)
            } else {
                if let translated = segment.translated {
                    Text(translated).font(.system(size: history ? 18 : 24, weight: .medium))
                        .foregroundStyle(history ? Theme.text1 : primaryText).textSelection(.enabled)
                } else {
                    Text(segment.original).font(.system(size: history ? 18 : 24, weight: .medium))
                        .foregroundStyle(history ? Theme.text1 : primaryText).textSelection(.enabled)
                    Text(segment.translationError ?? L10n.text(history ? "Translation not available" : captions.isActive ? "Translating this segment…" : "Translation stopped"))
                        .font(.system(size: 12)).foregroundStyle(segment.translationError == nil ? Theme.text2 : Theme.red)
                }
                if showOriginal && segment.translated != nil {
                    Text(segment.original).font(.system(size: 14)).foregroundStyle(history ? Theme.text2 : secondaryText).textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("Caption settings")).font(.system(size: 14, weight: .medium))
            Picker(L10n.text("Recognition"), selection: $captions.source) {
                ForEach(LiveCaptions.Source.allCases, id: \.rawValue) { Text($0.label).tag($0) }
            }.disabled(!canConfigure)
            Picker(L10n.text("Speech language"), selection: $captions.language) {
                ForEach(LiveCaptions.Language.allCases, id: \.rawValue) { Text($0.label).tag($0) }
            }.disabled(!canConfigure)
            if !canConfigure {
                Text(L10n.text("Stop captions before changing the model or language."))
                    .font(.system(size: 12)).foregroundStyle(Theme.text2)
            }
            Picker(L10n.text("Viewing mode"), selection: $transparentPreference) {
                Text(L10n.text("Solid panel")).tag(false)
                Text(L10n.text("Transparent subtitles")).tag(true)
            }
            Toggle(L10n.text("Show original text"), isOn: $showOriginal)
            Divider()
            Text(L10n.text(disclosure)).font(.system(size: 12)).foregroundStyle(Theme.text2)
            Text(L10n.text("No microphone · Closing stops capture"))
                .font(.system(size: 12)).foregroundStyle(Theme.text2)
        }.padding(18).frame(width: 350)
    }

    private var route: String {
        if captions.source == .local {
            return captions.language == .english ? "Local ASR · Cloud translation" : "Local · Chinese"
        }
        return captions.language == .english ? "Cloud · English → Chinese" : "Cloud · Chinese"
    }
    private var disclosure: String {
        if captions.source == .cloud {
            return captions.language == .english
                ? "Audio → StepAudio 2.5 ASR · English text → Step 3.7 Flash · Uses Step Plan"
                : "Audio → StepAudio 2.5 ASR · Uses Step Plan · No translation"
        }
        return captions.language == .english
            ? "Audio stays on this Mac · English text → Step 3.7 Flash · Uses Step Plan"
            : "Audio stays on this Mac · SenseVoice-Small · Temporary audio deleted after recognition"
    }
    private var status: String {
        switch captions.phase {
        case .idle: return "Captions stopped"
        case .preparing: return "Preparing captions…"
        case .listening:
            if captions.recognizing { return "Recognizing audio segment…" }
            return captions.receivesAudio ? "Receiving computer audio" : "Listening for computer audio…"
        case .stopping: return "Stopping captions…"
        case .failed: return "Couldn’t start captions"
        }
    }
}

private struct CaptionContentHeight: PreferenceKey {
    static let defaultValue: CGFloat = 100
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Borderless so the subtitle, not standard window chrome, remains the primary content.
private final class CaptionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class LiveCaptionsWindow: NSObject, NSWindowDelegate {
    static let shared = LiveCaptionsWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = CaptionPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 173),
                                      styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
            window.title = L10n.text("Live captions")
            window.contentView = NSHostingView(rootView: LiveCaptionsView(captions: .shared, resize: { [weak window] height in
                guard let window, abs(window.frame.height - height) > 1 else { return }
                var frame = window.frame
                frame.size.height = height
                window.setFrame(frame, display: true)
            }))
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.isMovableByWindowBackground = true
            window.isFloatingPanel = true
            window.hidesOnDeactivate = false
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 420, height: 120)
            window.delegate = self
            window.setFrameAutosaveName("LiveCaptionsCompactV2")
            if !window.setFrameUsingName("LiveCaptionsCompactV2") {
                let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
                window.setFrameOrigin(NSPoint(x: screen.midX - 320, y: screen.minY + 60))
            }
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }
    func windowWillClose(_ notification: Notification) { LiveCaptions.shared.stop() }
}
