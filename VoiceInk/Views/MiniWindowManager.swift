import SwiftUI
import AppKit

class MiniWindowManager: ObservableObject {
    @Published var isVisible = false
    private var windowController: NSWindowController?
    private var miniPanel: MiniRecorderPanel?
    private let whisperState: WhisperState
    private let audioEngine: AudioEngine
    
    init(whisperState: WhisperState, audioEngine: AudioEngine) {
        self.whisperState = whisperState
        self.audioEngine = audioEngine
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleHideNotification),
            name: NSNotification.Name("HideMiniRecorder"),
            object: nil
        )
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    @objc private func handleHideNotification() {
        hide()
    }
    
    func show() {
        if isVisible { return }
        
        let activeScreen = NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        
        initializeWindow(screen: activeScreen)
        self.isVisible = true
        miniPanel?.show()
    }
    
    func hide() {
        guard isVisible else { return }
        
        withAnimation(.easeOut(duration: 0.5)) {
            self.isVisible = false
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.miniPanel?.hide { [weak self] in
                guard let self = self else { return }
                self.deinitializeWindow()
            }
        }
    }
    
    private func initializeWindow(screen: NSScreen) {
        deinitializeWindow()
        
        let metrics = MiniRecorderPanel.calculateWindowMetrics()
        let panel = MiniRecorderPanel(contentRect: metrics)
        
        let miniRecorderView = MiniRecorderView(whisperState: whisperState, audioEngine: audioEngine)
            .environmentObject(self)
        
        let hostingController = NSHostingController(rootView: miniRecorderView)
        panel.contentView = hostingController.view
        
        self.miniPanel = panel
        self.windowController = NSWindowController(window: panel)
        
        panel.orderFrontRegardless()
    }
    
    private func deinitializeWindow() {
        windowController?.close()
        windowController = nil
        miniPanel = nil
    }
    
    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }
} 