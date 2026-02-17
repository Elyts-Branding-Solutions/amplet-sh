#!/bin/sh
# Build, tag, and publish a release (Linux + macOS binaries).
# Usage: ./release.sh [VERSION]
#   No arg: auto-increment patch (v1.0.0 -> v1.0.1)
#   patch | minor | major: increment that part
#   1.0.0 or v1.0.0: use this version
# Requires: gh (GitHub CLI), git, go

set -e
REPO="Elyts-Branding-Solutions/amplet-sh"

if ! command -v gh >/dev/null 2>&1; then
  echo "Need GitHub CLI (gh). Install: https://cli.github.com/"
  exit 1
fi

# Resolve next or given version
next_version() {
  bump="$1"
  last_tag=$(git describe --tags --abbrev=0 2>/dev/null || true)
  if [ -z "$last_tag" ]; then
    echo "v1.0.0"
    return
  fi
  ver=$(echo "$last_tag" | sed 's/^v//')
  major=$(echo "$ver" | cut -d. -f1)
  minor=$(echo "$ver" | cut -d. -f2)
  patch=$(echo "$ver" | cut -d. -f3)
  case "$bump" in
    major) major=$((major + 1)); minor=0; patch=0 ;;
    minor) minor=$((minor + 1)); patch=0 ;;
    patch|*) patch=$((patch + 1)) ;;
  esac
  echo "v${major}.${minor}.${patch}"
}

VERSION="${1:-patch}"
case "$VERSION" in
  patch|minor|major)
    TAG=$(next_version "$VERSION")
    ;;
  v*)
    TAG="$VERSION"
    ;;
  *)
    TAG="v$VERSION"
    ;;
esac

echo "==> Building binaries"
GOOS=linux GOARCH=amd64 go build -o amplet-linux-amd64 .
GOOS=darwin GOARCH=amd64 go build -o amplet-darwin-amd64 .
GOOS=darwin GOARCH=arm64 go build -o amplet-darwin-arm64 .

echo "==> Tagging $TAG"
git tag -a "$TAG" -m "Release $TAG"

echo "==> Pushing tag and creating release"
git push origin "$TAG"
gh release create "$TAG" \
  --repo "$REPO" \
  --title "Release $TAG" \
  --notes "Install: curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh | sh" \
  amplet-linux-amd64 amplet-darwin-amd64 amplet-darwin-arm64

echo "==> Done. Install: curl -sSL https://raw.githubusercontent.com/$REPO/main/install.sh | sh"
