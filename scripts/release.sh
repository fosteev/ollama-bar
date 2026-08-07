#!/usr/bin/env bash
#
# Cuts a release: bumps the version in Project.swift, commits, tags and pushes.
#
# The tag is the only thing that triggers a build, and the workflow refuses a tag whose version
# disagrees with Project.swift. So the two move together — here — or not at all.
#
# Run: scripts/release.sh 0.2.0

set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "usage: scripts/release.sh 1.2.3" >&2
    exit 1
fi

TAG="v$VERSION"

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "$TAG already exists — releases are not reissued under the same number" >&2
    exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
    echo "the working tree is dirty; commit or stash first" >&2
    exit 1
fi

CURRENT=$(sed -n 's/.*"MARKETING_VERSION": "\([^"]*\)".*/\1/p' Project.swift)
BUILD=$(sed -n 's/.*"CURRENT_PROJECT_VERSION": "\([^"]*\)".*/\1/p' Project.swift)

# Usually this bumps the version. Not always: the first release of a version the project already
# declares has nothing to bump, and the tag it does not have yet is the whole point. Reissuing is
# still refused above — that check is on the tag, which is the thing people actually download.
if [ "$CURRENT" = "$VERSION" ]; then
    echo "==> $VERSION (build $BUILD), already in Project.swift — tagging as is"
else
    # The build number only ever goes up. Nothing reads it yet, but Sparkle will, and it is the one
    # number you cannot fix after the fact — an update that appears to go backwards is not offered.
    sed -i '' -E \
        -e "s/(\"MARKETING_VERSION\": \")[^\"]*/\1$VERSION/" \
        -e "s/(\"CURRENT_PROJECT_VERSION\": \")[^\"]*/\1$((BUILD + 1))/" \
        Project.swift

    echo "==> $CURRENT -> $VERSION (build $BUILD -> $((BUILD + 1)))"

    git add Project.swift
    git commit -q -m "Release $TAG"
fi

git tag -a "$TAG" -m "$TAG"

echo "==> pushing"
git push -q origin HEAD
git push -q origin "$TAG"

echo "==> done; the release workflow takes it from here"
echo "    gh run watch"
