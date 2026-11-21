# Release packaging

Use Xcode 26 or compatible command-line tools for builds. Use a Developer ID Application certificate and the Apple notarization tools for public distribution.

## Local build

```sh
Scripts/test.sh
ARCHS="arm64 x86_64" Scripts/package.sh
codesign --verify --deep --strict dist/GlassStats.app
(cd dist && shasum -a 256 -c GlassStats.zip.sha256)
```

This produces an ad-hoc signed Universal app and ZIP. The extension is compiled and embedded. Live widget snapshots require the signed App Group below.

## Developer ID release

1. Set your version and build number in both `Resources/*-Info.plist` files. Set your unique bundle ID and Apple Team ID. The packaging script uses the macOS team-prefixed App Group convention and applies the group to both targets. [Apple App Group entitlements](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.application-groups)
2. Build with the distribution identity. The script signs the widget first, then the app, with the hardened runtime.
3. Submit the ZIP using a configured notarytool keychain profile. After acceptance, staple the app and create a fresh ZIP. [Apple notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)

```sh
ARCHS="arm64 x86_64" BUNDLE_ID="com.example.glassstats" TEAM_ID="YOURTEAMID" \
  SIGN_IDENTITY="Developer ID Application: Your Name (YOURTEAMID)" Scripts/package.sh
xcrun notarytool submit dist/GlassStats.zip --keychain-profile GlassStatsNotary --wait
xcrun stapler staple dist/GlassStats.app
rm dist/GlassStats.zip
ditto -c -k --sequesterRsrc --keepParent dist/GlassStats.app dist/GlassStats.zip
(cd dist && shasum -a 256 GlassStats.zip > GlassStats.zip.sha256)
spctl --assess --type execute --verbose dist/GlassStats.app
```

Test the extracted archive in a fresh user session. Open the widget gallery, add the overview and ports widgets, and check that each displays a dated snapshot. Click Ports to verify the link opens the inspector. Test an Apple Silicon Mac and an Intel Mac before publishing a Universal release. Upload the ZIP and checksum to the GitHub release alongside the changelog.

## License

The project uses MIT. It permits reuse and redistribution with a short attribution requirement and suits a dependency-free monitoring utility intended for community maintenance.
