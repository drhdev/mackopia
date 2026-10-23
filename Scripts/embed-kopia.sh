#!/bin/bash
set -euo pipefail
"${SRCROOT}/Scripts/fetch-kopia.sh"
version=$(/usr/bin/plutil -extract version raw -o - "${SRCROOT}/Config/kopia-version.json")
source_dir="${SRCROOT}/Vendor/kopia/${version}"
helper_dir="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Helpers"
license_dir="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/Kopia"
/bin/mkdir -p "$helper_dir" "$license_dir"
/usr/bin/ditto "${source_dir}/kopia" "${helper_dir}/kopia"
/usr/bin/ditto "${source_dir}/LICENSE" "${license_dir}/LICENSE"
/usr/bin/ditto "${source_dir}/README.md" "${license_dir}/README.md"
if [[ "${CODE_SIGNING_ALLOWED:-NO}" == "YES" ]]; then
    identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
    if [[ "$identity" == "-" ]]; then
        /usr/bin/codesign --force --sign - --options runtime "${helper_dir}/kopia"
    else
        /usr/bin/codesign --force --sign "$identity" --options runtime --timestamp "${helper_dir}/kopia"
    fi
    /usr/bin/codesign --verify --strict "${helper_dir}/kopia"
fi
/usr/bin/python3 "${SRCROOT}/Scripts/embed-agent-plist.py" \
    --template "${SRCROOT}/Agent/LaunchAgent/Agent.plist" \
    --destination "${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Library/LaunchAgents" \
    --bundle-id "${PRODUCT_BUNDLE_IDENTIFIER}"
