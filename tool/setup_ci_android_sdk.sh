#!/bin/sh
# setup-android extracts and renames tools without a cross-job lock.
# A private root prevents concurrent matrix jobs from replacing in-use tools.
set -eu
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${GITHUB_ENV:?GITHUB_ENV is required}"
umask 077
android_sdk_dir="$(mktemp -d "${RUNNER_TEMP}/cyi-android-sdk.XXXXXXXX")"
printf 'ANDROID_HOME=%s\nANDROID_SDK_ROOT=%s\n' "$android_sdk_dir" "$android_sdk_dir" >> "$GITHUB_ENV"
