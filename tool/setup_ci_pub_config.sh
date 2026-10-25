#!/bin/sh
# Pub's Linux token store follows XDG_CONFIG_HOME, independently of PUB_CACHE.
# Keep each job away from persistent runner credentials without changing HOME.
set -eu
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${GITHUB_ENV:?GITHUB_ENV is required}"
umask 077
pub_config_dir="$(mktemp -d "${RUNNER_TEMP}/cyi-pub-config.XXXXXXXX")"
printf 'XDG_CONFIG_HOME=%s\n' "$pub_config_dir" >> "$GITHUB_ENV"
