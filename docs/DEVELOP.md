# Developing Plank

This document covers source builds and implementation details. For installation, settings, permissions, and daily use, see the [user guide](../README.md).

## Requirements

- macOS 14 or later.
- Swift 6 or later, supplied by Xcode or Command Line Tools.
- Swift Package Manager. The package has no third-party package dependencies.

Source code is managed with Git. `.build/`, `.swiftpm/`, `dist/`, and user-specific Xcode files are ignored.

## Build and Run

From the repository root:

```sh
swift build
swift run Plank
```

You can also open `Package.swift` in Xcode. Use the panel menu's **Quit Plank** action to exit normally, particularly when testing Dock replacement. Abrupt termination can leave Dock recovery work for the next launch.

To build an app bundle:

```sh
./scripts/build-app.sh
open dist/Plank.app
```

The script performs a release build, generates the icon, copies the executable and resource bundle, writes `Info.plist`, and applies an ad hoc signature. Its bundle identifier is `dev.plank.panel`. Local builds are not Developer ID signed or notarized; configure signing and notarization before distribution.

Install the bundle in a permanent location such as `/Applications` before testing login registration. `SMAppService.mainApp` requires the app bundle rather than the standalone command-line executable. Rebuilding an ad hoc signed app may require reviewing its macOS privacy permissions again.

## Architecture

The app uses Swift and AppKit. UI and plugin ownership are isolated to the main actor; potentially blocking work such as catalog scans, badge reads, and Trash status queries runs outside the UI path.

| File or component | Responsibility |
| --- | --- |
| `Sources/Plank/main.swift` | Application lifecycle, panel construction, plugin instances, layout, menus, and refresh coordination. |
| `PanelPlugin.swift` | Plugin protocol and default implementations. |
| `PluginFactory.swift` | Maps plugin kinds to concrete types for runtime instances and settings content. |
| `PluginPreferences.swift` | Codable instance configuration, default layout, ordering, visibility, and migration. |
| `PanelPreferences.swift` | Height presets and panel preferences shared by the UI and geometry logic. |
| `PluginContainer.swift`, `PanelHandle.swift` | Plugin wrappers, handles, panel-side move behavior, and separator drawing. |
| `PluginsWindowController.swift` | Plugin management, row dragging, insertion indicator, addition, deletion, and settings navigation. |
| `PluginSettingsContent.swift` | Shared settings-content interface for controls, validation, and configuration updates. |
| `PluginSettingsWindowController.swift`, `SettingsUI.swift` | Shared settings window, name field, cards, and layout. |
| `SettingsWindowController.swift` | Panel appearance, startup, Dock replacement, and plugin-manager entry point. |
| `PanelMenu.swift` | Popup context menus, panel views, and inactive-panel cursor tracking. |

Each plugin owns its views and resources and implements `init(id:)`, `view`, `refresh()`, and `makeSettings(configuration:)`. Optional lifecycle hooks include `setPanelHeight`, `stop`, and plugin-specific menu items. The panel owns plugin lifetimes and stops disabled or removed instances.

Plugin-specific settings controls and save logic live in the corresponding plugin file. The generic settings window retains their `PluginSettingsContent` and supplies an `onChange` callback; plugin controls request a save, after which the window persists the configuration and refreshes the panel.

To add a plugin:

1. Implement `PanelPlugin` in its own file, including settings content and resource cleanup.
2. Register its kind and display name in `PluginPreferences.available`.
3. Register its type in `PluginFactory.swift` and its settings icon in `SettingsUI.symbol(for:)`.
4. Add optional, backward-compatible fields to `PluginConfiguration` if needed.
5. Update defaults only if the plugin should appear on new panels. Do not add new types to the legacy one-per-type migration list.
6. Verify independent instances, disabling/removal, settings persistence, panel locking, and supported heights.

Plugins are compiled into the executable; there is no external dynamic-plugin loader.

## Panel and Input Behavior

The panel is a borderless, nonactivating `NSPanel` that cannot become key or main during normal use. It floats at the bottom of the primary display, joins desktop Spaces, and uses `.stationary` so Show Desktop leaves it visible. Dock replacement manages native full-screen visibility separately.

Width defaults to 100%, with square corners at that width and rounded corners below it. Heights are Tiny 32, Small 48, Medium 64 (default), Large 80, or custom 32–128 pt. Plugin containers and buttons fill the panel height, with no panel padding or inter-plugin spacing. Expanding separators share remaining width; overflow scrolls horizontally.

`PanelMenu` presents compact context menus in a popover rather than constraining native menus to the panel's short frame. It supports keyboard selection, Return, Esc, and outside-click dismissal.

`PanelBackgroundView` uses `.activeAlways` tracking areas with mouse-entered and mouse-moved events to replace cursor state inherited from other applications. Apple's tracking rules do not deliver `cursorUpdate` with `.activeAlways`. Normal panel regions set an arrow; a moving plugin uses an open-hand cursor. Tracking does not require making the panel key or installing a global mouse monitor.

Panel locking prevents direct panel-side plugin moves and Launcher shortcut drags. The Plugins management window intentionally remains editable while locked. Its custom table drag handling draws an explicit insertion line; Esc, an outside release, or a reload clears the drag state.

## Themes

`PanelPreferences.theme` persists `system`, `dark`, or `light` under `panelTheme`, defaulting to system for missing or unknown values. `ThemeController` sets `NSApplication.appearance` to nil, Dark Aqua, or Aqua so existing and future windows, panels, and popovers share the choice. A nil override keeps system appearance changes live without polling or changing macOS settings.

Views use semantic AppKit colors and adaptive visual-effect materials. Custom Core Animation colors are resolved under the view’s effective appearance and refreshed on appearance changes, including Taskbar backgrounds, Launcher feedback, iMenu grid selection, and settings cards. Verify both live switching and saved startup appearance.

## Plugin Implementation Notes

### Taskbar

`TaskbarPlugin.swift` builds application buttons. `ApplicationButton.swift` handles activation, context menus, active-app appearance, and native dragging of application file URLs into Launcher. Exported drags support copying only within Plank; external drops do nothing.

`TaskbarWindowOrder` observes layer-zero application windows every 0.5 seconds, including minimized windows and windows in other Spaces. Each window receives a first-observed rank. Apps sort by their earliest remaining window; observations in the same batch have no known historical order and fall back to app-name sorting. Apps without windows follow those with windows. Finder is placed first unless hidden. Optional Launcher filtering compares canonical application paths across enabled Launchers.

`TaskbarWindowController` uses Accessibility to minimize the focused standard window of an active app. Activation uses Launch Services' reopen behavior, allowing the app to decide how to handle having no windows. Show Windows from Launcher restores and raises standard windows, then sends a reopen request. Finder is excluded from normal Quit actions.

### Launcher and Badges

`LauncherStore.swift` validates local application bundles, executable presence, canonical paths, duplicates, and per-instance shortcut ordering. Mixed drops containing unsupported files are rejected. Reordering uses insertion gaps in the original array. Removing a shortcut only changes preferences, never the app on disk.

Launcher buttons provide immediate pressed feedback and a short highlight after release. Clicking a shortcut reuses `TaskbarWindowController.minimizeFocusedWindow` for the active app, falling back to normal activation when minimization is unavailable. The context-menu Show Windows action keeps its reopen path and never toggles minimization. Optional running indicators match canonical paths against running applications. Enabling the indicator also enables application context-menu actions.

`DockBadgeCenter.swift` reads `AXStatusLabel` from system Dock application items off the main thread, approximately once per second. `AppBadgeView.swift` updates overlays without rebuilding the panel. `AppBadgeContent.swift` normalizes numeric labels, caps display at 99+, and uses dots for long nonnumeric labels. Full labels remain available to accessibility tools.

An initial badge snapshot is requested before Dock replacement restarts the Dock. This does not guarantee startup badges: the Dock can expose no value even when the app has unread content. Custom-painted icons or inaccessible/missing Dock items cannot be mirrored. No notification database is read and no unread counts are inferred.

### iMenu

`IMenuPlugin.swift` owns an arrowless resizable panel at popup-menu level. It anchors to the iMenu button, stays flush against the panel, and clamps to usable screen bounds without extra edge margins. It saves size independently per instance. Outside-click monitors and Esc dismiss it.

The menu provides list and icon-grid modes, filtering, keyboard navigation, and system-action buttons. `ApplicationCatalog.swift` scans `/Applications`, `/System/Applications`, system utilities, and `~/Applications`, and includes Finder. It skips hidden files, background applications, and nested helpers, deduplicates paths, and refreshes in the background on opening.

`SystemSessionAction.swift` uses AppleScript targeting System Events for Lock, Sleep, Restart, and Shut Down. Restart and Shut Down require confirmation with Cancel as the default; cancellation is not reported as an error. These actions use Automation permission, with Accessibility also needed for locking.

### Clock and Separator

`ClockPlugin.swift` contains `ClockStyle`, `ClockTime`, rendering, timer management, and settings. Digital and Binary support 12/24-hour time; Analog uses a 12-hour dial. Binary rendering uses decimal-digit columns with row weights 8, 4, 2, 1. Clock styles are independent per instance and update once per second. Older configurations without a style retain Digital; the new-panel default is Binary.

`SeparatorPlugin.swift` supplies settings for Line or Space. `SeparatorView` draws a one-point line explicitly across the full panel height, avoiding disappearing `NSBox.separator` rendering at narrow widths. Space accepts fixed widths of 8–400 pt or expansion to fill remaining panel width.

Clock’s optional `clockOpensCalendar` setting defaults to off for older and new instances. Its display routes clicks and accessibility presses to Launch Services using Calendar’s `com.apple.iCal` identifier; it does not read calendar data or require Calendar/Automation permission. Pointer drags are excluded from launching, and right-click plugin menus retain their behavior.

### Folder

`FolderPlugin.swift` contains the folder button and its settings. The optional `folderPath` field is saved per instance; an unset path defaults to the user’s home directory. Settings use a directory-only `NSOpenPanel`, and cancellation leaves the previous selection intact. The plugin shows the directory’s system icon and opens its contents explicitly through Finder, validating that the directory still exists before opening. It does not require Finder Automation permission for this Launch Services operation.

### Trash

`TrashPlugin.swift` opens Trash explicitly in Finder and provides Open Trash / Empty Trash context actions. Emptying uses Finder AppleScript only after confirmation; cancellation is ignored and Automation denial produces a helpful error.

The plugin uses `NSImage.trashEmptyName` and `NSImage.trashFullName`. A background Finder query checks whether the combined Trash contains an item at startup and approximately every two seconds, including Trash on mounted volumes. This avoids directly enumerating protected Trash directories. It requires Finder automation permission. Failed queries preserve the previous icon; before the first successful query, the empty icon is only a visual default. Disabling/removing the plugin stops its timer and cancels pending UI updates.

### Show Desktop

`ShowDesktopPlugin.swift` dynamically loads `CoreDockSendNotification` from HIServices and sends `com.apple.showdesktop.awake`, following [Hammerspoon's implementation](https://github.com/Hammerspoon/hammerspoon/blob/master/extensions/spaces/spaces.lua). The symbol is resolved at runtime so its absence does not prevent app startup. Missing symbols and nonzero return codes produce a user-visible error, with no alternative action attempted.

This is a private interface and may change across macOS versions. The plugin leaves display and Spaces behavior to macOS and maintains no local active-state flag, since the user can toggle Show Desktop externally. It neither depends on Hammerspoon nor synthesizes keyboard input.

## Dock Replacement and Window Space

`SystemDockController` coordinates Dock replacement and `WindowSpaceGuard`. Hide System Dock is opt-in and requires Accessibility trust. It snapshots the original Dock auto-hide and reveal-delay preferences, turns on auto-hide with a one-day reveal delay, and restarts the Dock.

macOS's [`NSScreen.visibleFrame`](https://developer.apple.com/documentation/appkit/nsscreen/visibleframe) is read-only. Plank does not change resolution or register a system-wide reserved screen area equivalent to the Dock. It records the original work area and adjusts eligible windows through Accessibility notifications and periodic checks.

Near-maximized and full-height tiled windows on the primary display may shrink or expand to match the panel height, reclaiming space left by a taller Dock. The logic preserves the menu-bar area, horizontal position, and width. It excludes smaller floating windows, dialogs, minimized windows, and windows on other displays or Spaces. Apps that reject resizing or enforce minimum sizes may not fit. Native full-screen windows are not resized.

Restoration avoids overwriting later manual moves/resizes. Dock preferences that originally did not exist are removed during restoration. Saved work-area data is checked against display identity and geometry before reuse. Recovery data is retained until restoration succeeds, allowing the next launch to restore or resume replacement after an unexpected exit.

External window managers must account for Plank independently: Hammerspoon's `screen:frame()` still reflects the system work area, not a Plank reservation. Any integration querying Plank windows must identify the actual bottom panel and exclude iMenu, context menus, and settings windows so a popup is not mistaken for reserved space.

## Configuration and Compatibility

The bundled app stores preferences in the `dev.plank.panel` UserDefaults domain, normally backed by `~/Library/Preferences/dev.plank.panel.plist`. Use the settings UI for changes; avoid editing the plist while the app is running because preferences are cached.

- `pluginConfigurations`: JSON-encoded data containing instance IDs, kinds, names, enabled state, and plugin options.
- `plugin.<id>.launcherPaths`: per-Launcher shortcut paths.
- `plugin.<id>.menuWidth` / `menuHeight`: per-iMenu popup dimensions.
- `panelWidthPercentage`, `panelHeightPreset`, `panelCustomHeight`, `panelLocked`, and `hideSystemDock`: panel preferences.

Optional fields keep older plugin configurations decodable. Legacy ordering/visibility migrates automatically, default Chinese built-in names are translated to English, and custom names are preserved. Default layouts must use stable, unique IDs for repeated separators. Existing saved configurations, including an empty panel, must not be replaced by new defaults.

## Checks and Manual Verification

From the repository root:

```sh
./scripts/check-preferences.sh
./scripts/build-app.sh
codesign --verify --deep --strict dist/Plank.app
git diff --check
```

The preferences script compiles the relevant production sources with `Tests/PluginPreferencesChecks.swift`. Checks use isolated preferences domains and temporary fixtures. They cover configuration migration, default layout, independent instances, removal, Launcher validation and ordering, Taskbar ordering/settings, badge normalization, clock encoding, panel dimensions, application discovery, and Dock rollback/recovery and window geometry. The Dock checks use a simulated backend and do not modify the machine's Dock.

Builds and model checks do not establish UI behavior. For changes affecting interaction, also verify the relevant paths in the app: panel sizes and locking, menu edges and dismissal, drag previews/cancellation, keyboard navigation, permissions, and cleanup. Show Desktop needs live toggle/restore verification; Trash switching needs authorized Finder queries. Test multi-display and full-screen behavior separately rather than inferring it from primary-display checks.

Use isolated test-app identities and preferences when practical. Do not replace a running user's app, alter their layout, empty their Trash, or terminate a Dock-replacement session abruptly merely to test a change. Restore any global desktop state toggled during a test.

## Icons and Resources

The original app icon is `Assets/AppIcon.png`. `scripts/build-icon.sh` uses `sips` and `iconutil` to generate the multi-resolution `Assets/AppIcon.icns`, which is copied into the bundle and referenced by `CFBundleIconFile`. Design notes and the generation prompt are in [Assets/README.md](../Assets/README.md).

Google Material Design system-action icons and their Apache 2.0 license are bundled in `Sources/Plank/Resources/MaterialIcons`; see [NOTICE.txt](../Sources/Plank/Resources/MaterialIcons/NOTICE.txt). Swift Package Manager copies these resources into `Plank_Plank.bundle`, which the app build script includes.

If an installed app's icon is stale, check the installed bundle's plist, icon decoding, and signature before changing packaging. App-specific Launch Services registration and Alfred's `reload` command can refresh stale entries without deleting system-wide caches.
