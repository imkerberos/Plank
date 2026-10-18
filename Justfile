set shell := ["bash", "-euo", "pipefail", "-c"]

# Show available tasks.
default:
    @just --list

# Print the application version from its single source of truth.
version:
    #!/usr/bin/env bash
    set -euo pipefail
    version=$(cat VERSION)
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "VERSION must contain X.Y.Z" >&2; exit 2; }
    echo "$version"

# Build the debug executable.
build:
    swift build

# Run Plank (quit normally through the panel menu to restore the Dock).
run:
    swift run Plank

# Run isolated configuration and geometry checks without changing the Dock.
test:
    #!/usr/bin/env bash
    set -euo pipefail
    check_dir=$(mktemp -d)
    trap 'rm -rf "$check_dir"' EXIT
    swiftc -swift-version 6 -parse-as-library \
        Sources/Plank/{PluginPreferences,ClockPlugin,PanelPlugin,PluginSettingsContent,SettingsUI,PanelMenu,PluginContainer,AppBadgeContent,LauncherStore,PanelPreferences,ApplicationCatalog,DockReplacementState,TaskbarOrderState}.swift \
        Tests/PluginPreferencesChecks.swift -o "$check_dir/check-preferences"
    "$check_dir/check-preferences"

# Validate the debug build and patch whitespace.
check: build
    just --fmt --check
    just --quiet version >/dev/null
    git diff --check

# Run the local CI checks.
ci: check test

# Generate the app's multi-resolution icon.
icon:
    #!/usr/bin/env bash
    set -euo pipefail
    icon_dir=$(mktemp -d)
    trap 'rm -rf "$icon_dir"' EXIT
    iconset="$icon_dir/AppIcon.iconset"
    mkdir -p "$iconset"
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size" Assets/AppIcon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
        double=$((size * 2))
        sips -z "$double" "$double" Assets/AppIcon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$iconset" -o Assets/AppIcon.icns

# Build optimized binaries: native, arm64, x86_64, or universal.
[positional-arguments]
build-release arch="native":
    #!/usr/bin/env bash
    set -euo pipefail
    case "$1" in
        native) arch_args=() ;;
        arm64|x86_64) arch_args=(--arch "$1") ;;
        universal) arch_args=(--arch arm64 --arch x86_64) ;;
        *) echo "Unsupported architecture: $1" >&2; exit 2 ;;
    esac
    swift build -c release "${arch_args[@]}"

# Build and ad hoc sign dist/Plank.app using VERSION.
[positional-arguments]
build-app arch="native":
    #!/usr/bin/env bash
    set -euo pipefail
    architecture="$1"
    version=$(just --quiet version)
    case "$architecture" in
        native) arch_args=() ;;
        arm64|x86_64) arch_args=(--arch "$architecture") ;;
        universal) arch_args=(--arch arm64 --arch x86_64) ;;
        *) echo "Unsupported architecture: $architecture" >&2; exit 2 ;;
    esac
    just build-release "$architecture"
    just icon
    bin_dir=$(swift build -c release "${arch_args[@]}" --show-bin-path)
    app="dist/Plank.app"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp Assets/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
    cp "$bin_dir/Plank" "$app/Contents/MacOS/Plank"
    cp -R "$bin_dir/Plank_Plank.bundle" "$app/Contents/Resources/"
    cp packaging/Info.plist "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $version" "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $version" "$app/Contents/Info.plist"
    plutil -lint "$app/Contents/Info.plist"
    codesign --force --sign - "$app"
    just verify-app
    if [[ "$architecture" == universal ]]; then
        for slice in arm64 x86_64; do
            lipo "$app/Contents/MacOS/Plank" -verify_arch "$slice"
        done
    elif [[ "$architecture" != native ]]; then
        lipo "$app/Contents/MacOS/Plank" -verify_arch "$architecture"
    fi
    echo "Built $app ($architecture, $version)"

# Verify the packaged app, metadata, icon, and bundled resources.
verify-app:
    test -x dist/Plank.app/Contents/MacOS/Plank
    test -s dist/Plank.app/Contents/Resources/AppIcon.icns
    test -d dist/Plank.app/Contents/Resources/Plank_Plank.bundle
    plutil -lint dist/Plank.app/Contents/Info.plist
    codesign --verify --deep --strict dist/Plank.app
    test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' dist/Plank.app/Contents/Info.plist)" = "$(just --quiet version)"
    test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' dist/Plank.app/Contents/Info.plist)" = "$(just --quiet version)"

# Create and push the VERSION tag, then start the GitHub Draft Release workflow.
[positional-arguments]
release-draft tag="":
    #!/usr/bin/env bash
    set -euo pipefail
    requested="{{ tag }}"
    version=$(just --quiet version)
    if [[ -z "$requested" ]]; then
        release_tag="v$version"
    elif [[ "$requested" == v* ]]; then
        release_tag="$requested"
    else
        release_tag="v$requested"
    fi
    [[ "$release_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
        echo "Release tag must be vX.Y.Z" >&2
        exit 2
    }
    [[ "$release_tag" == "v$version" ]] || {
        echo "Release tag must match VERSION (v$version)" >&2
        exit 2
    }
    command -v gh >/dev/null 2>&1 || {
        echo "GitHub CLI (gh) is required; install it and run gh auth login first" >&2
        exit 1
    }
    branch=$(git branch --show-current)
    [[ -n "$branch" ]] || {
        echo "release-draft must run from a named branch" >&2
        exit 1
    }
    [[ -z "$(git status --porcelain)" ]] || {
        echo "working tree has uncommitted changes; commit them before release-draft" >&2
        exit 1
    }
    head=$(git rev-parse HEAD)
    remote_head=$(git rev-parse "origin/$branch" 2>/dev/null || true)
    [[ "$head" == "$remote_head" ]] || {
        echo "HEAD is not pushed to origin/$branch; push the current commit first" >&2
        exit 1
    }
    just ci
    if git show-ref --verify --quiet "refs/tags/$release_tag"; then
        tag_head=$(git rev-list -n 1 "$release_tag")
        [[ "$tag_head" == "$head" ]] || {
            echo "$release_tag already exists and does not point to HEAD" >&2
            exit 1
        }
    elif git ls-remote --exit-code --tags origin "refs/tags/$release_tag" >/dev/null 2>&1; then
        git fetch origin "refs/tags/$release_tag:refs/tags/$release_tag"
        tag_head=$(git rev-list -n 1 "$release_tag")
        [[ "$tag_head" == "$head" ]] || {
            echo "$release_tag already exists on origin and does not point to HEAD" >&2
            exit 1
        }
    else
        git tag -a "$release_tag" -m "Release $release_tag" "$head"
    fi
    git push origin "refs/tags/$release_tag"
    repo=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')
    gh workflow run release.yml --repo "$repo" --ref "$branch" --raw-field "tag=$release_tag"
    echo "Started Draft Release workflow for $release_tag"

# Publish an existing GitHub Draft Release after its artifacts are verified.
[positional-arguments]
release-publish tag:
    #!/usr/bin/env bash
    set -euo pipefail
    requested="{{ tag }}"
    if [[ "$requested" == v* ]]; then
        release_tag="$requested"
    else
        release_tag="v$requested"
    fi
    [[ "$release_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
        echo "Release tag must be vX.Y.Z" >&2
        exit 2
    }
    command -v gh >/dev/null 2>&1 || {
        echo "GitHub CLI (gh) is required; install it and run gh auth login first" >&2
        exit 1
    }
    repo=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')
    draft=$(gh release view "$release_tag" --repo "$repo" --json isDraft --jq '.isDraft')
    [[ "$draft" == true ]] || {
        echo "Refusing to publish $release_tag: the release does not exist as a draft" >&2
        exit 1
    }
    gh release edit "$release_tag" --repo "$repo" --draft=false
    echo "Published $repo/releases/tag/$release_tag"

# Create a DMG, zipped app, and SHA-256 checksums for download.
[positional-arguments]
package arch="native":
    #!/usr/bin/env bash
    set -euo pipefail
    version=$(just --quiet version)
    just build-app "$1"
    architecture="$1"
    if [[ "$architecture" == native ]]; then architecture=$(uname -m); fi
    archive="Plank-$version-macos-$architecture.app.zip"
    disk_image="Plank-$version-macos-$architecture.dmg"
    ditto -c -k --sequesterRsrc --keepParent dist/Plank.app "dist/$archive"
    staging=$(mktemp -d)
    trap 'rm -rf "$staging"' EXIT
    cp -R dist/Plank.app "$staging/Plank.app"
    ln -s /Applications "$staging/Applications"
    hdiutil create -volname "Plank" -srcfolder "$staging" -ov -format UDZO "dist/$disk_image" >/dev/null
    test -s "dist/$disk_image"
    hdiutil imageinfo "dist/$disk_image" >/dev/null
    (cd dist && shasum -a 256 "$archive" > "$archive.sha256")
    (cd dist && shasum -a 256 "$disk_image" > "$disk_image.sha256")
    echo "Packaged dist/$archive and dist/$disk_image"
