#!/usr/bin/env bash
# Submit a signed Ahem build to Apple notarization and staple the ticket.
#
# Usage:
#   ./Scripts/notarize.sh /path/to/Ahem.app
#   ./Scripts/notarize.sh /path/to/Ahem.zip
#
# Prerequisites:
#   - Developer ID Application certificate installed
#   - App signed with hardened runtime
#   - notarytool credentials stored locally (see Docs/RELEASE_DISTRIBUTION.md)
#
# Do NOT commit Apple IDs, app-specific passwords, or API keys.

set -euo pipefail

SUBMIT_PATH="${1:-}"
PROFILE_NAME="${NOTARYTOOL_PROFILE:-AHEM_NOTARIZATION}"
APP_PATH=""

if [[ -z "$SUBMIT_PATH" ]]; then
  echo "Usage: $0 /path/to/Ahem.app|Ahem.zip" >&2
  exit 1
fi

if [[ ! -e "$SUBMIT_PATH" ]]; then
  echo "Error: path not found: $SUBMIT_PATH" >&2
  exit 1
fi

if [[ "$SUBMIT_PATH" == *.app ]]; then
  APP_PATH="$SUBMIT_PATH"
  ZIP_PATH="${SUBMIT_PATH%.app}.zip"
  echo "Creating submission zip: $ZIP_PATH"
  ditto -c -k --keepParent "$SUBMIT_PATH" "$ZIP_PATH"
  SUBMIT_PATH="$ZIP_PATH"
fi

echo "Submitting to Apple notarization using profile: $PROFILE_NAME"
xcrun notarytool submit "$SUBMIT_PATH" \
  --keychain-profile "$PROFILE_NAME" \
  --wait

if [[ -n "$APP_PATH" ]]; then
  echo "Stapling ticket to: $APP_PATH"
  xcrun stapler staple "$APP_PATH"
  xcrun stapler validate "$APP_PATH"
  echo "Notarization complete."
else
  echo "Submission complete. Staple manually:"
  echo "  xcrun stapler staple /path/to/Ahem.app"
  echo "  xcrun stapler validate /path/to/Ahem.app"
fi
