#!/bin/sh
# CYDA-21 — pub.dev must receive the release number, not another one.
#
# `dart pub publish` sends the `version` from pubspec.yaml and never looks at the release tag.
# Nobody compares the two: the release can be called 0.8.0 and publish 0.7.2, green. With the
# number computed by the server, the two diverge BY CONSTRUCTION if it was not updated inside, not
# by oversight. And if that number has already shipped, pub.dev rejects the good release — the
# work is left half done, with the tag created and nothing published.
#
# POSIX and SDK-free on purpose: it runs as the first step, before Flutter is installed. A
# check that needs ten minutes of setup to say "the number is wrong" arrives
# too late to be useful.
#
# Fail-closed on everything: unreadable pubspec, missing version line, empty value. A doubt
# is not a permission.
set -eu

PUBSPEC="${PUBSPEC:-pubspec.yaml}"
TAG="${1:-${GITHUB_REF_NAME:-}}"

if [ -z "$TAG" ]; then
  echo "::error::no tag to check: pass it as an argument or set GITHUB_REF_NAME" >&2
  exit 1
fi

# This repository has no pre-release channel: pub.dev only receives final versions. A tag with a
# hyphen here is not a preview to publish elsewhere — it is a mistake, and it must be said now.
case "$TAG" in
  *-*)
    # Braces are required: with `$TAG»` sh reads the multibyte character as part of the variable
    # name, and the step dies with "unbound variable" instead of saying what is wrong.
    echo "::error::«${TAG}» is a pre-release tag, and this repository has no pre-release channel: only final versions go to pub.dev" >&2
    exit 1
    ;;
esac

if [ ! -r "$PUBSPEC" ]; then
  echo "::error::cannot read $PUBSPEC: unable to tell which number would be published" >&2
  exit 1
fi

# The top-level `version:` line, not any line containing that word: pubspec.yaml has other
# indented ones (the dependency constraints).
DECLARED="$(sed -n 's/^version:[[:space:]]*//p' "$PUBSPEC" | head -1 | tr -d '[:space:]')"
if [ -z "$DECLARED" ]; then
  echo "::error::$PUBSPEC declares no version: unable to tell which number would be published" >&2
  exit 1
fi

EXPECTED="${TAG#v}"
if [ "$EXPECTED" != "$DECLARED" ]; then
  echo "::error::$PUBSPEC says $DECLARED, the release says $EXPECTED: update the version before creating the tag" >&2
  exit 1
fi

echo "tag and pubspec aligned: $DECLARED"
