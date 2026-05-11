# RoyalVNCKitUI

An iOS rendering and input layer on top of
[RoyalVNCKit](https://github.com/royalapplications/royalvnc) — the
cross-platform VNC protocol + macOS framebuffer view from
[Royal Applications](https://royalapps.com).

RoyalVNCKit ships a macOS `NSView`-backed framebuffer renderer but no
iOS equivalent. `RoyalVNCKitUI` adds:

- A `UIViewController`-based framebuffer view backed by a `CALayer`
  pipeline (smooth pan/zoom, edge-snap clamps, low-latency cursor
  redraws).
- Gesture handling — pan, pinch, two-finger tap-as-right-click,
  modifier keys (Shift sticky, Cmd/Ctrl/Option one-shot).
- A `RemoteKeyboardTextField` overlay that bridges UIKit text input
  into raw VNC keyboard events.
- A loading overlay with auto-reconnect grace and a share-sheet
  affordance.
- An optional in-app performance HUD (FPS, frame-interval jitter,
  update-to-render latency, CSV export via signposts).

## Installation

Embed as a git submodule and reference by path in your app's
`Package.swift`:

```swift
.package(path: "Vendor/vncat")
```

Then depend on the library product:

```swift
.product(name: "RoyalVNCKitUI", package: "vncat")
```

The package has a nested `royalvnc` submodule pointing at upstream
RoyalVNCKit — clone with `--recurse-submodules` (or run
`git submodule update --init --recursive` after a plain clone).

## Platforms

- iOS 15+
- macOS 11+ (RoyalVNCKit's own macOS renderer is used directly; this
  package's UI layer is iOS-only)

## Layout

```
Sources/RoyalVNCKitUI/iOS/   The UIKit/CALayer rendering layer.
royalvnc/                    Nested submodule: upstream RoyalVNCKit.
Package.swift                Library target definition.
```

## License

See [LICENSE](LICENSE). RoyalVNCKit itself is MIT-licensed by Royal
Applications — see `royalvnc/LICENSE` for the upstream terms.
