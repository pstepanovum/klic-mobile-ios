#!/usr/bin/env bash
#
# Shared mobile release entrypoint for Klic.
# - Always keeps Android + iOS version numbers in sync when both repos are present.
# - Publishes the current platform by default.
# - Optionally also publishes the sibling platform after a confirmation prompt.
#
# Usage:
#   ./release.sh            # auto-bump patch version
#   ./release.sh 0.4.3      # explicit shared version
#
set -euo pipefail
# Without this, a build failing inside $(build_android ...) does NOT abort the
# script — bash drops errexit in command substitutions — and a stale artifact
# gets released. This bit us once. macOS bash 3.2 lacks the option (hence the
# guard), so the [ -f ... ] checks after each build are the real safety net.
shopt -s inherit_errexit 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SELF_DIR="$SCRIPT_DIR"
SELF_NAME="$(basename "$SELF_DIR")"

if [ "$SELF_NAME" = "klic-mobile-android" ]; then
  SELF_PLATFORM="android"
  SIBLING_PLATFORM="ios"
  SIBLING_DIR="$(cd "$SELF_DIR/../klic-mobile-ios" 2>/dev/null && pwd || true)"
else
  SELF_PLATFORM="ios"
  SIBLING_PLATFORM="android"
  SIBLING_DIR="$(cd "$SELF_DIR/../klic-mobile-android" 2>/dev/null && pwd || true)"
fi

ANDROID_DIR=""
IOS_DIR=""

if [ "$SELF_PLATFORM" = "android" ]; then
  ANDROID_DIR="$SELF_DIR"
  IOS_DIR="$SIBLING_DIR"
else
  IOS_DIR="$SELF_DIR"
  ANDROID_DIR="$SIBLING_DIR"
fi

ANDROID_GRADLE_REL="app/build.gradle.kts"
IOS_PROJECT_REL="project.yml"

require_dir() {
  local dir="$1"
  [ -n "$dir" ] && [ -d "$dir" ]
}

android_version_name() {
  grep -E 'versionName = ' "$1/$ANDROID_GRADLE_REL" | head -1 | sed -E 's/.*"([^"]+)".*/\1/'
}

android_version_code() {
  grep -E 'versionCode = ' "$1/$ANDROID_GRADLE_REL" | head -1 | sed -E 's/.*= *([0-9]+).*/\1/'
}

ios_version_name() {
  grep -E 'MARKETING_VERSION: ' "$1/$IOS_PROJECT_REL" | head -1 | sed -E 's/.*"([^"]+)".*/\1/'
}

ios_version_code() {
  grep -E 'CURRENT_PROJECT_VERSION: ' "$1/$IOS_PROJECT_REL" | head -1 | sed -E 's/.*"([^"]+)".*/\1/'
}

bump_patch() {
  local version="$1"
  IFS=. read -r major minor patch <<< "$version"
  echo "${major}.${minor}.$((patch + 1))"
}

update_android_version() {
  local dir="$1"
  local version="$2"
  local code="$3"
  sed -i '' -E "s/versionName = \"[^\"]+\"/versionName = \"${version}\"/" "$dir/$ANDROID_GRADLE_REL"
  sed -i '' -E "s/versionCode = [0-9]+/versionCode = ${code}/" "$dir/$ANDROID_GRADLE_REL"
}

update_ios_version() {
  local dir="$1"
  local version="$2"
  local code="$3"
  sed -i '' -E "s/MARKETING_VERSION: \"[^\"]+\"/MARKETING_VERSION: \"${version}\"/" "$dir/$IOS_PROJECT_REL"
  sed -i '' -E "s/CURRENT_PROJECT_VERSION: \"[^\"]+\"/CURRENT_PROJECT_VERSION: \"${code}\"/" "$dir/$IOS_PROJECT_REL"
}

ensure_clean_tag() {
  local dir="$1"
  local tag="$2"
  if git -C "$dir" rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    echo "Tag $tag already exists in $dir"
    exit 1
  fi
}

confirm_yes() {
  local prompt="$1"
  local answer
  read -r -p "$prompt [y/N] " answer || true
  case "${answer:-}" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

build_android() {
  local dir="$1"
  local version="$2"
  local build_dir="$dir/build-android"
  local apk="$build_dir/klic-${version}.apk"
  echo "Building Android APK..." >&2
  mkdir -p "$build_dir"
  (
    cd "$dir"
    # stdout of this function is the artifact path — keep build logs on stderr
    ./gradlew assembleDebug 1>&2
  ) || { echo "ERROR: gradle build failed" >&2; exit 1; }
  cp "$dir/app/build/outputs/apk/debug/app-debug.apk" "$apk"
  ARTIFACT_ANDROID_APK="$apk"
}

build_ios() {
  local dir="$1"
  local version="$2"
  local build_root="$dir/build-ios"
  local unsigned_dir="$build_root/unsigned"
  local signed_dir="$build_root/signed"
  local unsigned_archive_path="/tmp/klic-${version}-unsigned.xcarchive"
  local signed_archive_path="/tmp/klic-${version}-signed.xcarchive"
  local export_dir="/tmp/klic-${version}-signed-export"
  local unsigned_ipa_path="$unsigned_dir/klic-ios-${version}-unsigned.ipa"
  local signed_ipa_path="$signed_dir/klic-ios-${version}-signed.ipa"
  local payload_dir="/tmp/klic-ipa-payload-${version}"
  local export_options_plist="/tmp/klic-export-options-${version}.plist"
  local team_id
  echo "Building iOS IPA..." >&2
  (
    cd "$dir"
    if command -v xcodegen >/dev/null 2>&1; then
      xcodegen generate --quiet 1>&2
    else
      echo "xcodegen not found — skipping project regeneration (xcodeproj must already be up to date)" >&2
    fi
    # xcodegen rewrites the pbxproj, which drops CocoaPods integration — reinstall.
    if [ -f Podfile ]; then
      pod install 1>&2
    fi
  ) || { echo "ERROR: project generation failed" >&2; exit 1; }

  mkdir -p "$unsigned_dir" "$signed_dir"
  rm -f "$unsigned_ipa_path" "$signed_ipa_path"
  rm -rf "$unsigned_archive_path" "$signed_archive_path" "$payload_dir" "$export_dir"

  (
    cd "$dir"
    # CocoaPods projects must build via the workspace. (Plain string, not an
    # array: empty-array expansion breaks under set -u on macOS bash 3.2.)
    workspace_flag=""
    if [ -d "Klic.xcworkspace" ]; then
      workspace_flag="-workspace Klic.xcworkspace"
    fi
    # shellcheck disable=SC2086
    xcodebuild archive \
      $workspace_flag \
      -scheme Klic \
      -destination 'generic/platform=iOS' \
      -disableAutomaticPackageResolution \
      -onlyUsePackageVersionsFromResolvedFile \
      -sdk iphoneos \
      -configuration Release \
      -archivePath "$unsigned_archive_path" \
      CODE_SIGN_IDENTITY="" \
      CODE_SIGNING_REQUIRED=NO \
      CODE_SIGNING_ALLOWED=NO \
      DEVELOPMENT_TEAM="" \
      -quiet 1>&2
  ) || { echo "ERROR: unsigned xcodebuild archive failed" >&2; exit 1; }

  mkdir -p "$payload_dir/Payload"
  cp -r "$unsigned_archive_path/Products/Applications/Klic.app" "$payload_dir/Payload/"
  (cd "$payload_dir" && zip -qr "$unsigned_ipa_path" Payload)

  team_id="$(grep -E 'DEVELOPMENT_TEAM: ' "$dir/$IOS_PROJECT_REL" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
  if [ -z "$team_id" ]; then
    echo "ERROR: DEVELOPMENT_TEAM not found in $dir/$IOS_PROJECT_REL; cannot export signed IPA" >&2
    exit 1
  fi

  cat > "$export_options_plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>development</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>teamID</key>
  <string>${team_id}</string>
  <key>stripSwiftSymbols</key>
  <true/>
  <key>compileBitcode</key>
  <false/>
</dict>
</plist>
EOF

  (
    cd "$dir"
    workspace_flag=""
    if [ -d "Klic.xcworkspace" ]; then
      workspace_flag="-workspace Klic.xcworkspace"
    fi
    # shellcheck disable=SC2086
    xcodebuild archive \
      $workspace_flag \
      -scheme Klic \
      -destination 'generic/platform=iOS' \
      -disableAutomaticPackageResolution \
      -onlyUsePackageVersionsFromResolvedFile \
      -sdk iphoneos \
      -configuration Release \
      -archivePath "$signed_archive_path" \
      -allowProvisioningUpdates \
      -quiet 1>&2
  ) || { echo "ERROR: signed xcodebuild archive failed" >&2; exit 1; }

  xcodebuild -exportArchive \
    -archivePath "$signed_archive_path" \
    -exportPath "$export_dir" \
    -exportOptionsPlist "$export_options_plist" \
    -allowProvisioningUpdates \
    -quiet 1>&2 || { echo "ERROR: signed IPA export failed" >&2; exit 1; }

  local exported_ipa
  exported_ipa="$(find "$export_dir" -type f -name '*.ipa' | head -1)"
  if [ -z "$exported_ipa" ]; then
    echo "ERROR: signed IPA export did not produce an .ipa file" >&2
    exit 1
  fi
  cp "$exported_ipa" "$signed_ipa_path"

  rm -rf "$payload_dir" "$unsigned_archive_path" "$signed_archive_path" "$export_dir"
  rm -f "$export_options_plist"
  ARTIFACT_IOS_UNSIGNED_IPA="$unsigned_ipa_path"
  ARTIFACT_IOS_SIGNED_IPA="$signed_ipa_path"
}

commit_tag_push_android() {
  local dir="$1"
  local tag="$2"
  local branch
  branch="$(git -C "$dir" rev-parse --abbrev-ref HEAD)"
  git -C "$dir" add "$ANDROID_GRADLE_REL"
  git -C "$dir" commit -m "Release ${tag}" || echo "(nothing to commit in Android)"
  git -C "$dir" tag "$tag"
  git -C "$dir" push origin "$branch" --tags
}

commit_tag_push_ios() {
  local dir="$1"
  local tag="$2"
  local branch
  branch="$(git -C "$dir" rev-parse --abbrev-ref HEAD)"
  git -C "$dir" add "$IOS_PROJECT_REL"
  git -C "$dir" commit -m "Release ${tag}" || echo "(nothing to commit in iOS)"
  git -C "$dir" tag "$tag"
  git -C "$dir" push origin "$branch" --tags
}

publish_android_release() {
  local version="$1"
  local code="$2"
  local tag="$3"
  local apk="$4"
  gh release create "$tag" "${apk}#Klic ${version} (Android APK)" \
    --repo pstepanovum/klic-mobile-android \
    --title "Klic ${version}" \
    --notes "Android debug build. Install via the in-app updater (Settings → App updates) or by downloading the APK. Shared mobile version ${version} (build ${code})."
}

publish_ios_release() {
  local version="$1"
  local code="$2"
  local tag="$3"
  local ipa="$4"
  gh release create "$tag" "${ipa}#Klic ${version} (iOS IPA — unsigned)" \
    --repo pstepanovum/klic-mobile-ios \
    --title "Klic ${version}" \
    --notes "Unsigned IPA for sideloading via AltStore or similar tools. AltStore will re-sign it with your personal certificate. Shared mobile version ${version} (build ${code})."
}

current_version=""
current_code=""

if require_dir "$ANDROID_DIR"; then
  current_version="$(android_version_name "$ANDROID_DIR")"
  current_code="$(android_version_code "$ANDROID_DIR")"
elif require_dir "$IOS_DIR"; then
  current_version="$(ios_version_name "$IOS_DIR")"
  current_code="$(ios_version_code "$IOS_DIR")"
else
  echo "Neither Android nor iOS repo was found."
  exit 1
fi

new_version="${1:-}"
if [ -z "$new_version" ]; then
  new_version="$(bump_patch "$current_version")"
fi
new_code=$((current_code + 1))
tag="v${new_version}"

publish_sibling=false
sync_sibling=false

if [ "$SIBLING_PLATFORM" = "ios" ] && require_dir "$IOS_DIR"; then
  sync_sibling=true
  if confirm_yes "Also publish iOS from ${IOS_DIR}?"; then
    publish_sibling=true
  fi
elif [ "$SIBLING_PLATFORM" = "android" ] && require_dir "$ANDROID_DIR"; then
  sync_sibling=true
  if confirm_yes "Also publish Android from ${ANDROID_DIR}?"; then
    publish_sibling=true
  fi
else
  echo "Sibling repo for ${SIBLING_PLATFORM} was not found. Only ${SELF_PLATFORM} will be published."
fi

echo "==========================================="
echo "Shared mobile release"
echo "  ${current_version} (${current_code}) -> ${new_version} (${new_code})"
echo "  tag=${tag}"
echo "  current platform : ${SELF_PLATFORM}"
echo "  sibling publish  : ${publish_sibling}"
echo "  sibling sync     : ${sync_sibling}"
echo "==========================================="

if require_dir "$ANDROID_DIR"; then
  ensure_clean_tag "$ANDROID_DIR" "$tag"
fi
if require_dir "$IOS_DIR"; then
  ensure_clean_tag "$IOS_DIR" "$tag"
fi

if require_dir "$ANDROID_DIR"; then
  update_android_version "$ANDROID_DIR" "$new_version" "$new_code"
fi
if require_dir "$IOS_DIR"; then
  update_ios_version "$IOS_DIR" "$new_version" "$new_code"
fi

ARTIFACT_ANDROID_APK=""
ARTIFACT_IOS_UNSIGNED_IPA=""
ARTIFACT_IOS_SIGNED_IPA=""

# A build function's stdout must be exactly one line: the artifact path. Verify the
# file really exists before releasing anything — on bash < 4.4 a build failure inside
# $(...) does not abort the script, and a stale artifact must never ship again.
require_artifact() {
  local path="$1"
  local label="$2"
  if [ ! -f "$path" ]; then
    echo "ERROR: $label build did not produce an artifact (got: ${path:0:120})" >&2
    exit 1
  fi
}

if [ "$SELF_PLATFORM" = "android" ]; then
  build_android "$ANDROID_DIR" "$new_version"
  require_artifact "$ARTIFACT_ANDROID_APK" "Android"
  if [ "$publish_sibling" = true ] && require_dir "$IOS_DIR"; then
    build_ios "$IOS_DIR" "$new_version"
    require_artifact "$ARTIFACT_IOS_UNSIGNED_IPA" "iOS unsigned"
    require_artifact "$ARTIFACT_IOS_SIGNED_IPA" "iOS signed"
  fi
else
  build_ios "$IOS_DIR" "$new_version"
  require_artifact "$ARTIFACT_IOS_UNSIGNED_IPA" "iOS unsigned"
  require_artifact "$ARTIFACT_IOS_SIGNED_IPA" "iOS signed"
  if [ "$publish_sibling" = true ] && require_dir "$ANDROID_DIR"; then
    build_android "$ANDROID_DIR" "$new_version"
    require_artifact "$ARTIFACT_ANDROID_APK" "Android"
  fi
fi

if require_dir "$ANDROID_DIR"; then
  echo "Committing/tagging Android repo..." >&2
  commit_tag_push_android "$ANDROID_DIR" "$tag"
fi
if require_dir "$IOS_DIR"; then
  echo "Committing/tagging iOS repo..." >&2
  commit_tag_push_ios "$IOS_DIR" "$tag"
fi

if [ "$SELF_PLATFORM" = "android" ]; then
  publish_android_release "$new_version" "$new_code" "$tag" "$ARTIFACT_ANDROID_APK"
  if [ "$publish_sibling" = true ] && [ -n "$ARTIFACT_IOS_UNSIGNED_IPA" ]; then
    publish_ios_release "$new_version" "$new_code" "$tag" "$ARTIFACT_IOS_UNSIGNED_IPA"
  else
    echo "Skipped iOS artifact release."
  fi
else
  publish_ios_release "$new_version" "$new_code" "$tag" "$ARTIFACT_IOS_UNSIGNED_IPA"
  if [ "$publish_sibling" = true ] && [ -n "$ARTIFACT_ANDROID_APK" ]; then
    publish_android_release "$new_version" "$new_code" "$tag" "$ARTIFACT_ANDROID_APK"
  else
    echo "Skipped Android artifact release."
  fi
fi

echo ""
echo "==========================================="
echo "Released ${tag}"
echo "  Shared version : ${new_version} (${new_code})"
if [ -n "$ARTIFACT_ANDROID_APK" ]; then
  echo "  Android APK    : $ARTIFACT_ANDROID_APK"
fi
if [ -n "$ARTIFACT_IOS_UNSIGNED_IPA" ]; then
  echo "  iOS unsigned   : $ARTIFACT_IOS_UNSIGNED_IPA"
fi
if [ -n "$ARTIFACT_IOS_SIGNED_IPA" ]; then
  echo "  iOS signed     : $ARTIFACT_IOS_SIGNED_IPA"
fi
echo "==========================================="
