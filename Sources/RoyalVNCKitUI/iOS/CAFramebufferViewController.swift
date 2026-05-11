#if os(iOS)
//
//  CAFramebufferViewController.swift
//  RoyalVNCiOSDemo
//
//  Main VNC viewer for iOS. Renders the remote framebuffer via CALayer and
//  translates iOS touch gestures into VNC mouse/keyboard events.
//
//  ──────────────────────────────────────────────────────────────────────
//  FEATURES
//  ──────────────────────────────────────────────────────────────────────
//  - Touch-to-click with white/orange ripple visual feedback
//  - Pinch-to-zoom (0.5x .. 5x) with anchor-point tracking
//  - Two-finger scroll mapped to mouse wheel events
//  - Long-press (0.3s) initiates click-and-drag
//  - On-screen toolbar: keyboard toggle, esc, tab, arrows, modifiers, disconnect
//  - Modifier keys (Shift/Ctrl/Opt/Cmd) are sticky toggles (held until toggled off)
//  - Hardware keyboard support via RemoteKeyboardTextField (arrows, F-keys, modifiers)
//  - Clipboard paste via toolbar button or CMD+V hardware shortcut
//  - Keyboard-aware layout (toolbar slides above the software keyboard)
//  - Cursor overlay (arrow pointer) tracks current remote mouse position
//  - Haptic feedback on taps, drags, and modifier toggles
//
//  ──────────────────────────────────────────────────────────────────────
//  GESTURE MAPPING
//  ──────────────────────────────────────────────────────────────────────
//  Gesture              | Touches | VNC Action           | Feedback
//  ─────────────────────┼─────────┼──────────────────────┼──────────────
//  Single tap           | 1       | Left click           | White ripple, light haptic
//  Double tap           | 1       | Double click         | Two ripples, medium haptic
//  Two-finger tap       | 2       | Right click          | Orange ripple, medium haptic
//  One-finger pan       | 1       | Move cursor / pan*   | Cursor follows touch
//  Two-finger pan       | 2       | Scroll (mouse wheel) | --
//  Pinch                | 2       | Zoom in/out          | --
//  Long press + drag    | 1       | Click-drag           | Blue dot, heavy haptic
//
//  * When zoomed beyond 1x, one-finger pan moves the viewport instead of the cursor.
//
//  ──────────────────────────────────────────────────────────────────────
//  TOOLBAR BUTTONS (left to right)
//  ──────────────────────────────────────────────────────────────────────
//  Icon/Label   | Tag | Action
//  ─────────────┼─────┼─────────────────────────────────────────────────
//  cursorarrow  | 10  | Toggle cursor overlay on/off
//  keyboard     |  0  | Show/hide software keyboard
//  clipboard    |  0  | Paste from iOS clipboard (CMD+V)
//  "esc"        |  0  | Send Escape key
//  tab arrow    |  0  | Send Tab key
//  chevron.left |  0  | Send Left arrow
//  chevron.up   |  0  | Send Up arrow
//  chevron.down |  0  | Send Down arrow
//  chevron.right|  0  | Send Right arrow
//  shift        |  1  | Toggle Shift (held until toggled off)
//  "ctrl"       |  2  | Toggle Control (held until toggled off)
//  option       |  3  | Toggle Option/Alt (held until toggled off)
//  command      |  4  | Toggle Command (held until toggled off)
//  xmark.circle |  0  | Disconnect (red tint)
//
//  Modifier buttons turn blue + scale 1.1x when active. All modifiers are
//  released automatically on disconnect or when the view disappears.
//
//  ──────────────────────────────────────────────────────────────────────
//  CURSOR MODES
//  ──────────────────────────────────────────────────────────────────────
//  The cursor overlay is a white arrow-pointer shape drawn with CAShapeLayer.
//  Toggle visibility with the cursorarrow toolbar button. The cursor tracks
//  the last framebuffer coordinate touched or moved to, converting between
//  screen coordinates and framebuffer coordinates via touchPointToFramebuffer()
//  and framebufferPointToScreen().
//

// TODO: Refactor this file into smaller components (gesture handling, toolbar, cursor overlay)
// to meet the 800-line file_length and type_body_length limits.
// swiftlint:disable file_length

import Foundation
import os.signpost
import UIKit

import RoyalVNCKit

private let perfSignposter = OSSignposter(
	subsystem: "com.royalapplications.RoyalVNCiOSDemo.perf",
	category: "Framebuffer"
)

/// Rolling fixed-capacity buffer for percentile/average over the recent past.
/// Used for cgImage and applyFramebufferImage timings; small enough that
/// per-update sort cost is negligible and shape is more stable than a hard
/// 1-second window.
private struct RollingDurationBuffer {
	private var samples: [Double] = []
	private let capacity: Int
	private var head = 0

	init(capacity: Int) {
		self.capacity = capacity
	}

	mutating func record(_ value: Double) {
		if samples.count < capacity {
			samples.append(value)
		} else {
			samples[head] = value
			head = (head + 1) % capacity
		}
	}

	var average: Double {
		guard !samples.isEmpty else { return 0 }
		return samples.reduce(0, +) / Double(samples.count)
	}

	func percentile(_ percentile: Double) -> Double {
		guard !samples.isEmpty else { return 0 }
		let sorted = samples.sorted()
		let index = min(sorted.count - 1, Int((Double(sorted.count) * percentile).rounded()))
		return sorted[index]
	}

	mutating func reset() {
		samples.removeAll(keepingCapacity: true)
		head = 0
	}
}

// swiftlint:disable:next type_body_length
public class CAFramebufferViewController: UIViewController, FramebufferViewController {
	public weak var framebufferViewControllerDelegate: FramebufferViewControllerDelegate?

	public var logger: VNCLogger?
	public var settings: VNCConnection.Settings?
	/// Perf HUD opt-in. Setter is a no-op outside DEBUG so the overlay can
	/// never appear in shipped builds; the supporting code still compiles
	/// (dead-code stripping handles the rest).
	public var isDebugInfoEnabled = false {
		didSet {
			#if DEBUG
			updateDebugInfoVisibility()
			#endif
		}
	}

	public private(set) var framebufferSize: CGSize = .zero

	private var didLoad = false

	// MARK: - Input Views
	private var hiddenTextField: RemoteKeyboardTextField!
	private var toolbarView: UIView!
	private var isKeyboardVisible = false
	private var toolbarBottomConstraint: NSLayoutConstraint?
	private var activeHardwareModifiers = [VNCKeyCode]()

	// MARK: - Modifier Key State
	private var isShiftPressed = false
	private var isControlPressed = false
	private var isOptionPressed = false
	private var isCommandPressed = false

	// MARK: - Display Link
	private var displayLink: DisplayLink?
	private var needsRender = false
	private var pendingFramebuffer: VNCFramebuffer?

	// MARK: - Debug Info
	private var debugInfoLabel: UILabel?
	private var debugInfoWindowStart = CACurrentMediaTime()
	private var debugInfoRenderCount = 0
	private var debugInfoUpdateCount = 0
	private var debugInfoCoalescedUpdateCount = 0
	private var debugInfoDirtyPixelCount: Double = 0
	private var debugInfoCgImageDurations = RollingDurationBuffer(capacity: 600)
	private var debugInfoApplyDurations = RollingDurationBuffer(capacity: 600)
	private var debugInfoFrameIntervals = RollingDurationBuffer(capacity: 600)
	private var debugInfoUpdateToRenderLatencies = RollingDurationBuffer(capacity: 600)
	private var debugInfoLastRenderTime: TimeInterval?
	private var debugInfoPendingUpdateArrival: TimeInterval?
	private var debugInfoCSVHandle: FileHandle?
	private var debugInfoCSVURL: URL?

	// HUD positioning (PiP-style)
	private var hudIsAtRightEdge = false
	private var isHUDCollapsed = false

	// MARK: - Zoom & Pan State
	private var currentScale: CGFloat = 1.0
	private var minScale: CGFloat = 0.5
	private var maxScale: CGFloat = 5.0
	private var panOffset: CGPoint = .zero
	private var lastPanPoint: CGPoint = .zero
	private var isDragging = false

	// MARK: - Scale Ratio Cache
	private var cachedScaleRatio: CGFloat = 1.0
	private var lastContainerBounds: CGRect = .zero
	private var lastCachedFramebufferSize: CGSize = .zero

	// MARK: - Haptic Feedback (cached)
	private lazy var lightHaptic: UIImpactFeedbackGenerator = {
		UIImpactFeedbackGenerator(style: .light)
	}()
	private lazy var mediumHaptic: UIImpactFeedbackGenerator = {
		UIImpactFeedbackGenerator(style: .medium)
	}()
	private lazy var heavyHaptic: UIImpactFeedbackGenerator = {
		UIImpactFeedbackGenerator(style: .heavy)
	}()

	// MARK: - Tap Indicator Pool
	private var indicatorPool: [UIView] = []

	// MARK: - Cursor Overlay
	private var cursorView: UIView!
	private var cursorImageView: UIImageView!
	private var defaultCursorLayer: CAShapeLayer!
	private var cursorHotspot: CGPoint = .zero
	private var cursorPosition: CGPoint = .zero
	private var isCursorVisible = true

	// MARK: - Framebuffer View
	private var framebufferView: UIView!
	private var framebufferContentView: UIView!
	private var framebufferImageView: UIImageView!
	private var framebufferBottomConstraint: NSLayoutConstraint?

	// MARK: - Loading Overlay
	private var loadingOverlayView: UIView?
	private var loadingSpinner: UIActivityIndicatorView?
	private var loadingLabel: UILabel?
	private var hasReceivedFirstFrame = false

	// MARK: - Connection Time
	private var connectionStartedAt: Date?

	// MARK: - Scale Ratio

	public var scaleRatio: CGFloat {
		let containerBounds = framebufferView?.bounds ?? view.bounds
		if containerBounds != lastContainerBounds || framebufferSize != lastCachedFramebufferSize {
			cachedScaleRatio = calculateScaleRatio()
			lastContainerBounds = containerBounds
			lastCachedFramebufferSize = framebufferSize
		}
		return cachedScaleRatio
	}

	private func calculateScaleRatio() -> CGFloat {
		let containerBounds = framebufferView?.bounds ?? view.bounds
		let fbSize = framebufferSize

		guard containerBounds.width > 0,
			  containerBounds.height > 0,
			  fbSize.width > 0,
			  fbSize.height > 0 else {
			return 1
		}

		let targetAspectRatio = containerBounds.width / containerBounds.height
		let fbAspectRatio = fbSize.width / fbSize.height

		if fbAspectRatio >= targetAspectRatio {
			return containerBounds.width / fbSize.width
		} else {
			return containerBounds.height / fbSize.height
		}
	}

	private func invalidateScaleRatioCache() {
		lastContainerBounds = .zero
		lastCachedFramebufferSize = .zero
	}

	public var contentRect: CGRect {
		let containerBounds = framebufferView?.bounds ?? view.bounds
		let scale = scaleRatio * currentScale

		var rect = CGRect(x: 0, y: 0,
						  width: framebufferSize.width * scale, height: framebufferSize.height * scale)

		if rect.size.width < containerBounds.size.width {
			rect.origin.x = (containerBounds.size.width - rect.size.width) / 2.0
		}

		if rect.size.height < containerBounds.size.height {
			rect.origin.y = (containerBounds.size.height - rect.size.height) / 2.0
		}

		return rect
	}

	// MARK: - Lifecycle

	public override func viewDidLoad() {
		super.viewDidLoad()

		guard !didLoad else { return }
		didLoad = true

		view.backgroundColor = .black

		setupFramebufferView()
		setupCursorOverlay()
			setupToolbar()
			#if DEBUG
			setupDebugInfoOverlay()
			#endif
			setupLoadingOverlay()
			setupHiddenTextField()
			setupGestures()

		// Pre-warm haptic generators
		lightHaptic.prepare()
		mediumHaptic.prepare()
		heavyHaptic.prepare()

		// Listen for keyboard notifications
		NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow(_:)), name: UIResponder.keyboardWillShowNotification, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
	}

	public override func viewDidLayoutSubviews() {
		super.viewDidLayoutSubviews()
		invalidateScaleRatioCache()
		clampPanOffset()
		updateTransform()
		if isDebugInfoEnabled {
			relayoutHUDPreservingEdge()
		}
	}

	public override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)
		addDisplayLink()
		if connectionStartedAt == nil {
			connectionStartedAt = Date()
		}
	}

	public override func viewWillDisappear(_ animated: Bool) {
		super.viewWillDisappear(animated)
		removeDisplayLink()
		releaseAllModifiers()
		endPerfSession()
	}

	deinit {
		// MainActor isolation isn't inherited by deinit. removeDisplayLink
		// touches MainActor state, so jump back via assumeIsolated. The
		// NotificationCenter call is safe from any thread.
		MainActor.assumeIsolated {
			removeDisplayLink()
		}
		NotificationCenter.default.removeObserver(self)
	}

	// MARK: - Setup

	private func setupFramebufferView() {
		framebufferView = UIView()
		framebufferView.translatesAutoresizingMaskIntoConstraints = false
		framebufferView.backgroundColor = .black
		framebufferView.clipsToBounds = true
		framebufferView.isUserInteractionEnabled = true

		framebufferContentView = UIView()
		framebufferContentView.translatesAutoresizingMaskIntoConstraints = false
		framebufferContentView.backgroundColor = .black
		framebufferContentView.isUserInteractionEnabled = false

		framebufferImageView = UIImageView()
		framebufferImageView.translatesAutoresizingMaskIntoConstraints = false
		framebufferImageView.backgroundColor = .black
		framebufferImageView.contentMode = .scaleAspectFit
		framebufferImageView.isUserInteractionEnabled = false
		framebufferImageView.clipsToBounds = true

		let layer = framebufferImageView.layer
		layer.contentsScale = 1
		// .linear is correct for VNC framebuffers: trilinear without mipmaps degrades
		// to linear visually but still costs extra sample lookups per pixel.
		layer.minificationFilter = .linear
		layer.magnificationFilter = .linear

		view.addSubview(framebufferView)
		framebufferView.addSubview(framebufferContentView)
		framebufferContentView.addSubview(framebufferImageView)

		// Top, leading, trailing constraints - bottom is set in setupToolbar
		NSLayoutConstraint.activate([
			framebufferView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
			framebufferView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			framebufferView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			framebufferContentView.topAnchor.constraint(equalTo: framebufferView.topAnchor),
			framebufferContentView.leadingAnchor.constraint(equalTo: framebufferView.leadingAnchor),
			framebufferContentView.trailingAnchor.constraint(equalTo: framebufferView.trailingAnchor),
			framebufferContentView.bottomAnchor.constraint(equalTo: framebufferView.bottomAnchor),
			framebufferImageView.topAnchor.constraint(equalTo: framebufferContentView.topAnchor),
			framebufferImageView.leadingAnchor.constraint(equalTo: framebufferContentView.leadingAnchor),
			framebufferImageView.trailingAnchor.constraint(equalTo: framebufferContentView.trailingAnchor),
			framebufferImageView.bottomAnchor.constraint(equalTo: framebufferContentView.bottomAnchor)
		])
	}

	private func setupCursorOverlay() {
		// Create cursor view - a pointer-style indicator
		cursorView = UIView(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
		cursorView.isUserInteractionEnabled = false
		cursorView.alpha = 0.9

		// Create arrow pointer shape using CAShapeLayer
		let pointerPath = UIBezierPath()
		pointerPath.move(to: .zero)       // Tip
		pointerPath.addLine(to: CGPoint(x: 0, y: 18))   // Down left edge
		pointerPath.addLine(to: CGPoint(x: 5, y: 14))   // Notch
		pointerPath.addLine(to: CGPoint(x: 9, y: 22))   // Arrow tail bottom
		pointerPath.addLine(to: CGPoint(x: 13, y: 20))  // Arrow tail right
		pointerPath.addLine(to: CGPoint(x: 9, y: 12))   // Back to body
		pointerPath.addLine(to: CGPoint(x: 14, y: 12))  // Right edge
		pointerPath.close()

		let shapeLayer = CAShapeLayer()
		shapeLayer.path = pointerPath.cgPath
		shapeLayer.fillColor = UIColor.white.cgColor
		shapeLayer.strokeColor = UIColor.black.cgColor
		shapeLayer.lineWidth = 1.5
		defaultCursorLayer = shapeLayer

		cursorView.layer.addSublayer(shapeLayer)

		// Image view for server-sent cursor images (hidden by default)
		cursorImageView = UIImageView()
		cursorImageView.isHidden = true
		cursorImageView.contentMode = .scaleToFill
		cursorView.addSubview(cursorImageView)

		// Add subtle shadow for visibility. shadowPath is required to avoid an
		// offscreen rasterization pass on every cursor move at display refresh rate.
		cursorView.layer.shadowColor = UIColor.black.cgColor
		cursorView.layer.shadowOffset = CGSize(width: 1, height: 1)
		cursorView.layer.shadowOpacity = 0.5
		cursorView.layer.shadowRadius = 2
		cursorView.layer.shadowPath = pointerPath.cgPath

		framebufferView.addSubview(cursorView)

		// Default hotspot at tip of arrow pointer
		cursorHotspot = .zero

		// Initially position at center
		cursorPosition = CGPoint(x: framebufferSize.width / 2, y: framebufferSize.height / 2)
		updateCursorPosition()
	}

		private func setupToolbar() {
			toolbarView = UIView()
		toolbarView.translatesAutoresizingMaskIntoConstraints = false
		toolbarView.backgroundColor = UIColor.systemGray5

		view.addSubview(toolbarView)

		let bottomConstraint = toolbarView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
		toolbarBottomConstraint = bottomConstraint

		// Connect framebuffer bottom to toolbar top
		framebufferBottomConstraint = framebufferView.bottomAnchor.constraint(equalTo: toolbarView.topAnchor)

		var constraints = [
			toolbarView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			toolbarView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			bottomConstraint,
			toolbarView.heightAnchor.constraint(equalToConstant: 50)
		]
		if let fbBottomConstraint = framebufferBottomConstraint {
			constraints.insert(fbBottomConstraint, at: 0)
		}
		NSLayoutConstraint.activate(constraints)

		// Create toolbar buttons
		let stackView = UIStackView()
		stackView.axis = .horizontal
		stackView.distribution = .fillEqually
		stackView.spacing = 4
		stackView.translatesAutoresizingMaskIntoConstraints = false

		// Cursor toggle
		let cursorBtn = createToolbarButton(action: #selector(toggleCursor(_:)), icon: "cursorarrow", tag: 10, accessibilityLabel: "Toggle cursor visibility")

		// Keyboard toggle
		let keyboardBtn = createToolbarButton(action: #selector(toggleKeyboard), icon: "keyboard", accessibilityLabel: "Toggle keyboard")

		// Escape
		let escBtn = createToolbarButton(action: #selector(sendEscape), title: "esc", accessibilityLabel: "Escape key")

		// Tab
		let tabBtn = createToolbarButton(action: #selector(sendTab), icon: "arrow.right.to.line", accessibilityLabel: "Tab key")

		// Arrow keys
		let upBtn = createToolbarButton(action: #selector(sendArrowUp), icon: "chevron.up", accessibilityLabel: "Up arrow")
		let downBtn = createToolbarButton(action: #selector(sendArrowDown), icon: "chevron.down", accessibilityLabel: "Down arrow")
		let leftBtn = createToolbarButton(action: #selector(sendArrowLeft), icon: "chevron.left", accessibilityLabel: "Left arrow")
		let rightBtn = createToolbarButton(action: #selector(sendArrowRight), icon: "chevron.right", accessibilityLabel: "Right arrow")

		// Modifiers
		let shiftBtn = createToolbarButton(action: #selector(toggleShift), icon: "shift", tag: 1, accessibilityLabel: "Shift modifier")
		let ctrlBtn = createToolbarButton(action: #selector(toggleControl), title: "ctrl", tag: 2, accessibilityLabel: "Control modifier")
		let optBtn = createToolbarButton(action: #selector(toggleOption), icon: "option", tag: 3, accessibilityLabel: "Option modifier")
		let cmdBtn = createToolbarButton(action: #selector(toggleCommand), icon: "command", tag: 4, accessibilityLabel: "Command modifier")

		// Paste from clipboard
		let pasteBtn = createToolbarButton(action: #selector(pasteFromClipboard), icon: "doc.on.clipboard", accessibilityLabel: "Paste from clipboard")

		// Disconnect
		let disconnectBtn = createToolbarButton(action: #selector(disconnect), icon: "xmark.circle", accessibilityLabel: "Disconnect")
		disconnectBtn.tintColor = .systemRed

		stackView.addArrangedSubview(cursorBtn)
		stackView.addArrangedSubview(keyboardBtn)
		stackView.addArrangedSubview(pasteBtn)
		stackView.addArrangedSubview(escBtn)
		stackView.addArrangedSubview(tabBtn)
		stackView.addArrangedSubview(leftBtn)
		stackView.addArrangedSubview(upBtn)
		stackView.addArrangedSubview(downBtn)
		stackView.addArrangedSubview(rightBtn)
		stackView.addArrangedSubview(shiftBtn)
		stackView.addArrangedSubview(ctrlBtn)
		stackView.addArrangedSubview(optBtn)
		stackView.addArrangedSubview(cmdBtn)
		stackView.addArrangedSubview(disconnectBtn)

		toolbarView.addSubview(stackView)

			NSLayoutConstraint.activate([
				stackView.topAnchor.constraint(equalTo: toolbarView.topAnchor, constant: 4),
				stackView.leadingAnchor.constraint(equalTo: toolbarView.leadingAnchor, constant: 8),
				stackView.trailingAnchor.constraint(equalTo: toolbarView.trailingAnchor, constant: -8),
				stackView.bottomAnchor.constraint(equalTo: toolbarView.bottomAnchor, constant: -4)
			])
		}

		private func setupLoadingOverlay() {
			let overlay = UIView()
			overlay.translatesAutoresizingMaskIntoConstraints = false
			overlay.backgroundColor = UIColor.black.withAlphaComponent(0.6)
			overlay.isUserInteractionEnabled = false

			let spinner = UIActivityIndicatorView(style: .large)
			spinner.translatesAutoresizingMaskIntoConstraints = false
			spinner.color = .white
			spinner.startAnimating()

			let label = UILabel()
			label.translatesAutoresizingMaskIntoConstraints = false
			label.text = "Loading desktop…"
			label.textColor = .white
			label.font = .systemFont(ofSize: 15, weight: .medium)
			label.textAlignment = .center
			label.numberOfLines = 0

			overlay.addSubview(spinner)
			overlay.addSubview(label)
			view.addSubview(overlay)

			// Bottom edge stops at the toolbar instead of view.bottomAnchor so
			// the dim layer doesn't grey out the toolbar's disconnect /
			// keyboard / arrow buttons while the session is still connecting.
			NSLayoutConstraint.activate([
				overlay.topAnchor.constraint(equalTo: view.topAnchor),
				overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
				overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
				overlay.bottomAnchor.constraint(equalTo: toolbarView.topAnchor),
				spinner.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
				spinner.centerYAnchor.constraint(equalTo: overlay.centerYAnchor, constant: -20),
				label.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 16),
				label.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
				label.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.leadingAnchor, constant: 24),
				label.trailingAnchor.constraint(lessThanOrEqualTo: overlay.trailingAnchor, constant: -24)
			])

			loadingOverlayView = overlay
			loadingSpinner = spinner
			loadingLabel = label
		}

		func setLoadingMessage(_ message: String) {
			loadingLabel?.text = message
			showLoadingOverlay()
		}

		private func showLoadingOverlay() {
			guard let overlay = loadingOverlayView, overlay.isHidden || overlay.alpha < 1 else { return }
			overlay.isHidden = false
			loadingSpinner?.startAnimating()
			UIView.animate(withDuration: 0.2) {
				overlay.alpha = 1
			}
		}

		private func hideLoadingOverlay() {
			guard let overlay = loadingOverlayView, !overlay.isHidden else { return }
			UIView.animate(withDuration: 0.25, animations: {
				overlay.alpha = 0
			}, completion: { [weak self] _ in
				overlay.isHidden = true
				self?.loadingSpinner?.stopAnimating()
			})
		}

		private func setupDebugInfoOverlay() {
			let label = UILabel()
			// Frame-based so we can drag/snap PiP-style without fighting Auto Layout.
			label.translatesAutoresizingMaskIntoConstraints = true
			label.numberOfLines = 0
			label.textColor = .systemGreen
			label.backgroundColor = UIColor.black.withAlphaComponent(0.72)
			label.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
			label.layer.cornerRadius = 6
			label.layer.masksToBounds = true
			label.text = "FPS: --\n(drag to move · tap to collapse · hold to share)"
			label.isHidden = !isDebugInfoEnabled
			label.accessibilityIdentifier = "framebufferDebugInfoLabel"
			label.isUserInteractionEnabled = true

			let pan = UIPanGestureRecognizer(target: self, action: #selector(handleHUDPan(_:)))
			label.addGestureRecognizer(pan)

			let tap = UITapGestureRecognizer(target: self, action: #selector(toggleHUDCollapse))
			label.addGestureRecognizer(tap)

			let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleHUDLongPress(_:)))
			longPress.minimumPressDuration = 0.5
			label.addGestureRecognizer(longPress)
			tap.require(toFail: longPress)

			view.addSubview(label)
			debugInfoLabel = label

			label.sizeToFit()
			let margin: CGFloat = 8
			label.frame = CGRect(
				x: view.safeAreaInsets.left + margin,
				y: view.safeAreaInsets.top + margin,
				width: label.frame.width + 16,
				height: label.frame.height + 8
			)
		}

		@objc private func handleHUDPan(_ gesture: UIPanGestureRecognizer) {
			guard let label = debugInfoLabel else { return }
			let translation = gesture.translation(in: view)

			switch gesture.state {
			case .changed:
				label.center = CGPoint(
					x: label.center.x + translation.x,
					y: label.center.y + translation.y
				)
				gesture.setTranslation(.zero, in: view)
			case .ended, .cancelled:
				snapHUDToNearestEdge()
			default:
				break
			}
		}

		private func snapHUDToNearestEdge() {
			guard let label = debugInfoLabel else { return }
			let viewBounds = view.bounds
			let safeArea = view.safeAreaInsets
			let margin: CGFloat = 8

			hudIsAtRightEdge = label.center.x > viewBounds.midX

			var newFrame = label.frame
			if hudIsAtRightEdge {
				newFrame.origin.x = viewBounds.maxX - safeArea.right - margin - newFrame.width
			} else {
				newFrame.origin.x = safeArea.left + margin
			}

			let minY = safeArea.top + margin
			let maxY = viewBounds.maxY - safeArea.bottom - margin - newFrame.height
			newFrame.origin.y = max(minY, min(maxY, newFrame.origin.y))

			UIView.animate(
				withDuration: 0.3,
				delay: 0,
				usingSpringWithDamping: 0.85,
				initialSpringVelocity: 0.5,
				options: .curveEaseOut
			) {
				label.frame = newFrame
			}
		}

		@objc private func toggleHUDCollapse() {
			isHUDCollapsed.toggle()
			updateDebugInfoLabel(force: true)
		}

		@objc private func handleHUDLongPress(_ gesture: UILongPressGestureRecognizer) {
			guard gesture.state == .began else { return }
			presentPerfCSVShareSheet()
		}

		private func relayoutHUDPreservingEdge() {
			guard let label = debugInfoLabel else { return }
			let prevMidY = label.frame.midY

			label.sizeToFit()
			var newFrame = label.frame
			newFrame.size.width += 16
			newFrame.size.height += 8

			let viewBounds = view.bounds
			let safeArea = view.safeAreaInsets
			let margin: CGFloat = 8

			if hudIsAtRightEdge {
				newFrame.origin.x = viewBounds.maxX - safeArea.right - margin - newFrame.width
			} else {
				newFrame.origin.x = safeArea.left + margin
			}

			newFrame.origin.y = prevMidY - newFrame.height / 2
			let minY = safeArea.top + margin
			let maxY = viewBounds.maxY - safeArea.bottom - margin - newFrame.height
			newFrame.origin.y = max(minY, min(maxY, newFrame.origin.y))

			label.frame = newFrame
		}

		@objc private func presentPerfCSVShareSheet() {
			let url: URL?
			if let active = debugInfoCSVURL {
				try? debugInfoCSVHandle?.synchronize()
				url = active
			} else {
				url = mostRecentPerfCSV()
			}

			guard let csvURL = url else {
				let alert = UIAlertController(
					title: "No perf CSV yet",
					message: "Toggle Debug Info on and let it record for a few seconds before sharing.",
					preferredStyle: .alert
				)
				alert.addAction(UIAlertAction(title: "OK", style: .default))
				present(alert, animated: true)
				return
			}

			let activityVC = UIActivityViewController(activityItems: [csvURL], applicationActivities: nil)
			activityVC.popoverPresentationController?.sourceView = debugInfoLabel
			activityVC.popoverPresentationController?.sourceRect = debugInfoLabel?.bounds ?? .zero
			present(activityVC, animated: true)
		}

		private func mostRecentPerfCSV() -> URL? {
			guard let docs = try? FileManager.default.url(
				for: .documentDirectory,
				in: .userDomainMask,
				appropriateFor: nil,
				create: false
			) else { return nil }

			let keys: [URLResourceKey] = [.contentModificationDateKey]
			guard let urls = try? FileManager.default.contentsOfDirectory(
				at: docs,
				includingPropertiesForKeys: keys
			) else { return nil }

			return urls
				.filter { $0.lastPathComponent.hasPrefix("perf-") && $0.pathExtension == "csv" }
				.max(by: { lhs, rhs in
					let lhsDate = (try? lhs.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
					let rhsDate = (try? rhs.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
					return lhsDate < rhsDate
				})
		}

		private func createToolbarButton(
		action: Selector,
		title: String? = nil,
		icon: String? = nil,
		tag: Int = 0,
		accessibilityLabel: String? = nil
	) -> UIButton {
		let button = UIButton(type: .system)
		button.tag = tag

		if let icon = icon {
			button.setImage(UIImage(systemName: icon), for: .normal)
		}
		if let title = title {
			button.setTitle(title, for: .normal)
			button.titleLabel?.font = .systemFont(ofSize: 12, weight: .medium)
		}

		button.backgroundColor = UIColor.systemGray4
		button.layer.cornerRadius = 6
		button.tintColor = .label
		button.addTarget(self, action: action, for: .touchUpInside)

		// Accessibility
		button.isAccessibilityElement = true
		button.accessibilityLabel = accessibilityLabel ?? title
		button.accessibilityTraits = .button

		return button
	}

	private func setupHiddenTextField() {
		hiddenTextField = RemoteKeyboardTextField()
		hiddenTextField.frame = CGRect(x: -1000, y: -1000, width: 100, height: 30)
		hiddenTextField.autocorrectionType = .no
		hiddenTextField.autocapitalizationType = .none
		hiddenTextField.spellCheckingType = .no
		hiddenTextField.smartQuotesType = .no
		hiddenTextField.smartDashesType = .no
		hiddenTextField.smartInsertDeleteType = .no
		hiddenTextField.textContentType = .none
		hiddenTextField.keyboardType = .default
		hiddenTextField.delegate = self
		hiddenTextField.onDeleteBackwardKey = { [weak self] in
			self?.sendKey(.delete)
		}
		hiddenTextField.onHardwareKeyDown = { [weak self] keyCode in
			self?.handleHardwareKeyDown(keyCode)
		}
		hiddenTextField.onHardwareKeyUp = { [weak self] keyCode in
			self?.handleHardwareKeyUp(keyCode)
		}
		hiddenTextField.onHardwareModifierChange = { [weak self] keyCode, isDown in
			self?.handleHardwareModifier(keyCode, isDown: isDown)
		}
		hiddenTextField.onPasteCommand = { [weak self] in
			self?.pasteFromClipboard()
		}

		view.addSubview(hiddenTextField)
	}

	private func setupGestures() {
		// Single tap = left click
		let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
		tapGesture.numberOfTapsRequired = 1
		tapGesture.numberOfTouchesRequired = 1
		framebufferView.addGestureRecognizer(tapGesture)

		// Two-finger tap = right click
		let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
		twoFingerTap.numberOfTapsRequired = 1
		twoFingerTap.numberOfTouchesRequired = 2
		framebufferView.addGestureRecognizer(twoFingerTap)

		// Double tap = double click
		let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
		doubleTap.numberOfTapsRequired = 2
		doubleTap.numberOfTouchesRequired = 1
		framebufferView.addGestureRecognizer(doubleTap)
		tapGesture.require(toFail: doubleTap)

		// Pan = mouse move
		let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
		panGesture.minimumNumberOfTouches = 1
		panGesture.maximumNumberOfTouches = 1
		framebufferView.addGestureRecognizer(panGesture)

		// Two-finger pan = scroll
		let twoFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan(_:)))
		twoFingerPan.minimumNumberOfTouches = 2
		twoFingerPan.maximumNumberOfTouches = 2
		framebufferView.addGestureRecognizer(twoFingerPan)

		// Pinch = zoom
		let pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
		framebufferView.addGestureRecognizer(pinchGesture)

		// Long press = drag
		let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
		longPress.minimumPressDuration = 0.3
		framebufferView.addGestureRecognizer(longPress)

		panGesture.require(toFail: longPress)
	}

	// MARK: - Toolbar Actions

	@objc private func toggleKeyboard() {
		if isKeyboardVisible {
			hiddenTextField.resignFirstResponder()
		} else {
			hiddenTextField.becomeFirstResponder()
		}
	}

	@objc private func sendEscape() {
		sendKey(.escape)
	}

	@objc private func sendTab() {
		sendKey(.tab)
	}

	@objc private func sendArrowUp() {
		sendKey(.upArrow)
	}

	@objc private func sendArrowDown() {
		sendKey(.downArrow)
	}

	@objc private func sendArrowLeft() {
		sendKey(.leftArrow)
	}

	@objc private func sendArrowRight() {
		sendKey(.rightArrow)
	}

	@objc private func toggleShift(_ sender: UIButton) {
		toggleModifier(.shift, isPressed: &isShiftPressed, button: sender)
	}

	@objc private func toggleControl(_ sender: UIButton) {
		toggleModifier(.control, isPressed: &isControlPressed, button: sender)
	}

	@objc private func toggleOption(_ sender: UIButton) {
		toggleModifier(.option, isPressed: &isOptionPressed, button: sender)
	}

	@objc private func toggleCommand(_ sender: UIButton) {
		toggleModifier(.command, isPressed: &isCommandPressed, button: sender)
	}

	/// Toggle a modifier key - sends keyDown when activated, keyUp when deactivated
	/// Modifiers stay held until explicitly toggled off, enabling CMD+A style combos
	private func toggleModifier(_ keyCode: VNCKeyCode, isPressed: inout Bool, button: UIButton) {
		isPressed.toggle()

		if isPressed {
			// Modifier ON → send keyDown (key is now held on remote)
			framebufferViewControllerDelegate?.framebufferViewController(self, keyDown: keyCode)
		} else {
			// Modifier OFF → send keyUp (key is released on remote)
			framebufferViewControllerDelegate?.framebufferViewController(self, keyUp: keyCode)
		}

		updateModifierButtonAppearance(button, isPressed: isPressed)

		lightHaptic.impactOccurred()
	}

	private func updateModifierButtonAppearance(_ button: UIButton, isPressed: Bool) {
		UIView.animate(withDuration: 0.15) {
			button.backgroundColor = isPressed ? .systemBlue : .systemGray4
			button.tintColor = isPressed ? .white : .label
			button.transform = isPressed ? CGAffineTransform(scaleX: 1.1, y: 1.1) : .identity
		}
	}

	/// Release all held modifiers (call when disconnecting or view disappears)
	private func releaseAllModifiers() {
		if isShiftPressed {
			framebufferViewControllerDelegate?.framebufferViewController(self, keyUp: .shift)
			isShiftPressed = false
		}
		if isControlPressed {
			framebufferViewControllerDelegate?.framebufferViewController(self, keyUp: .control)
			isControlPressed = false
		}
		if isOptionPressed {
			framebufferViewControllerDelegate?.framebufferViewController(self, keyUp: .option)
			isOptionPressed = false
		}
		if isCommandPressed {
			framebufferViewControllerDelegate?.framebufferViewController(self, keyUp: .command)
			isCommandPressed = false
		}

		// Update UI
		if let stackView = toolbarView?.subviews.first(where: { $0 is UIStackView }) as? UIStackView {
			for case let button as UIButton in stackView.arrangedSubviews where button.tag > 0 {
				updateModifierButtonAppearance(button, isPressed: false)
			}
		}
	}

	@objc private func pasteFromClipboard() {
		logger?.logDebug("[PASTE] button tapped, reading UIPasteboard…")
		let text: String?
		text = UIPasteboard.general.string
		logger?.logDebug("[PASTE] pasteboard string: \(text?.count ?? -1) chars")

		guard let text, !text.isEmpty else {
			logger?.logDebug("[PASTE] empty/nil — bailing")
			lightHaptic.impactOccurred()
			return
		}

		guard let delegate = framebufferViewControllerDelegate else {
			logger?.logError("[PASTE] no delegate set — cannot forward paste")
			return
		}

		logger?.logDebug("[PASTE] forwarding to delegate")
		delegate.framebufferViewControllerDidRequestPaste(self, text: text)
		logger?.logDebug("[PASTE] delegate returned")

		mediumHaptic.impactOccurred()
	}

	@objc private func disconnect() {
		releaseAllModifiers()
		framebufferViewControllerDelegate?.framebufferViewControllerDidRequestDisconnect(self)
	}

	// MARK: - Key Sending

	/// Send a regular key press. After the key is sent, any one-shot modifiers
	/// (Cmd/Ctrl/Option) that were toggled on get released automatically.
	/// Shift stays held — it's most useful for sequential capitals.
	private func sendKey(_ keyCode: VNCKeyCode) {
		handleKeyPress(keyCode)
		releaseOneShotModifiers()
	}

	/// Release Cmd, Ctrl, and Option if currently held; leave Shift alone.
	/// Called after any non-modifier action (key press, mouse click) so combos
	/// like Cmd+C / Cmd+V / Cmd+click feel like a single gesture rather than
	/// requiring an explicit Cmd untoggle.
	private func releaseOneShotModifiers() {
		if isControlPressed {
			framebufferViewControllerDelegate?.framebufferViewController(self, keyUp: .control)
			isControlPressed = false
		}
		if isOptionPressed {
			framebufferViewControllerDelegate?.framebufferViewController(self, keyUp: .option)
			isOptionPressed = false
		}
		if isCommandPressed {
			framebufferViewControllerDelegate?.framebufferViewController(self, keyUp: .command)
			isCommandPressed = false
		}

		guard let stackView = toolbarView?.subviews.first(where: { $0 is UIStackView }) as? UIStackView else { return }
		for case let button as UIButton in stackView.arrangedSubviews where (2...4).contains(button.tag) {
			updateModifierButtonAppearance(button, isPressed: false)
		}
	}

	// MARK: - Keyboard Notifications

	@objc private func keyboardWillShow(_ notification: Notification) {
		isKeyboardVisible = true

		guard let userInfo = notification.userInfo,
			  let keyboardFrame = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
			  let duration = userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double else {
			return
		}

		let keyboardHeight = keyboardFrame.height - view.safeAreaInsets.bottom
		toolbarBottomConstraint?.constant = -keyboardHeight

		UIView.animate(withDuration: duration) {
			self.view.layoutIfNeeded()
		}
	}

	@objc private func keyboardWillHide(_ notification: Notification) {
		isKeyboardVisible = false

		guard let userInfo = notification.userInfo,
			  let duration = userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double else {
			toolbarBottomConstraint?.constant = 0
			return
		}

		toolbarBottomConstraint?.constant = 0

		UIView.animate(withDuration: duration) {
			self.view.layoutIfNeeded()
		}
	}

	// MARK: - Coordinate Conversion

	private func touchPointToFramebuffer(_ point: CGPoint) -> CGPoint {
		guard framebufferSize.width > 0, framebufferSize.height > 0 else {
			return .zero
		}

		let viewBounds = framebufferView.bounds
		let baseScale = scaleRatio
		let totalScale = baseScale * currentScale

		let scaledWidth = framebufferSize.width * totalScale
		let scaledHeight = framebufferSize.height * totalScale

		let offsetX = (viewBounds.width - scaledWidth) / 2.0 + panOffset.x
		let offsetY = (viewBounds.height - scaledHeight) / 2.0 + panOffset.y

		let fbX = (point.x - offsetX) / totalScale
		let fbY = (point.y - offsetY) / totalScale

		let clampedX = max(0, min(framebufferSize.width - 1, fbX))
		let clampedY = max(0, min(framebufferSize.height - 1, fbY))

		return CGPoint(x: clampedX, y: clampedY)
	}

	private func updatePanOffset(keeping anchorPoint: CGPoint,
								 anchoredTo framebufferPoint: CGPoint) {
		let viewBounds = framebufferView.bounds
		let totalScale = scaleRatio * currentScale
		let scaledWidth = framebufferSize.width * totalScale
		let scaledHeight = framebufferSize.height * totalScale

		panOffset.x = anchorPoint.x - (framebufferPoint.x * totalScale) - ((viewBounds.width - scaledWidth) / 2.0)
		panOffset.y = anchorPoint.y - (framebufferPoint.y * totalScale) - ((viewBounds.height - scaledHeight) / 2.0)
		clampPanOffset()
	}

	private func clampPanOffset() {
		let viewBounds = framebufferView?.bounds ?? .zero
		guard viewBounds.width > 0, viewBounds.height > 0 else { return }

		let totalScale = scaleRatio * currentScale
		let scaledWidth = framebufferSize.width * totalScale
		let scaledHeight = framebufferSize.height * totalScale

		// Allow panning past the natural edge so the user can reach corners
		// even when toolbar/keyboard cover part of the view. Keep at least
		// 80pt of content visible from each edge so they can pan back.
		let minVisible: CGFloat = 80
		let extraX = max(0, viewBounds.width - minVisible)
		let extraY = max(0, viewBounds.height - minVisible)

		let horizontalOverflow = max(0, scaledWidth - viewBounds.width)
		let verticalOverflow = max(0, scaledHeight - viewBounds.height)

		let limitX = horizontalOverflow / 2 + extraX
		let limitY = verticalOverflow / 2 + extraY

		panOffset.x = horizontalOverflow > 0 || scaledWidth > minVisible
			? max(-limitX, min(limitX, panOffset.x))
			: 0
		panOffset.y = verticalOverflow > 0 || scaledHeight > minVisible
			? max(-limitY, min(limitY, panOffset.y))
			: 0
	}

	// MARK: - Cursor Management

	/// Convert framebuffer coordinates to screen coordinates
	private func framebufferPointToScreen(_ fbPoint: CGPoint) -> CGPoint {
		let viewBounds = framebufferView.bounds
		let baseScale = scaleRatio
		let totalScale = baseScale * currentScale

		let scaledWidth = framebufferSize.width * totalScale
		let scaledHeight = framebufferSize.height * totalScale

		let offsetX = (viewBounds.width - scaledWidth) / 2.0 + panOffset.x
		let offsetY = (viewBounds.height - scaledHeight) / 2.0 + panOffset.y

		let screenX = fbPoint.x * totalScale + offsetX
		let screenY = fbPoint.y * totalScale + offsetY

		return CGPoint(x: screenX, y: screenY)
	}

	/// Update cursor view position on screen
	private func updateCursorPosition() {
		guard isCursorVisible else {
			cursorView?.isHidden = true
			return
		}

		CATransaction.begin()
		CATransaction.setDisableActions(true)

		let screenPoint = framebufferPointToScreen(cursorPosition)
		let cursorBounds = cursorView?.bounds ?? .zero
		// Position cursor so hotspot aligns with the screen point
		let cursorX = screenPoint.x - cursorHotspot.x + cursorBounds.width / 2
		let cursorY = screenPoint.y - cursorHotspot.y + cursorBounds.height / 2
		cursorView?.center = CGPoint(x: cursorX, y: cursorY)
		cursorView?.isHidden = false

		CATransaction.commit()
	}

	/// Move cursor to framebuffer position
	private func moveCursor(to fbPoint: CGPoint) {
		cursorPosition = fbPoint
		updateCursorPosition()
	}

	@objc private func toggleCursor(_ sender: UIButton) {
		isCursorVisible.toggle()
		updateCursorPosition()
		updateCursorButtonAppearance(sender)

		lightHaptic.impactOccurred()
	}

	private func updateCursorButtonAppearance(_ button: UIButton) {
		UIView.animate(withDuration: 0.15) {
			button.backgroundColor = self.isCursorVisible ? .systemBlue : .systemGray4
			button.tintColor = self.isCursorVisible ? .white : .label
			button.transform = self.isCursorVisible ? CGAffineTransform(scaleX: 1.1, y: 1.1) : .identity
		}
	}

	// MARK: - Tap Indicator Pool Helpers

	private func getIndicatorView() -> UIView {
		if let pooled = indicatorPool.popLast() {
			pooled.isHidden = false
			pooled.layer.removeAllAnimations()
			return pooled
		}
		return UIView()
	}

	private func returnIndicatorToPool(_ view: UIView) {
		view.isHidden = true
		view.alpha = 1.0
		view.transform = .identity
		view.backgroundColor = .clear
		view.layer.borderWidth = 0
		view.layer.borderColor = nil
		view.removeFromSuperview()
		// Cap pool size to prevent unbounded growth
		if indicatorPool.count < 10 {
			indicatorPool.append(view)
		}
	}

	// MARK: - Visual Feedback

	/// Shows a ripple effect at the tap location
	private func showTapIndicator(at point: CGPoint, color: UIColor = .white) {
		let size: CGFloat = 44
		let indicator = getIndicatorView()
		indicator.frame = CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
		indicator.backgroundColor = .clear
		indicator.layer.cornerRadius = size / 2
		indicator.layer.borderWidth = 2
		indicator.layer.borderColor = color.cgColor
		indicator.alpha = 0.8
		indicator.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)

		framebufferView.addSubview(indicator)

		// Keep cursor on top
		if let cursor = cursorView {
			framebufferView.bringSubviewToFront(cursor)
		}

		UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseOut) {
			indicator.transform = CGAffineTransform(scaleX: 1.2, y: 1.2)
			indicator.alpha = 0
		} completion: { [weak self] _ in
			self?.returnIndicatorToPool(indicator)
		}
	}

	/// Shows a smaller dot for drag operations
	private func showDragIndicator(at point: CGPoint) {
		let size: CGFloat = 24
		let indicator = getIndicatorView()
		indicator.frame = CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
		indicator.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.6)
		indicator.layer.cornerRadius = size / 2
		indicator.alpha = 1.0

		framebufferView.addSubview(indicator)

		UIView.animate(withDuration: 0.15, delay: 0.1, options: .curveEaseOut) {
			indicator.alpha = 0
		} completion: { [weak self] _ in
			self?.returnIndicatorToPool(indicator)
		}
	}

	// MARK: - Gesture Handlers

	@objc private func handleTap(_ gesture: UITapGestureRecognizer) {
		let touchPoint = gesture.location(in: framebufferView)
		let fbPoint = touchPointToFramebuffer(touchPoint)

		moveCursor(to: fbPoint)
		showTapIndicator(at: touchPoint)
		beginPointerModifiersIfNeeded()
		framebufferViewControllerDelegate?.framebufferViewController(self, mouseDownAt: fbPoint)
		framebufferViewControllerDelegate?.framebufferViewController(self, mouseUpAt: fbPoint)
		endPointerModifiersIfNeeded()

		lightHaptic.impactOccurred()
	}

	@objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
		let touchPoint = gesture.location(in: framebufferView)
		let fbPoint = touchPointToFramebuffer(touchPoint)

		moveCursor(to: fbPoint)

		// Double ripple for double-click
		showTapIndicator(at: touchPoint)
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
			self?.showTapIndicator(at: touchPoint)
		}

		beginPointerModifiersIfNeeded()
		framebufferViewControllerDelegate?.framebufferViewController(self, mouseDownAt: fbPoint)
		framebufferViewControllerDelegate?.framebufferViewController(self, mouseUpAt: fbPoint)
		framebufferViewControllerDelegate?.framebufferViewController(self, mouseDownAt: fbPoint)
		framebufferViewControllerDelegate?.framebufferViewController(self, mouseUpAt: fbPoint)
		endPointerModifiersIfNeeded()

		mediumHaptic.impactOccurred()
	}

	@objc private func handleTwoFingerTap(_ gesture: UITapGestureRecognizer) {
		let touchPoint = gesture.location(in: framebufferView)
		let fbPoint = touchPointToFramebuffer(touchPoint)

		moveCursor(to: fbPoint)

		// Orange ripple for right-click
		showTapIndicator(at: touchPoint, color: .systemOrange)

		beginPointerModifiersIfNeeded()
		framebufferViewControllerDelegate?.framebufferViewController(self, rightMouseDownAt: fbPoint)
		framebufferViewControllerDelegate?.framebufferViewController(self, rightMouseUpAt: fbPoint)
		endPointerModifiersIfNeeded()

		mediumHaptic.impactOccurred()
	}

	@objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
		let touchPoint = gesture.location(in: framebufferView)
		let fbPoint = touchPointToFramebuffer(touchPoint)

		switch gesture.state {
		case .began:
			lastPanPoint = touchPoint
			moveCursor(to: fbPoint)
			framebufferViewControllerDelegate?.framebufferViewController(self, mouseDidMove: fbPoint)

		case .changed:
				if isDragging {
					moveCursor(to: fbPoint)
					framebufferViewControllerDelegate?.framebufferViewController(self, mouseDidMove: fbPoint)
				} else if currentScale > 1.01 {
					let delta = CGPoint(x: touchPoint.x - lastPanPoint.x, y: touchPoint.y - lastPanPoint.y)
					panOffset.x += delta.x
					panOffset.y += delta.y
					lastPanPoint = touchPoint
					clampPanOffset()
					updateTransform()
					updateCursorPosition() // Keep cursor in place when panning view
				} else {
					moveCursor(to: fbPoint)
					framebufferViewControllerDelegate?.framebufferViewController(self, mouseDidMove: fbPoint)
				}

		default:
			break
		}
	}

	@objc private func handleTwoFingerPan(_ gesture: UIPanGestureRecognizer) {
		let touchPoint = gesture.location(in: framebufferView)
		let fbPoint = touchPointToFramebuffer(touchPoint)
		let translation = gesture.translation(in: framebufferView)
		let velocity = gesture.velocity(in: framebufferView)

		switch gesture.state {
			case .began:
				beginPointerModifiersIfNeeded()
			case .changed:
				// Calculate velocity-based multiplier for acceleration (faster scrolls = more steps)
				let velocityMagnitude = sqrt(velocity.x * velocity.x + velocity.y * velocity.y)
				let accelerationMultiplier = max(1.0, min(5.0, velocityMagnitude / 500.0))

				// Invert Y for natural scrolling: swiping up scrolls content up (reveals content below)
				// Apply acceleration multiplier for responsive fast scrolling
				let scrollDelta = CGPoint(
					x: translation.x * accelerationMultiplier,
					y: -translation.y * accelerationMultiplier
				)
				framebufferViewControllerDelegate?.framebufferViewController(self, scrollDelta: scrollDelta, mousePosition: fbPoint)
				gesture.setTranslation(.zero, in: framebufferView)
			case .ended, .cancelled, .failed:
				endPointerModifiersIfNeeded()
			default:
				break
		}
	}

	@objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
		switch gesture.state {
			case .began, .changed:
				let anchorPoint = gesture.location(in: framebufferView)
				let anchoredFramebufferPoint = touchPointToFramebuffer(anchorPoint)
				let newScale = currentScale * gesture.scale
				currentScale = max(minScale, min(maxScale, newScale))
				gesture.scale = 1.0
				updatePanOffset(keeping: anchorPoint, anchoredTo: anchoredFramebufferPoint)
				updateTransform()

			case .ended:
				if currentScale < 1.05 && currentScale > 0.95 {
					currentScale = 1.0
					panOffset = .zero
					updateTransform()
				}

		default:
			break
		}
	}

	@objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
		let touchPoint = gesture.location(in: framebufferView)
		let fbPoint = touchPointToFramebuffer(touchPoint)

		switch gesture.state {
			case .began:
				isDragging = true
				moveCursor(to: fbPoint)
				showDragIndicator(at: touchPoint)
				beginPointerModifiersIfNeeded()
				framebufferViewControllerDelegate?.framebufferViewController(self, mouseDownAt: fbPoint)
				heavyHaptic.impactOccurred()

		case .changed:
			moveCursor(to: fbPoint)
			framebufferViewControllerDelegate?.framebufferViewController(self, mouseDidMove: fbPoint)

			case .ended, .cancelled:
				isDragging = false
				framebufferViewControllerDelegate?.framebufferViewController(self, mouseUpAt: fbPoint)
				endPointerModifiersIfNeeded()

			default:
				break
		}
	}

	// MARK: - Transform

	private func updateTransform() {
		CATransaction.begin()
		CATransaction.setDisableActions(true)

		let safeScale = max(currentScale, .leastNonzeroMagnitude)
		framebufferContentView.transform = CGAffineTransform(scaleX: safeScale, y: safeScale)
			.translatedBy(x: panOffset.x / safeScale, y: panOffset.y / safeScale)
		updateCursorPosition()

		CATransaction.commit()
	}

	private func applyFramebufferImage(_ cgImage: CGImage?) {
		let interval = perfSignposter.beginInterval("applyFramebufferImage")
		let start = CACurrentMediaTime()

		framebufferImageView.image = cgImage.map(UIImage.init(cgImage:))

		let duration = CACurrentMediaTime() - start
		perfSignposter.endInterval("applyFramebufferImage", interval)

		if let cgImage {
			if !hasReceivedFirstFrame {
				hasReceivedFirstFrame = true
				hideLoadingOverlay()
			}
			if isDebugInfoEnabled {
				debugInfoApplyDurations.record(duration)
			}
			recordDebugInfoRender(cgImage: cgImage)
		} else {
			logger?.logError("Framebuffer update produced nil CGImage for iOS viewer")
		}
	}

	private func updateDebugInfoVisibility() {
		debugInfoLabel?.isHidden = !isDebugInfoEnabled
		if isDebugInfoEnabled {
			beginPerfSession()
			updateDebugInfoLabel(force: true)
		} else {
			endPerfSession()
		}
	}

	private func beginPerfSession() {
		guard debugInfoCSVHandle == nil else { return }

		debugInfoCgImageDurations.reset()
		debugInfoApplyDurations.reset()
		debugInfoFrameIntervals.reset()
		debugInfoUpdateToRenderLatencies.reset()
		debugInfoLastRenderTime = nil
		debugInfoPendingUpdateArrival = nil
		debugInfoWindowStart = CACurrentMediaTime()

		do {
			let docs = try FileManager.default.url(
				for: .documentDirectory,
				in: .userDomainMask,
				appropriateFor: nil,
				create: true
			)
			let formatter = DateFormatter()
			formatter.dateFormat = "yyyyMMdd-HHmmss"
			let stamp = formatter.string(from: Date())
			let url = docs.appendingPathComponent("perf-\(stamp).csv")
			try Data().write(to: url)

			let handle = try FileHandle(forWritingTo: url)
			let header = "timestamp_iso,uptime_sec,fps,updates_per_sec,coalesced_per_sec,dirty_pct,cgimage_avg_ms,cgimage_p95_ms,apply_avg_ms,apply_p95_ms,frame_interval_p50_ms,frame_interval_p95_ms,update_to_render_p50_ms,update_to_render_p95_ms,fb_width,fb_height\n"
			if let data = header.data(using: .utf8) {
				try? handle.write(contentsOf: data)
			}
			debugInfoCSVHandle = handle
			debugInfoCSVURL = url
			logger?.logDebug("Perf CSV recording to \(url.path)")
		} catch {
			logger?.logError("Failed to open perf CSV: \(error.localizedDescription)")
		}
	}

	private func formatUptime(_ seconds: TimeInterval) -> String {
		let total = Int(seconds)
		let hours = total / 3600
		let minutes = (total % 3600) / 60
		let secs = total % 60
		if hours > 0 {
			return String(format: "%d:%02d:%02d", hours, minutes, secs)
		}
		return String(format: "%d:%02d", minutes, secs)
	}

	private func endPerfSession() {
		guard let handle = debugInfoCSVHandle else { return }
		try? handle.close()
		if let url = debugInfoCSVURL {
			logger?.logDebug("Perf CSV finalized at \(url.path)")
		}
		debugInfoCSVHandle = nil
		debugInfoCSVURL = nil
	}

	private func recordDebugInfoUpdate(width: UInt16, height: UInt16, wasCoalesced: Bool) {
		guard isDebugInfoEnabled else { return }

		debugInfoUpdateCount += 1
		if wasCoalesced {
			debugInfoCoalescedUpdateCount += 1
		}
		debugInfoDirtyPixelCount += Double(width) * Double(height)
		// Stamp the earliest arrival time of an update batch so the next
		// applyFramebufferImage can compute the update→render latency.
		if debugInfoPendingUpdateArrival == nil {
			debugInfoPendingUpdateArrival = CACurrentMediaTime()
		}
		updateDebugInfoLabel(force: false)
	}

	private func recordDebugInfoRender(cgImage: CGImage) {
		guard isDebugInfoEnabled else { return }

		debugInfoRenderCount += 1
		if framebufferSize == .zero {
			framebufferSize = CGSize(width: cgImage.width, height: cgImage.height)
		}

		let now = CACurrentMediaTime()
		if let last = debugInfoLastRenderTime {
			debugInfoFrameIntervals.record(now - last)
		}
		debugInfoLastRenderTime = now

		if let arrival = debugInfoPendingUpdateArrival {
			debugInfoUpdateToRenderLatencies.record(now - arrival)
			debugInfoPendingUpdateArrival = nil
		}

		updateDebugInfoLabel(force: false)
	}

	private func updateDebugInfoLabel(force: Bool) {
		guard isDebugInfoEnabled,
			  let debugInfoLabel else { return }

		let now = CACurrentMediaTime()
		let elapsed = now - debugInfoWindowStart
		guard force || elapsed >= 1 else { return }

		let window = max(elapsed, 0.001)
		let renderFPS = Double(debugInfoRenderCount) / window
		let updatesPerSecond = Double(debugInfoUpdateCount) / window
		let coalescedPerSecond = Double(debugInfoCoalescedUpdateCount) / window
		let framebufferPixels = max(Double(framebufferSize.width * framebufferSize.height), 1)
		let averageDirtyPercent = debugInfoUpdateCount > 0
			? (debugInfoDirtyPixelCount / (framebufferPixels * Double(debugInfoUpdateCount))) * 100
			: 0

		let cgImageAvgMs = debugInfoCgImageDurations.average * 1000
		let cgImageP95Ms = debugInfoCgImageDurations.percentile(0.95) * 1000
		let applyAvgMs = debugInfoApplyDurations.average * 1000
		let applyP95Ms = debugInfoApplyDurations.percentile(0.95) * 1000
		let intervalP50Ms = debugInfoFrameIntervals.percentile(0.5) * 1000
		let intervalP95Ms = debugInfoFrameIntervals.percentile(0.95) * 1000
		let latencyP50Ms = debugInfoUpdateToRenderLatencies.percentile(0.5) * 1000
		let latencyP95Ms = debugInfoUpdateToRenderLatencies.percentile(0.95) * 1000

		let uptimeSec = connectionStartedAt.map { Date().timeIntervalSince($0) } ?? 0
		let uptimeText = formatUptime(uptimeSec)

		if isHUDCollapsed {
			debugInfoLabel.text = String(
				format: " 📊 %.0f fps  %.0fms ",
				renderFPS, intervalP95Ms
			)
		} else {
			debugInfoLabel.text = String(
				format: " Up %@  FPS %.1f\n Interval p50 %.0fms  p95 %.0fms\n Update→render p95 %.0fms\n Updates %.1f/s  Coalesced %.1f/s\n cgImage p95 %.2fms  apply p95 %.2fms\n Dirty %.1f%%  FB %d×%d ",
				uptimeText, renderFPS,
				intervalP50Ms, intervalP95Ms,
				latencyP95Ms,
				updatesPerSecond, coalescedPerSecond,
				cgImageP95Ms, applyP95Ms,
				averageDirtyPercent,
				Int(framebufferSize.width), Int(framebufferSize.height)
			)
		}
		relayoutHUDPreservingEdge()

		if let handle = debugInfoCSVHandle {
			let iso = ISO8601DateFormatter().string(from: Date())
			let row = String(
				format: "%@,%.1f,%.2f,%.2f,%.2f,%.2f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%d,%d\n",
				iso, uptimeSec,
				renderFPS, updatesPerSecond, coalescedPerSecond, averageDirtyPercent,
				cgImageAvgMs, cgImageP95Ms, applyAvgMs, applyP95Ms,
				intervalP50Ms, intervalP95Ms, latencyP50Ms, latencyP95Ms,
				Int(framebufferSize.width), Int(framebufferSize.height)
			)
			if let data = row.data(using: .utf8) {
				try? handle.write(contentsOf: data)
			}
		}

		debugInfoWindowStart = now
		debugInfoRenderCount = 0
		debugInfoUpdateCount = 0
		debugInfoCoalescedUpdateCount = 0
		debugInfoDirtyPixelCount = 0
	}
}

// MARK: - Display Link

extension CAFramebufferViewController: DisplayLinkDelegate {
	private func addDisplayLink() {
		guard settings?.useDisplayLink == true else {
			removeDisplayLink()
			return
		}

		if displayLink == nil {
			let newDisplayLink = DisplayLink()
			newDisplayLink.delegate = self
			displayLink = newDisplayLink
		}

		displayLink?.isEnabled = true
		logger?.logDebug("iOS display link rendering enabled")
	}

	private func removeDisplayLink() {
		guard let oldDisplayLink = self.displayLink else { return }

		oldDisplayLink.delegate = nil
		oldDisplayLink.isEnabled = false
		self.displayLink = nil
	}

	func displayLinkDidUpdate(_ displayLink: DisplayLink) {
		guard needsRender else { return }
		needsRender = false

		let framebuffer = pendingFramebuffer
		let cgImage: CGImage?
		if let framebuffer {
			let interval = perfSignposter.beginInterval("cgImage")
			let start = CACurrentMediaTime()
			cgImage = framebuffer.cgImage
			let duration = CACurrentMediaTime() - start
			perfSignposter.endInterval("cgImage", interval)
			if isDebugInfoEnabled {
				debugInfoCgImageDurations.record(duration)
			}
		} else {
			cgImage = nil
		}

		self.applyFramebufferImage(cgImage)
	}
}

// MARK: - Framebuffer Updates

extension CAFramebufferViewController {
	func frameSizeDidChange(_ size: CGSize) {
		DispatchQueue.main.async { [weak self] in
			guard let self = self else { return }
			self.framebufferSize = size
			self.invalidateScaleRatioCache()
			self.clampPanOffset()

			// Center cursor if it's at origin (initial state)
			if self.cursorPosition == .zero {
				self.cursorPosition = CGPoint(x: size.width / 2, y: size.height / 2)
			}
			self.updateCursorPosition()
		}
	}

	// swiftlint:disable identifier_name - x,y match VNCConnectionDelegate API
	public func framebufferDidUpdate(_ framebuffer: VNCFramebuffer,
							  x: UInt16, y: UInt16,
							  width: UInt16, height: UInt16) {
		// swiftlint:enable identifier_name
		perfSignposter.emitEvent(
			"framebufferDidUpdate",
			"x=\(x) y=\(y) w=\(width) h=\(height)"
		)
		let sizeChanged = framebufferSize != framebuffer.size.cgSize
		let newSize = framebuffer.size.cgSize

		// When display link is active, just mark dirty and let
		// the display link callback handle the actual render
		if settings?.useDisplayLink == true, displayLink != nil {
			DispatchQueue.main.async { [weak self] in
				guard let self = self else { return }

				if sizeChanged {
					self.framebufferSize = newSize
					self.invalidateScaleRatioCache()
					self.clampPanOffset()
				}

				self.recordDebugInfoUpdate(width: width,
										   height: height,
										   wasCoalesced: self.needsRender)
				self.pendingFramebuffer = framebuffer
				self.needsRender = true
			}
			return
		}

		let cgImageInterval = perfSignposter.beginInterval("cgImage")
		let cgImageStart = CACurrentMediaTime()
		let cgImage = framebuffer.cgImage
		let cgImageDuration = CACurrentMediaTime() - cgImageStart
		perfSignposter.endInterval("cgImage", cgImageInterval)

		DispatchQueue.main.async { [weak self] in
			guard let self = self else { return }

			CATransaction.begin()
			CATransaction.setDisableActions(true)

			if sizeChanged {
				self.framebufferSize = newSize
				self.invalidateScaleRatioCache()
				self.clampPanOffset()
			}

			CATransaction.commit()
			if self.isDebugInfoEnabled {
				self.debugInfoCgImageDurations.record(cgImageDuration)
			}
			self.recordDebugInfoUpdate(width: width,
									   height: height,
									   wasCoalesced: false)
			self.applyFramebufferImage(cgImage)
		}
	}

	public func updateCursor(_ cursor: VNCCursor) {
		DispatchQueue.main.async { [weak self] in
			guard let self = self else { return }

			if cursor.isEmpty {
				// Revert to default arrow pointer
				self.cursorImageView?.isHidden = true
				self.defaultCursorLayer?.isHidden = false
				self.cursorHotspot = .zero
				self.cursorView?.bounds = CGRect(x: 0, y: 0, width: 24, height: 24)
				self.cursorView?.layer.shadowPath = self.defaultCursorLayer?.path
			} else if let cgImage = cursor.cgImage {
				// Use server-sent cursor image
				let image = UIImage(cgImage: cgImage)
				self.cursorImageView?.image = image
				self.cursorImageView?.frame = CGRect(origin: .zero, size: cursor.cgSize)
				self.cursorImageView?.isHidden = false
				self.defaultCursorLayer?.isHidden = true
				self.cursorHotspot = cursor.cgHotspot
				let cursorBounds = CGRect(origin: .zero, size: cursor.cgSize)
				self.cursorView?.bounds = cursorBounds
				self.cursorView?.layer.shadowPath = UIBezierPath(rect: cursorBounds).cgPath
			}

			self.updateCursorPosition()
		}
	}
}

// MARK: - Keyboard Input

extension CAFramebufferViewController: UITextFieldDelegate {
	public func textFieldShouldReturn(_ textField: UITextField) -> Bool {
		sendKey(.return)
		return false
	}

	public func textField(_ textField: UITextField,
				   shouldChangeCharactersIn range: NSRange,
				   replacementString string: String) -> Bool {
		let keys = VNCKeyCode.keyCodesFrom(characters: string)
		for key in keys {
			sendKey(key)
		}

		return false
	}
}

// MARK: - Hardware Keyboard Handling

private extension CAFramebufferViewController {
	func handleHardwareKeyDown(_ keyCode: VNCKeyCode) {
		framebufferViewControllerDelegate?.framebufferViewController(self, keyDown: keyCode)
	}

	func handleHardwareKeyUp(_ keyCode: VNCKeyCode) {
		framebufferViewControllerDelegate?.framebufferViewController(self, keyUp: keyCode)
	}

	func handleHardwareModifier(_ keyCode: VNCKeyCode,
								isDown: Bool) {
		if isDown {
			guard !activeHardwareModifiers.contains(keyCode) else { return }
			activeHardwareModifiers.append(keyCode)
			framebufferViewControllerDelegate?.framebufferViewController(self, keyDown: keyCode)
		} else {
			guard let index = activeHardwareModifiers.firstIndex(of: keyCode) else { return }
			activeHardwareModifiers.remove(at: index)
			framebufferViewControllerDelegate?.framebufferViewController(self, keyUp: keyCode)
		}
	}

	/// No-op: With the new modifier handling, modifiers are already held on the server
	/// when toggled on, so no additional action needed for pointer events
	func beginPointerModifiersIfNeeded() {
		// Modifiers are already held on server when toggled - no action needed
	}

	/// Release one-shot modifiers (Cmd/Ctrl/Option) after a click or drag so
	/// combos like Cmd+click feel intentional. Shift stays held.
	func endPointerModifiersIfNeeded() {
		releaseOneShotModifiers()
	}
}

#endif
