#if os(iOS)
//
//  DisplayLink.swift
//  RoyalVNCiOSDemo
//
//  CADisplayLink wrapper for iOS framebuffer rendering.
//  Mirrors the macOS CVDisplayLink wrapper from RoyalVNCKit.
//

import Foundation
import UIKit

@MainActor
protocol DisplayLinkDelegate: AnyObject {
	func displayLinkDidUpdate(_ displayLink: DisplayLink)
}

@MainActor
final class DisplayLink {
	private var displayLink: CADisplayLink?

	weak var delegate: DisplayLinkDelegate?

	var isEnabled: Bool {
		get {
			displayLink?.isPaused == false
		}
		set {
			displayLink?.isPaused = !newValue
		}
	}

	init() {
		let link = CADisplayLink(target: self, selector: #selector(displayLinkFired))
		link.isPaused = true
		link.add(to: .main, forMode: .common)
		self.displayLink = link
	}

	deinit {
		// CADisplayLink.invalidate is safe to call off the main thread; we
		// avoid touching `displayLink` directly to keep deinit nonisolated.
		MainActor.assumeIsolated {
			displayLink?.invalidate()
			displayLink = nil
		}
	}

	@objc private func displayLinkFired() {
		delegate?.displayLinkDidUpdate(self)
	}
}

#endif
