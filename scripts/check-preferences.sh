#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
CHECK_DIR=$(mktemp -d)
trap 'rm -rf "$CHECK_DIR"' EXIT
swiftc -swift-version 6 -parse-as-library Sources/Plank/PluginPreferences.swift Sources/Plank/ClockPlugin.swift Sources/Plank/PanelPlugin.swift Sources/Plank/PluginSettingsContent.swift Sources/Plank/SettingsUI.swift Sources/Plank/PanelMenu.swift Sources/Plank/AppBadgeContent.swift Sources/Plank/LauncherStore.swift Sources/Plank/PanelPreferences.swift Sources/Plank/ApplicationCatalog.swift Sources/Plank/DockReplacementState.swift Sources/Plank/TaskbarOrderState.swift Tests/PluginPreferencesChecks.swift -o "$CHECK_DIR/check-preferences"
"$CHECK_DIR/check-preferences"
