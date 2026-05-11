#if os(iOS)
//
//  RemoteKeyboardTextField.swift
//  RoyalVNCiOSDemo
//
//  Custom UITextField that captures hardware keyboard input for VNC.
//
//  Features:
//  - Intercepts hardware key presses (arrows, function keys, etc.)
//  - Handles modifier keys (CMD/CTRL/OPT/SHIFT) separately
//  - Maps UIKeyboardHIDUsage to VNC key codes
//  - Supports backspace via deleteBackward override
//

import UIKit

import RoyalVNCKit

final class RemoteKeyboardTextField: UITextField {
	private static let modifierKeyCodes: [UIKeyboardHIDUsage: VNCKeyCode] = [
		.keyboardLeftShift: .shift,
		.keyboardRightShift: .rightShift,
		.keyboardLeftControl: .control,
		.keyboardRightControl: .rightControl,
		.keyboardLeftAlt: .option,
		.keyboardRightAlt: .rightOption,
		.keyboardLeftGUI: .command,
		.keyboardRightGUI: .rightCommand
	]

	private static let specialKeyCodes: [UIKeyboardHIDUsage: VNCKeyCode] = [
		.keyboardReturnOrEnter: .return,
		.keypadEnter: .return,
		.keyboardTab: .tab,
		.keyboardDeleteOrBackspace: .delete,
		.keyboardDeleteForward: .forwardDelete,
		.keyboardEscape: .escape,
		.keyboardUpArrow: .upArrow,
		.keyboardDownArrow: .downArrow,
		.keyboardLeftArrow: .leftArrow,
		.keyboardRightArrow: .rightArrow,
		.keyboardHome: .home,
		.keyboardEnd: .end,
		.keyboardPageUp: .pageUp,
		.keyboardPageDown: .pageDown,
		.keyboardF1: .f1,
		.keyboardF2: .f2,
		.keyboardF3: .f3,
		.keyboardF4: .f4,
		.keyboardF5: .f5,
		.keyboardF6: .f6,
		.keyboardF7: .f7,
		.keyboardF8: .f8,
		.keyboardF9: .f9,
		.keyboardF10: .f10,
		.keyboardF11: .f11,
		.keyboardF12: .f12
	]

	var onDeleteBackwardKey: (() -> Void)?
	var onHardwareKeyDown: ((VNCKeyCode) -> Void)?
	var onHardwareKeyUp: ((VNCKeyCode) -> Void)?
	var onHardwareModifierChange: ((VNCKeyCode, Bool) -> Void)?
	var onPasteCommand: (() -> Void)?

	override func deleteBackward() {
		onDeleteBackwardKey?()
	}

	override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
		guard !handleHardwarePresses(presses, isDown: true) else { return }
		super.pressesBegan(presses, with: event)
	}

	override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
		guard !handleHardwarePresses(presses, isDown: false) else { return }
		super.pressesEnded(presses, with: event)
	}

	override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
		_ = handleHardwarePresses(presses, isDown: false)
		super.pressesCancelled(presses, with: event)
	}

	private func handleHardwarePresses(_ presses: Set<UIPress>,
									   isDown: Bool) -> Bool {
		var handledAny = false

		for press in presses {
			guard let key = press.key else { continue }

			// Intercept CMD+V to trigger local clipboard paste
			if isDown,
			   key.keyCode == .keyboardV,
			   key.modifierFlags.contains(.command) {
				onPasteCommand?()
				handledAny = true
				continue
			}

			if let modifierKeyCode = Self.modifierKeyCodes[key.keyCode] {
				onHardwareModifierChange?(modifierKeyCode, isDown)
				handledAny = true
				continue
			}

			guard let keyCode = Self.keyCode(for: key) else {
				continue
			}

			if isDown {
				onHardwareKeyDown?(keyCode)
			} else {
				onHardwareKeyUp?(keyCode)
			}

			handledAny = true
		}

		return handledAny
	}

	private static func keyCode(for key: UIKey) -> VNCKeyCode? {
		if let specialKeyCode = specialKeyCodes[key.keyCode] {
			return specialKeyCode
		}

		guard key.characters.count == 1,
			  let character = key.characters.first else {
			return nil
		}

		return VNCKeyCode.withCharacter(character).first
	}
}

#endif
