#!/usr/bin/env bash
#
# Builds, signs, notarises and packages Podlight for Mac, and writes the Sparkle appcast.
#
#   tools/mac-release.sh            # version from apps/mac/project.yml
#
# Needs on this Mac:
#   - the "Developer ID Application" certificate in the keychain
#   - notarisation credentials as a notarytool keychain profile, created once with
#       xcrun notarytool store-credentials podlight-notary \
#         --key <AuthKey_XXXX.p8> --key-id <KEY ID> --issuer <ISSUER ID>
#     (or NOTARY_PROFILE=<name> for another profile name)
#   - the Sparkle signing key in the keychain (account "podlight"), made by Sparkle's
#     generate_keys --account podlight
#
# Output in build/release: Podlight-<version>.dmg (notarised and stapled) and appcast.xml.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mac="$root/apps/mac"
out="$root/build/release"
derived="$root/build/release-dd"
profile="${NOTARY_PROFILE:-podlight-notary}"
version="$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"/\1/p' "$mac/project.yml")"
build_number="$(sed -n 's/^ *CURRENT_PROJECT_VERSION: "\(.*\)"/\1/p' "$mac/project.yml")"
app="$out/export/Podlight.app"
dmg="$out/Podlight-$version.dmg"

echo "==> Podlight $version ($build_number)"
# The app shows this version in its sidebar, settings and menu bar. A release tag on this commit
# must name the same version, so the number users see is the one they downloaded.
tag="$(git -C "$root" describe --tags --exact-match HEAD 2>/dev/null || true)"
if [[ -n "$tag" && "$tag" != "v$version" ]]; then
  echo "The commit is tagged $tag, but project.yml says $version. Bump MARKETING_VERSION first."
  exit 2
fi
rm -rf "$out"
mkdir -p "$out"

skip="${SKIP_NOTARIZE:-0}"   # 1: dry run up to a signed, un-notarised disk image

echo "==> Checking notarisation credentials (profile \"$profile\")"
if [[ "$skip" != 1 ]] && ! xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1; then
  echo "No notarytool profile \"$profile\". Create it once with:"
  echo "  xcrun notarytool store-credentials $profile --key <AuthKey.p8> --key-id <KEY ID> --issuer <ISSUER ID>"
  exit 2
fi

echo "==> Generating the Xcode project"
xcodegen generate --spec "$mac/project.yml" >/dev/null

echo "==> Archiving (universal)"
xcodebuild -project "$mac/Podlight.xcodeproj" -scheme Podlight -configuration Release \
  -derivedDataPath "$derived" -archivePath "$out/Podlight.xcarchive" \
  -destination 'generic/platform=macOS' ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  archive | grep -E "error:|warning: .*App/|ARCHIVE (SUCCEEDED|FAILED)" || true
[[ -d "$out/Podlight.xcarchive" ]] || { echo "archive failed"; exit 1; }

echo "==> Exporting with Developer ID"
xcodebuild -exportArchive -archivePath "$out/Podlight.xcarchive" -exportPath "$out/export" \
  -exportOptionsPlist "$mac/ExportOptions.plist" | grep -E "error|EXPORT (SUCCEEDED|FAILED)" || true
[[ -d "$app" ]] || { echo "export failed"; exit 1; }

echo "==> Verifying the signature"
codesign --verify --deep --strict --verbose=2 "$app"
# Read once into a variable: `grep -q` on a live pipe ends it early, and with pipefail that
# reads as a failure of codesign.
signature_info="$(codesign -dv --verbose=4 "$app" 2>&1)"
grep -q 'flags=.*runtime' <<<"$signature_info" || { echo "hardened runtime missing"; exit 1; }
grep -q 'Timestamp=' <<<"$signature_info" || { echo "no secure timestamp"; exit 1; }
grep 'Authority=Developer ID Application' <<<"$signature_info"

notarise() {
  if [[ "$skip" == 1 ]]; then echo "   (skipped: SKIP_NOTARIZE=1)"; return; fi
  xcrun notarytool submit "$1" --keychain-profile "$profile" --wait --timeout 30m
}
staple() {
  if [[ "$skip" == 1 ]]; then return; fi
  xcrun stapler staple "$1"
}

echo "==> Notarising the app"
# The app is stapled before the disk image is made, so a copy dragged out of the image carries
# its ticket and opens even without a network connection.
ditto -c -k --keepParent "$app" "$out/Podlight.zip"
notarise "$out/Podlight.zip"
staple "$app"

echo "==> Building the disk image"
# A designed window (background with an arrow, fixed icon positions) written by dmgbuild, which
# needs no Finder scripting and so runs headless. Finder cannot animate a disk image window; the
# app offers the move with an animation instead.
assets="$out/dmg-assets"
swift "$root/tools/dmg/background.swift" "$assets" >/dev/null
tiffutil -cathidpicheck "$assets/background.png" "$assets/background@2x.png" -out "$assets/background.tiff" >/dev/null
venv="$root/build/dmg-venv"
[[ -x "$venv/bin/dmgbuild" ]] || { python3 -m venv "$venv" && "$venv/bin/pip" install --quiet "dmgbuild==1.6.5"; }
"$venv/bin/dmgbuild" -s "$root/tools/dmg/settings.py" -D app="$app" -D background="$assets/background.tiff" \
  "Podlight" "$dmg" >/dev/null
codesign --sign "Developer ID Application" --timestamp "$dmg"

echo "==> Notarising the disk image"
notarise "$dmg"
staple "$dmg"

if [[ "$skip" != 1 ]]; then
  echo "==> Gatekeeper"
  spctl -a -vv -t install "$dmg"
  spctl -a -vv "$app"
fi

echo "==> Appcast"
sparkle_bin="$(find "$derived/SourcePackages/artifacts" -type d -path "*Sparkle/bin" | head -1)"
signature="$("$sparkle_bin/sign_update" --account podlight "$dmg")"
length="$(stat -f%z "$dmg")"
cat > "$out/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Podlight</title>
    <item>
      <title>Podlight $version</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$build_number</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/LOGIN-TB/podlight/releases/tag/v$version</sparkle:releaseNotesLink>
      <enclosure url="https://github.com/LOGIN-TB/podlight/releases/download/v$version/Podlight-$version.dmg"
                 type="application/octet-stream" $signature />
    </item>
  </channel>
</rss>
XML
grep -q 'sparkle:edSignature' "$out/appcast.xml" || { echo "appcast is not signed"; exit 1; }
echo "length check: $length bytes"

echo
echo "Done: $dmg"
echo "      $out/appcast.xml"
