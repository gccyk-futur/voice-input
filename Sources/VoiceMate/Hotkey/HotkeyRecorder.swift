import SwiftUI
import AppKit
import Carbon.HIToolbox

/// 系统风格的热键录制控件：点击进入录制，捕获下一次按键组合，
/// 以 "Cmd+Shift+V" 形式写回 binding，杜绝手填非法字符串导致热键失效。
struct HotkeyRecorder: NSViewRepresentable {
    @Binding var hotkeyString: String

    func makeNSView(context: Context) -> HotkeyRecorderField {
        let field = HotkeyRecorderField()
        field.coordinator = context.coordinator
        field.update(stringValue: hotkeyString)
        return field
    }

    func updateNSView(_ nsView: HotkeyRecorderField, context: Context) {
        nsView.update(stringValue: hotkeyString)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(binding: $hotkeyString)
    }

    @MainActor
    final class Coordinator: NSObject {
        let binding: Binding<String>
        var recording = false
        /// 事件监听令牌。写发生在 start()（MainActor），读发生在 stop() 和 deinit。
        /// 用 nonisolated(unsafe) 标记以允许 deinit（非isolated）读取；
        /// 实际读写不会并发——stop() 和 deinit 是互斥的。
        nonisolated(unsafe) var monitor: Any?
        weak var field: HotkeyRecorderField?

        init(binding: Binding<String>) {
            self.binding = binding
            super.init()
        }

        deinit {
            // 清理残留监听器，防止 Coordinator 意外释放导致泄漏
            if let m = monitor {
                NSEvent.removeMonitor(m)
            }
        }

        func toggle(field: HotkeyRecorderField) {
            recording ? stop() : start(field: field)
        }

        private func start(field: HotkeyRecorderField) {
            guard !recording else { return }
            // 先清理上一个残留监听器（防止崩溃/视图重建导致的泄漏）
            if let old = monitor {
                NSEvent.removeMonitor(old)
                monitor = nil
            }
            recording = true
            self.field = field
            field.setRecording(true)

            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                let keyCode = event.keyCode
                let flags = event.modifierFlags
                let swallow = MainActor.assumeIsolated { self.handle(keyCode: keyCode, flags: flags) }
                return swallow ? nil : event
            }
        }

        /// 处理一次按键：ESC 取消、单独修饰键放行、有效组合则提交并停止。
        /// 返回 true 表示吞掉该事件（录制期间避免触发应用内其他快捷键）。
        @MainActor private func handle(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
            if keyCode == 0x35 { // ESC 取消
                stop()
                return true
            }
            let modifierOnly: Set<UInt16> = [0x37, 0x38, 0x3B, 0x3A, 0x39] // cmd/shift/option/ctrl/caps
            if modifierOnly.contains(keyCode) { return false }

            var carbon: UInt32 = 0
            if flags.contains(.command) { carbon |= UInt32(cmdKey) }
            if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
            if flags.contains(.option) { carbon |= UInt32(optionKey) }
            if flags.contains(.control) { carbon |= UInt32(controlKey) }

            binding.wrappedValue = HotkeyManager.format(keyCode: UInt32(keyCode), modifiers: carbon)
            stop()
            return true
        }

        @MainActor private func stop() {
            recording = false
            if let m = monitor {
                NSEvent.removeMonitor(m)
                monitor = nil
            }
            field?.setRecording(false)
            field = nil
        }
    }
}

final class HotkeyRecorderField: NSView {
    weak var coordinator: HotkeyRecorder.Coordinator?
    private let label = NSTextField(labelWithString: "未设置")
    private var current: String = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

        label.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        label.textColor = .labelColor
        label.drawsBackground = false
        label.isBezeled = false
        label.isEditable = false
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
        let click = NSClickGestureRecognizer(target: self, action: #selector(toggle))
        addGestureRecognizer(click)
    }

    func update(stringValue: String) {
        current = stringValue
        if coordinator?.recording != true {
            label.stringValue = stringValue.isEmpty ? "未设置" : stringValue
        }
    }

    func setRecording(_ recording: Bool) {
        layer?.borderColor = recording ? NSColor.controlAccentColor.cgColor : NSColor.separatorColor.cgColor
        label.stringValue = recording ? "请按下组合键…（ESC 取消）" : (current.isEmpty ? "未设置" : current)
    }

    @objc private func toggle() {
        coordinator?.toggle(field: self)
    }
}
