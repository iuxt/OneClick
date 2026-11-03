#!/bin/bash
set -euo pipefail

vendor="$SRCROOT/Vendor/7zip"
helpers="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
licenses="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/7zip"
mkdir -p "$helpers" "$licenses"
install -m 755 "$vendor/7zz" "$helpers/7zz"
for file in License.txt COPYING.LESSER README.md 7zip-26.05-src.tar.xz; do
    install -m 644 "$vendor/$file" "$licenses/$file"
done
if [[ "${CODE_SIGNING_ALLOWED:-NO}" == YES ]]; then
    identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
    codesign --force --options runtime --timestamp=none --sign "$identity" \
        --entitlements "$vendor/7zz.entitlements" "$helpers/7zz"
fi
