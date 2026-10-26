#if os(iOS)
import Foundation
import UIKit

import RoyalVNCKit

public protocol FramebufferViewControllerDelegate: AnyObject {
	func framebufferViewControllerDidRequestDisconnect(_ framebufferViewController: FramebufferViewController)
	
	func framebufferViewController(_ framebufferViewController: FramebufferViewController,
						 mouseDidMove mousePosition: CGPoint)
	
	func framebufferViewController(_ framebufferViewController: FramebufferViewController,
						 mouseDownAt mousePosition: CGPoint)
	
	func framebufferViewController(_ framebufferViewController: FramebufferViewController,
						 mouseUpAt mousePosition: CGPoint)
	
	func framebufferViewController(_ framebufferViewController: FramebufferViewController,
						 rightMouseDownAt mousePosition: CGPoint)
	
	func framebufferViewController(_ framebufferViewController: FramebufferViewController,
						 rightMouseUpAt mousePosition: CGPoint)
	
	func framebufferViewController(_ framebufferViewController: FramebufferViewController,
						 scrollDelta: CGPoint,
						 mousePosition: CGPoint)
	
	func framebufferViewController(_ framebufferViewController: FramebufferViewController,
						 keyDown key: VNCKeyCode)
	
	func framebufferViewController(_ framebufferViewController: FramebufferViewController,
						 keyUp key: VNCKeyCode)

	func framebufferViewControllerDidRequestPaste(_ framebufferViewController: FramebufferViewController,
												  text: String)

	/// Paste with an image on the local clipboard. RFB has no image clipboard
	/// the targeted servers accept, so the host moves `imageData` to the
	/// remote pasteboard itself (any ImageIO-readable format) and then sends
	/// the paste chord. The default ignores it.
	func framebufferViewControllerDidRequestImagePaste(_ framebufferViewController: FramebufferViewController,
													   imageData: Data)
}

public extension FramebufferViewControllerDelegate {
	func framebufferViewControllerDidRequestImagePaste(_ framebufferViewController: FramebufferViewController,
													   imageData: Data) {}
}

#endif
