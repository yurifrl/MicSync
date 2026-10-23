import Testing
import Foundation
import AppKit
import Combine
@testable import KeyboardShortcuts

extension KeyboardShortcutsTests {
	@Test("RecorderCocoa has default size")
	func testRecorderDefaultSize() throws {
		let recorder = KeyboardShortcuts.RecorderCocoa(for: .init("test"))

		#expect(recorder.frame.width >= 130)
		#expect(recorder.frame.height > 0)
	}

	@Test("RecorderCocoa works with addSubview")
	func testRecorderAddSubview() throws {
		let recorder = KeyboardShortcuts.RecorderCocoa(for: .init("test"))
		let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))

		containerView.addSubview(recorder)

		#expect(recorder.frame.size != .zero)
	}

	@Test
	func `shortcut text is centered in the field`() throws {
		let recorder = KeyboardShortcuts.RecorderCocoa(shortcut: .init(.k, modifiers: [.command, .shift]))

		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 50), styleMask: .borderless, backing: .buffered, defer: false)
		window.contentView!.addSubview(recorder)
		recorder.frame = NSRect(x: 35, y: 13, width: 130, height: 24)
		window.orderBack(nil)
		window.display()

		// The clip view is only created when the window is displayed on a real display server.
		guard let clipView = recorder.subviews.first(where: { NSStringFromClass(type(of: $0)).contains("ClipView") }) else {
			return
		}

		#expect(clipView.frame.midX == recorder.bounds.midX)
	}

	@Test("RecorderCocoa supports direct shortcut storage")
	func testRecorderDirectShortcutStorage() throws {
		let shortcut = KeyboardShortcuts.Shortcut(.k, modifiers: [.command, .shift])
		let recorder = KeyboardShortcuts.RecorderCocoa(shortcut: shortcut)

		#expect(recorder.shortcut == shortcut)
		#expect(recorder.stringValue == "\(shortcut)")

		recorder.shortcut = nil

		#expect(recorder.shortcut == nil)
		#expect(recorder.stringValue.isEmpty)
	}

	@Test("RecorderCocoa direct mode handles multiple shortcut changes")
	func testRecorderDirectModeMultipleChanges() throws {
		let shortcut1 = KeyboardShortcuts.Shortcut(.a, modifiers: [.command])
		let shortcut2 = KeyboardShortcuts.Shortcut(.b, modifiers: [.command, .shift])
		let shortcut3 = KeyboardShortcuts.Shortcut(.c, modifiers: [.option, .control])

		let recorder = KeyboardShortcuts.RecorderCocoa(shortcut: nil)
		#expect(recorder.shortcut == nil)
		#expect(recorder.stringValue.isEmpty)

		recorder.shortcut = shortcut1
		#expect(recorder.shortcut == shortcut1)
		#expect(recorder.stringValue == "\(shortcut1)")

		recorder.shortcut = shortcut2
		#expect(recorder.shortcut == shortcut2)
		#expect(recorder.stringValue == "\(shortcut2)")

		recorder.shortcut = shortcut3
		#expect(recorder.shortcut == shortcut3)
		#expect(recorder.stringValue == "\(shortcut3)")

		recorder.shortcut = nil
		#expect(recorder.shortcut == nil)
		#expect(recorder.stringValue.isEmpty)
	}

	@Test("RecorderCocoa direct mode ignores redundant updates")
	func testRecorderDirectModeRedundantUpdates() throws {
		let shortcut = KeyboardShortcuts.Shortcut(.k, modifiers: [.command])
		let recorder = KeyboardShortcuts.RecorderCocoa(shortcut: shortcut)

		let originalStringValue = recorder.stringValue

		// Setting the same shortcut again should not cause issues
		recorder.shortcut = shortcut
		#expect(recorder.shortcut == shortcut)
		#expect(recorder.stringValue == originalStringValue)
	}

	@Test("RecorderCocoa supports validateShortcut")
	func testRecorderValidateShortcut() throws {
		let recorder = KeyboardShortcuts.RecorderCocoa(for: .init("test"))

		#expect(recorder.validateShortcut == nil)

		recorder.validateShortcut = { _ in
			.disallow(reason: "Test error")
		}

		#expect(recorder.validateShortcut != nil)

		let shortcut = KeyboardShortcuts.Shortcut(.k, modifiers: [.command])
		let result = recorder.validateShortcut?(shortcut)
		#expect(result == .disallow(reason: "Test error"))
	}

	@Test
	func `switching directly between recorders keeps shortcut handling paused`() async {
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100), styleMask: .borderless, backing: .buffered, defer: false)
		let firstRecorder = KeyboardShortcuts.RecorderCocoa(shortcut: nil)
		let secondRecorder = KeyboardShortcuts.RecorderCocoa(shortcut: nil)
		window.contentView = NSStackView(views: [firstRecorder, secondRecorder])
		var activeStates = [Bool]()
		let observation = NotificationCenter.default.publisher(for: .recorderActiveStatusDidChange).sink {
			activeStates.append($0.recorderIsActive)
		}

		defer {
			observation.cancel()
			KeyboardShortcuts.isPaused = false
		}

		#expect(window.makeFirstResponder(firstRecorder))
		firstRecorder.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: firstRecorder))
		#expect(window.makeFirstResponder(secondRecorder))

		await Task.yield()

		#expect(KeyboardShortcuts.isPaused)
		#expect(!activeStates.contains(false))
	}

	@Test
	func `ending recording restores the shared field editor caret`() async throws {
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100), styleMask: .borderless, backing: .buffered, defer: false)
		let recorder = KeyboardShortcuts.RecorderCocoa(shortcut: nil)
		let textField = NSTextField()
		window.contentView = NSStackView(views: [recorder, textField])

		#expect(window.makeFirstResponder(recorder))
		let fieldEditor = try #require(recorder.currentEditor() as? NSTextView)
		#expect(fieldEditor.insertionPointColor == .clear)

		recorder.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: recorder))
		#expect(window.makeFirstResponder(textField))

		await Task.yield()

		#expect(textField.currentEditor() === fieldEditor)
		#expect(fieldEditor.insertionPointColor == .labelColor)
	}
}
