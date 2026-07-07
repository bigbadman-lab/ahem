# Ahem — Release Distribution Guide

Direct distribution for **getahem.com** (outside the Mac App Store).

**Current release target:** `0.9.0` (build `15`)

---

## Security warning

Never commit:

- Apple ID passwords
- App-specific passwords
- `notarytool` API keys
- Team IDs tied to private accounts (unless your org policy allows it in the repo)
- `.p12` certificate exports
- `.env` files with secrets

Store credentials in **Keychain** or **Xcode Accounts** only.

---

## 1. Prerequisites

### Apple Developer

1. Enrolled **Apple Developer Program** (Individual account is fine).
2. **Developer ID Application** certificate created in [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/certificates/list).
3. Certificate installed in **Keychain Access** on the Mac used for release builds.

Verify locally:

```bash
security find-identity -v -p codesigning
```

You should see a line containing `Developer ID Application: Your Name (TEAMID)`.

### Xcode project settings (local)

1. Open `Ahem.xcodeproj` in Xcode.
2. Select the **Ahem** target → **Signing & Capabilities**.
3. Set **Team** to your Apple Developer team (this sets `DEVELOPMENT_TEAM` locally in `xcuserdata` or project settings — do not commit private team data unless intended).
4. Confirm **Release** configuration uses:
   - **Signing Certificate:** Developer ID Application
   - **Hardened Runtime:** Enabled

The project already sets in `project.pbxproj`:

| Setting | Value |
|---|---|
| `CODE_SIGN_IDENTITY` (Release) | Developer ID Application |
| `ENABLE_HARDENED_RUNTIME` | YES |
| `PRODUCT_BUNDLE_IDENTIFIER` | com.getahem.Ahem |
| `MARKETING_VERSION` | 0.9.0 |
| `CURRENT_PROJECT_VERSION` | 15 |

---

## 2. Archive and export

### Option A — Xcode (recommended)

1. Select scheme **Ahem** and destination **Any Mac (Apple Silicon, Intel)**.
2. **Product → Archive**.
3. In the Organizer, select the archive → **Distribute App**.
4. Choose **Direct Distribution** (or **Developer ID** / **Copy App** depending on Xcode version).
5. Enable **Upload for notarization** if offered, or export the `.app` for manual notarization.
6. Export to a folder, e.g. `dist/export/`.

### Option B — Command line (after Team is configured)

```bash
xcodebuild -project Ahem.xcodeproj \
  -scheme Ahem \
  -configuration Release \
  -archivePath build/Ahem.xcarchive \
  archive

xcodebuild -exportArchive \
  -archivePath build/Ahem.xcarchive \
  -exportPath dist/export \
  -exportOptionsPlist ExportOptions.plist
```

Create `ExportOptions.plist` locally (do not commit if it contains team-specific data):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>destination</key>
    <string>export</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
```

---

## 3. Verify signing (before notarization)

Replace `dist/export/Ahem.app` with your actual path.

```bash
APP="dist/export/Ahem.app"

# Deep signature check
codesign --verify --deep --strict --verbose=2 "$APP"

# Display signing identity
codesign -dv --verbose=4 "$APP" 2>&1 | rg "Authority|Identifier|TeamIdentifier|Format"

# Bundle identity and version
/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$APP/Contents/Info.plist"

# Gatekeeper assessment (may fail before notarization)
spctl -a -vv -t execute "$APP"
```

Expected before notarization: `codesign` passes; `spctl` may report **rejected** until notarized.

---

## 4. Notarization

### Store credentials safely (one-time)

**Option A — App-specific password (recommended for individuals)**

1. Create an app-specific password at [appleid.apple.com](https://appleid.apple.com).
2. Store in Keychain:

```bash
xcrun notarytool store-credentials "AHEM_NOTARIZATION" \
  --apple-id "you@example.com" \
  --team-id "YOUR_TEAM_ID" \
  --password "xxxx-xxxx-xxxx-xxxx"
```

**Option App Store Connect API key (teams / automation)**

```bash
xcrun notarytool store-credentials "AHEM_NOTARIZATION" \
  --key "AuthKey_XXXXXX.p8" \
  --key-id "YOUR_KEY_ID" \
  --issuer "YOUR_ISSUER_ID"
```

Keep `.p8` keys outside the repo.

### Submit

Zip the app (required for `notarytool`):

```bash
APP="dist/export/Ahem.app"
ditto -c -k --keepParent "$APP" "dist/Ahem.zip"

xcrun notarytool submit "dist/Ahem.zip" \
  --keychain-profile "AHEM_NOTARIZATION" \
  --wait
```

Or use the helper script:

```bash
./Scripts/notarize.sh dist/export/Ahem.app
```

### Check status manually

```bash
xcrun notarytool history --keychain-profile "AHEM_NOTARIZATION"

xcrun notarytool log <submission-id> --keychain-profile "AHEM_NOTARIZATION"
```

---

## 5. Stapling

After notarization succeeds:

```bash
APP="dist/export/Ahem.app"

xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
```

`stapler validate` should report **The validate action worked!**

Re-verify Gatekeeper:

```bash
spctl -a -vv -t execute "$APP"
```

Expected: `source=Notarized Developer ID` and `accepted`.

---

## 6. Create DMG

After the app is signed, notarized, and stapled:

```bash
./Scripts/create_dmg.sh dist/export/Ahem.app 0.9.0-beta
```

Output: `dist/Ahem-0.9.0-beta.dmg`

The DMG contains:

- `Ahem.app`
- `Applications` shortcut (drag-to-install)

Optional DMG verification:

```bash
hdiutil attach dist/Ahem-0.9.0-beta.dmg
spctl -a -vv -t install /Volumes/Ahem/Ahem.app
hdiutil detach /Volumes/Ahem
```

---

## 7. Gatekeeper verification checklist

Run before uploading to getahem.com:

- [ ] `codesign --verify --deep --strict` passes on `Ahem.app`
- [ ] `xcrun stapler validate Ahem.app` passes
- [ ] `spctl -a -vv -t execute Ahem.app` shows **accepted** and **Notarized Developer ID**
- [ ] DMG mounts and contains `Ahem.app` + `Applications` link
- [ ] Fresh install: copy to `/Applications`, launch, complete onboarding
- [ ] Microphone permission prompt appears with correct usage string
- [ ] Menu bar icon visible; no Dock icon (`LSUIElement`)

### Quarantine simulation (optional)

Simulates a browser download:

```bash
xattr -w com.apple.quarantine "0081;$(date +%s);Safari;com.apple.Safari" /Applications/Ahem.app
open /Applications/Ahem.app
```

After notarization + stapling, Gatekeeper should allow launch. Remove quarantine when done testing:

```bash
xattr -dr com.apple.quarantine /Applications/Ahem.app
```

---

## 8. Troubleshooting

| Problem | Likely cause | Fix |
|---|---|---|
| `requires a development team` | `DEVELOPMENT_TEAM` not set | Select Team in Xcode Signing & Capabilities |
| No `Developer ID Application` in identity list | Certificate not installed | Download from developer.apple.com, install in Keychain |
| `spctl` rejected before notarization | Normal | Notarize and staple first |
| Notarization invalid | Unsigned binary, missing hardened runtime, or bad entitlements | Check `codesign` and Hardened Runtime |
| `notarytool` auth failed | Wrong Apple ID / app-specific password | Re-run `store-credentials` |
| DMG won't open on another Mac | App inside DMG not stapled | Staple the `.app` before creating DMG |
| Launch at Login fails after install | User must approve in System Settings → Login Items | Expected on macOS 13+ |

---

## 9. Release folder layout

```
dist/
  export/
    Ahem.app          # exported signed app
  Ahem.zip            # notarization submission (gitignored)
  Ahem-0.9.0-beta.dmg # final distributable (gitignored)
```

---

## 10. Quick reference (full pipeline)

```bash
# 1. Archive in Xcode → export to dist/export/Ahem.app
# 2. Verify signing
codesign --verify --deep --strict --verbose=2 dist/export/Ahem.app

# 3. Notarize
./Scripts/notarize.sh dist/export/Ahem.app

# 4. Create DMG
./Scripts/create_dmg.sh dist/export/Ahem.app 0.9.0-beta

# 5. Final check
spctl -a -vv -t execute dist/export/Ahem.app
```

Upload `dist/Ahem-0.9.0-beta.dmg` to getahem.com when all checks pass.
