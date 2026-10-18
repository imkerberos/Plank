# Plank

A macOS desktop panel built with Swift and AppKit, inspired by XFCE Panel and designed as an alternative to the system Dock.

## Requirements

- macOS 14 or later
- Swift 6 or later, using Xcode or Command Line Tools
- Swift Package Manager; no third-party package dependencies

## Development

```sh
swift build
swift run Plank
```

You can also open `Package.swift` in Xcode. Right-click the panel handle and choose **Quit Plank** to exit. When running from a terminal, you can also press Ctrl-C.

## Building the App

```sh
./scripts/build-app.sh
open dist/Plank.app
```

The script builds an ad hoc signed application for local use. Before distributing it, configure your own bundle identifier, Developer ID signing, and notarization.

The original app icon is in `Assets/AppIcon.png`. The build script generates the multi-resolution `Assets/AppIcon.icns` and bundles it with the app. Design notes and the generation prompt are in `Assets/README.md`.

## Features

- A translucent floating panel at the bottom of the primary display that does not take keyboard focus during normal use.
- Running application buttons with active-app highlighting and updates when apps launch or quit.
- Support for multiple desktop Spaces and horizontal scrolling when content overflows.
- Adjustable panel width: right-click the panel handle, choose **Settings…**, and set the width to 10%–100% of the screen. The default is 100%. At 100%, the panel spans the screen and has square corners. Changes apply immediately and are saved automatically.
- Modular plugins, with the default order: **iMenu → Separator → Show Desktop → Separator → Launcher → Separator → Taskbar → expanding Space → Separator → Clock (Binary) → Trash**. Existing custom arrangements are preserved.

By default, Plank uses the screen's usable area and sits above the system Dock. You can enable automatic Dock hiding in System Settings → Desktop & Dock. Plank does not change the Dock unless you enable **Hide System Dock**.

## Limitations and Future Work

Future work includes more status plugins, panel positioning, and multi-display support. System-wide screen-edge reservation, panel auto-hide, and the full feature set of the macOS Dock are not implemented.

## Launch at Login

Enable **Launch at Login** in panel settings to start Plank automatically when you log in. Turning it off removes the login item. Plank uses `SMAppService.mainApp` and displays the actual system registration status. If approval is required, choose **Open Login Items Settings…** to grant it.

Move `Plank.app` to a permanent location, such as `/Applications`, before enabling this option. Launch at login cannot be configured when running the command-line executable directly.

## Git

Source code is managed with Git. Build caches and packaged applications are excluded by `.gitignore`.

## Replacing the System Dock and Reserving Window Space

**Hide System Dock** is off by default. Before enabling it, grant Plank Accessibility access in System Settings. Without permission, Plank leaves the Dock unchanged. Use **Open Accessibility Settings…** in panel settings, grant access, and enable the option again.

When enabled, Plank turns on Dock auto-hide, sets its reveal delay to one day to suppress edge activation, and restarts the Dock. Plank moves to the physical bottom edge of the primary display using its configured height. Window clearance applies across the entire bottom edge, even if panel width is less than 100%.

macOS exposes `NSScreen.visibleFrame` as a read-only property. Public APIs do not let third-party applications register a reserved screen area equivalent to the Dock. Plank does not change display resolution or the system-wide usable screen area. Instead, it records the original work area before hiding the Dock and adjusts eligible windows to leave room for the panel.

Windows previously maximized or tiled against the Dock boundary can shrink or expand to match Plank's height, including reclaiming space left by a taller Dock. The original work area is saved with the Dock recovery data and checked against the display identity and screen geometry before reuse.

Plank uses Accessibility notifications and periodic checks to adjust near-maximized or full-height tiled windows on the primary display. It preserves the menu bar area, horizontal position, and width. Small floating windows, dialogs, minimized windows, and windows on other displays or Spaces are left alone. Apps that reject Accessibility resizing or enforce minimum sizes may not fit. Native full-screen windows are not resized; Plank hides while they are active.

Turning the option off or quitting normally restores the original Dock auto-hide and reveal-delay settings, removing preferences that did not originally exist. Plank also attempts to restore windows that still have their adjusted geometry; it does not overwrite subsequent manual moves or resizes.

After an unexpected exit, the Dock may remain hidden temporarily. On the next launch, Plank reads its saved settings and restores the Dock or resumes replacement mode. Recovery data is removed only after restoration succeeds. Rebuilding the ad hoc signed app may require granting Accessibility access again.

The implementation uses Apple's [visibleFrame API](https://developer.apple.com/documentation/appkit/nsscreen/visibleframe) and [Accessibility trust checks](https://developer.apple.com/documentation/applicationservices/1460720-axisprocesstrusted). Preference and geometry checks use a simulated Dock backend and do not change the test machine's Dock.

## Locking the Panel

Toggle **Lock Panel** in the panel context menu to hide the panel and plugin handles and disable plugin dragging, including reordering in the Plugins window. Any active plugin move is canceled. The lock state is saved automatically.

Right-click an empty area of the locked panel and turn off **Lock Panel** to restore the handles. App switching, Launcher, and iMenu remain available while locked. Plugin settings remain accessible through the Plugins window.

## Panel Height

Open **Settings…** from the panel menu and choose a height: **Large (80 pt)**, **Medium (64 pt)**, **Small (48 pt)**, **Tiny (32 pt)**, or **Custom (32–128 pt)**. Medium is the default. Changes apply immediately and are saved automatically. Press Return to apply a custom value; switching presets preserves the last custom height.

Plugin containers and Taskbar and Launcher buttons fill the panel height, with no panel padding or inter-plugin spacing. Icons retain their own visual inset. Trash, iMenu, and handles also scale with panel height; separator lines span the full height. Clock text remains at a readable font size.

## Managing Plugins

Right-click the panel or its left-hand handle—the three vertical dots—and choose **Plugins…**.

- Drag rows to reorder plugins. The panel updates immediately and saves the order.
- Double-click a row to open settings for that instance. Every plugin supports a custom name. Clock settings include **Use 24-Hour Time** and **Show Seconds**; the clock width follows the displayed text.
- Clock offers **Digital**, **Analog**, and **Binary** styles. Digital and Binary support 12-hour or 24-hour time. Analog uses a 12-hour dial, with an optional second hand. Binary encodes each decimal digit in a column of dots weighted 8, 4, 2, 1 from top to bottom; groups are hours, minutes, and optional seconds. Hover over any style for the full date and readable time. Existing clocks default to Digital, and each instance saves its own style.
- Choose **Add…** to add Taskbar, Separator, Clock, Trash, Launcher, iMenu, or Show Desktop. Multiple instances of the same type are supported, each with independent settings.
- Select a row and choose **Remove** to remove that instance.
- Hidden instances remain in the list. Right-click a hidden row and choose **Show Plugin** to restore it.

Separator supports **Line** and **Space** styles. Space can have a fixed width of 8–400 pt, or **Expand to fill remaining panel space**. Multiple expanding spaces share the available width equally. When content overflows, spaces retain a minimum width and the panel scrolls horizontally.

## Show Desktop

Add **Show Desktop** from the Plugins window. Click its monitor icon to move windows aside and reveal the desktop; click again to restore them. The panel stays visible during Show Desktop. The button supports all panel sizes, including Tiny (32 pt), and remains usable while the panel is locked.

This plugin uses the Dock's internal `CoreDockSendNotification` interface with `com.apple.showdesktop.awake`, following [Hammerspoon's implementation](https://github.com/Hammerspoon/hammerspoon/blob/master/extensions/spaces/spaces.lua). It does not require Hammerspoon, send keyboard shortcuts, or minimize individual windows. The interface is private and may change in future macOS versions; if it cannot be loaded or returns an error, Plank displays an error instead of attempting a different action. It leaves multi-display and Spaces behavior to macOS and does not maintain its own active-state indicator.

## Context Menus

Panel and plugin context menus open above the panel without being confined to its short window, avoiding clipped menus and scrolling arrows. Use the arrow keys to select an action, Return to run it, and Esc or an outside click to close.

Right-click the Taskbar handle for plugin actions. Right-click an application button for **Show**, **Hide/Unhide**, **Show in Finder**, and **Quit**. Finder does not offer Quit. Application menus remain available while the panel is locked; right-click an empty area for the panel menu and unlock action.

Right-click the Trash icon for **Open Trash** or **Empty Trash…**, including while the panel is locked. Emptying Trash displays a confirmation dialog with **Cancel** as the default. After confirmation, Finder empties the Trash. This requires permission for Plank to control Finder under Privacy & Security → Automation. Emptying Trash permanently deletes its contents.

## Taskbar

Finder appears first by default. Enable **Hide Finder** in each Taskbar plugin's settings to remove it from that Taskbar. Other applications retain their window opening order.

Enable **Hide apps in Launcher** to omit applications with shortcuts in any enabled Launcher on the panel. Disabled Launchers are ignored. Each Launcher also offers **Show running app indicator**, which draws a small dot below running applications. Both options default to off and are saved independently for each plugin.

With **Show running app indicator** enabled, right-click a Launcher shortcut for app actions alongside **Remove Shortcut**. Running apps offer **Show Windows**, **Hide/Unhide**, **Show in Finder**, and **Quit** (except Finder). Show Windows restores minimized windows with Accessibility access and sends the app a reopen request. Apps that are not running offer **Open** and **Show in Finder**.

### App Badges

Launcher and Taskbar mirror app badges exposed by the system Dock, including when the Dock is auto-hidden. Badges appear on the icon, including Taskbar's Icons and Titles mode. Counts above 99 display as **99+**; long nonnumeric labels display as a red dot. The full original label remains available to accessibility tools.

Reading badges requires Accessibility access for Plank. Grant it in System Settings → Privacy & Security → Accessibility (also accessible from panel settings). Badges update approximately once per second without rebuilding the panel. An app must have a Dock item that exposes an `AXStatusLabel`; apps that paint custom icons without exposing a label, or have no accessible Dock item, cannot be mirrored. Plank does not read notification databases or infer unread counts. If access is unavailable, buttons work normally without badges.

### Ordering and Appearance

Taskbar groups buttons by application and orders them by when Plank first observes each application's earliest remaining window. Switching the foreground app does not reorder buttons. Windows already present when Plank starts, or first detected in the same polling cycle, have no known historical order and fall back to application-name sorting. Apps without windows follow apps with windows. Detection runs every 0.5 seconds and includes minimized windows and windows in other Spaces.

Double-click Taskbar in the Plugins list, or right-click its handle and choose **Plugin Settings…**, to select **Icons Only** or **Icons and Titles**. Titles use the application name, with the icon on the left. Labeled buttons size to their content up to a configurable maximum of 80–400 pt, defaulting to 180 pt. Long titles are truncated; hover to see the full name. Icon-only buttons use the panel height as their width.

Each Taskbar instance saves its own style and width. Older configurations default to icons only. Clicking an inactive app uses Launch Services to reopen it: apps with windows are brought forward, while apps without windows receive the standard reopen request and decide whether to create or restore a window. This activation path does not require Accessibility or Automation access.

Clicking the current foreground application's button minimizes its focused standard window. A subsequent click uses the standard reopen request to restore a window. Minimizing requires Accessibility access, and macOS prompts on first use. Without permission, or if the window cannot be minimized, Plank retains its normal activation behavior. **Show** in the context menu always displays the app; dragging an app to Launcher does not minimize it.

## iMenu

Add **iMenu** in the Plugins window, then click its four-square icon to open a compact menu of approximately 400 × 480 pt. Search by application display name or filename. Click a result or press Return to launch it, use the arrow keys to navigate, and press Esc or click outside to close. An empty result list shows a message.

In iMenu settings, choose **Display as → List View** (default) or **Icon View**. Icon View arranges larger app icons with names in a grid that adapts to the menu width. Search, arrow-key navigation, and launching work in both modes. Each iMenu saves its display mode independently.

iMenu uses an arrowless rounded floating window that sits flush against the panel. It adjusts its position near the left and right screen edges, retaining an 8 pt screen margin.

Drag the menu's edges or corners to resize it. Each iMenu remembers its size across launches, with screen bounds limiting its maximum size. The menu stays attached to the panel while resizing.

The application count and usage hints appear beside the **Applications** heading. The bottom row provides **Lock**, **Sleep**, **Restart…**, and **Shut Down…**, using Google Material Design icons. Restart and Shut Down display a confirmation dialog with Cancel as the default. These actions use AppleScript to control System Events and require permission under System Settings → Privacy & Security → Automation. Lock also requires Accessibility access. Icons and their Apache 2.0 license are bundled with the app; see `Sources/Plank/Resources/MaterialIcons/NOTICE.txt` for attribution.

The application catalog refreshes in the background whenever the menu opens. It scans `/Applications`, `/System/Applications`, system utilities, and `~/Applications`, and includes Finder. Scanning skips helpers inside app bundles, hidden files, and background apps, and deduplicates paths. The menu adapts to available screen space without entering full screen.

## Launcher

Choose **Add… → Launcher** in the Plugins window. Drag one or more `.app` bundles from Finder, or an application button from Taskbar, onto **＋ Drop Apps Here** or an existing Launcher icon to add shortcuts. The drop area highlights when it accepts the drag. Both icon-only and labeled Taskbar buttons can be dragged. Dropping only adds a shortcut; it does not launch or quit the app. Canceling a drag adds nothing.

- Click a shortcut to open or activate its app. Buttons highlight when pressed and briefly after release.
- Right-click an icon and choose **Remove Shortcut** to remove only the shortcut.
- Adding the same app to a Launcher again does not create duplicates. Multiple Launchers keep independent shortcut lists.
- Drag icons horizontally to reorder them. An insertion marker shows the destination. Release outside the panel to remove the Launcher shortcut; the application itself is not deleted or quit. Releasing elsewhere inside the panel, outside Launcher, cancels the reorder. Locking the panel disables dragging but still allows launching apps.
- Shortcuts persist across restarts. If an app is moved or deleted, remove its old shortcut and add it again.
- Only local application bundles are accepted. A drop containing ordinary files is rejected as a whole.

Dragging a Taskbar button outside the panel has no effect. Taskbar supports drops into Launcher within Plank; it does not offer file drops to other applications.

## Handles and Moving Plugins

Every plugin except Separator has a three-dot vertical handle on its left. Click or right-click it to open the plugin menu. Right-click a separator directly; its narrow hit area also works in Space mode.

Choose **Move** in a plugin menu to highlight the plugin, then drag horizontally and release to reorder it. Release outside the panel or choose **Cancel Move** to cancel. Plugin menus also offer hiding and settings; Trash additionally offers Open Trash and Empty Trash.

## Project Structure and Checks

`Sources/Plank/PanelPlugin.swift` defines the plugin protocol. Each built-in plugin lives in its own file and supplies its settings controls, validation, and save logic through `PluginSettingsContent`. `PluginSettingsWindowController` provides the shared window, name field, and layout. `PluginPreferences.swift` stores instances, ordering, and per-instance settings. To add a plugin, implement the protocol (including `makeSettings`) and register it in the available-types list and `PluginFactory.swift`. Plugins are compiled into the app; external dynamic plugins and dropping files onto Trash are not supported.

Older plugin ordering and visibility settings migrate automatically. Checks cover Launcher validation, deduplication, sorting, instance isolation, removal cleanup, Taskbar ordering, panel dimensions, application discovery, Dock recovery, and reserved-window geometry. They use an isolated preferences domain and do not modify your panel configuration:

```sh
./scripts/check-preferences.sh
```
