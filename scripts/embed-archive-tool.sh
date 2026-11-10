#!/bin/bash
set -euo pipefail

vendor="$SRCROOT/Vendor/7zip"
pigz_vendor="$SRCROOT/Vendor/pigz"
helpers="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
licenses="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/7zip"
pigz_licenses="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/pigz"
mkdir -p "$helpers" "$licenses" "$pigz_licenses"
install -m 755 "$vendor/7zz" "$helpers/7zz"
arch_flags=()
for arch in ${ARCHS:-$(uname -m)}; do
    arch_flags+=(-arch "$arch")
done
xcrun --sdk macosx clang -O3 -DNOZOPFLI "${arch_flags[@]}" \
    -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" \
    "$pigz_vendor/pigz.c" "$pigz_vendor/yarn.c" "$pigz_vendor/try.c" \
    -lz -lpthread -o "$helpers/pigz"
for file in License.txt COPYING.LESSER README.md 7zip-26.06-src.tar.xz 7z.sfx; do
    install -m 644 "$vendor/$file" "$licenses/$file"
done
for file in LICENSE.txt README.md; do
    install -m 644 "$pigz_vendor/$file" "$pigz_licenses/$file"
done
if [[ "${CODE_SIGNING_ALLOWED:-NO}" == YES ]]; then
    identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
    for helper in 7zz pigz; do
        codesign --force --options runtime --timestamp=none --sign "$identity" \
            --entitlements "$vendor/7zz.entitlements" "$helpers/$helper"
    done
fi
