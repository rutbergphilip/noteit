#!/usr/bin/env bash
# Prepares a release: stamps the Unreleased CHANGELOG section with the version and today's date,
# commits "chore: release x.y.z" and creates the annotated tag vx.y.z. Nothing is pushed.
# Pre-releases (x.y.z-beta.1) only get a tag; their notes come from Unreleased, which keeps
# collecting changes until the final release.
#   ./scripts/release.sh 1.2.0
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <x.y.z[-prerelease]>" >&2
    exit 2
fi
VERSION="$1"
TAG="v$VERSION"
SEMVER='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?$'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CHANGELOG="CHANGELOG.md"

die() { echo "error: $*" >&2; exit 1; }

[[ "$VERSION" =~ $SEMVER ]] || die "'$VERSION' isn't a semantic version (MAJOR.MINOR.PATCH[-prerelease])"

# Returns success if $1 > $2, by semver precedence.
version_gt() {
    local a_pre="" b_pre="" i x y
    [[ "$1" == *-* ]] && a_pre="${1#*-}"
    [[ "$2" == *-* ]] && b_pre="${2#*-}"
    local -a a b
    IFS=. read -r -a a <<< "${1%%-*}"
    IFS=. read -r -a b <<< "${2%%-*}"
    for i in 0 1 2; do
        (( 10#${a[i]} > 10#${b[i]} )) && return 0
        (( 10#${a[i]} < 10#${b[i]} )) && return 1
    done
    [[ -z "$a_pre" && -z "$b_pre" ]] && return 1
    [[ -z "$a_pre" ]] && return 0
    [[ -z "$b_pre" ]] && return 1
    IFS=. read -r -a a <<< "$a_pre"
    IFS=. read -r -a b <<< "$b_pre"
    for (( i = 0; i < ${#a[@]} && i < ${#b[@]}; i++ )); do
        x="${a[i]}" y="${b[i]}"
        [[ "$x" == "$y" ]] && continue
        if [[ "$x" =~ ^[0-9]+$ && "$y" =~ ^[0-9]+$ ]]; then
            (( 10#$x > 10#$y ))
            return
        fi
        [[ "$x" =~ ^[0-9]+$ ]] && return 1
        [[ "$y" =~ ^[0-9]+$ ]] && return 0
        [[ "$x" > "$y" ]]
        return
    done
    (( ${#a[@]} > ${#b[@]} ))
}

BRANCH="$(git symbolic-ref --quiet --short HEAD || true)"
[[ "$BRANCH" == "main" ]] || die "releases are cut from main (you're on '${BRANCH:-a detached HEAD}')"
[[ -z "$(git status --porcelain)" ]] || die "the working tree has uncommitted changes"

git fetch --quiet --tags origin main
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || die "main isn't in sync with origin/main; pull or push first"
! git rev-parse --quiet --verify "refs/tags/$TAG" > /dev/null || die "tag $TAG already exists"

LATEST=""
LATEST_FINAL=""
while read -r tag; do
    candidate="${tag#v}"
    [[ "$candidate" =~ $SEMVER ]] || continue
    if [[ -z "$LATEST" ]] || version_gt "$candidate" "$LATEST"; then
        LATEST="$candidate"
    fi
    if [[ "$candidate" != *-* ]] && { [[ -z "$LATEST_FINAL" ]] || version_gt "$candidate" "$LATEST_FINAL"; }; then
        LATEST_FINAL="$candidate"
    fi
done < <(git tag --list 'v*')
if [[ -n "$LATEST" ]]; then
    version_gt "$VERSION" "$LATEST" || die "$VERSION must be greater than the latest release, $LATEST"
fi

grep -qE '^## \[Unreleased\][[:space:]]*$' "$CHANGELOG" || die "$CHANGELOG has no '## [Unreleased]' section"
CHANGELOG="$ROOT/$CHANGELOG" ./scripts/release_notes.sh Unreleased > /dev/null \
    || die "add the changes for $VERSION under '## [Unreleased]' in CHANGELOG.md first"

if [[ "$VERSION" == *-* ]]; then
    git tag -a "$TAG" -m "NoteIt $VERSION"
    echo "Tagged pre-release $TAG on $(git rev-parse --short HEAD). CHANGELOG.md is unchanged: its"
    echo "Unreleased section becomes the release notes. Review it with 'git show $TAG', then publish it with:"
    echo
    echo "    git push origin $TAG"
    exit 0
fi

REPO_URL="https://github.com/rutbergphilip/noteit"
TODAY="$(date +%Y-%m-%d)"
if [[ -n "$LATEST_FINAL" ]]; then
    VERSION_LINK="$REPO_URL/compare/v$LATEST_FINAL...$TAG"
else
    VERSION_LINK="$REPO_URL/releases/tag/$TAG"
fi

awk -v version="$VERSION" -v today="$TODAY" -v unreleased_link="$REPO_URL/compare/$TAG...HEAD" \
    -v version_link="$VERSION_LINK" '
    /^## \[Unreleased\][[:space:]]*$/ && !stamped {
        print "## [Unreleased]"
        print ""
        print "## [" version "] - " today
        stamped = 1
        next
    }
    /^\[Unreleased\]: / {
        print "[Unreleased]: " unreleased_link
        print "[" version "]: " version_link
        linked = 1
        next
    }
    { print }
    END {
        if (!linked) {
            print ""
            print "[Unreleased]: " unreleased_link
            print "[" version "]: " version_link
        }
    }
' "$CHANGELOG" > "$CHANGELOG.tmp"
mv "$CHANGELOG.tmp" "$CHANGELOG"

git add "$CHANGELOG"
git commit --quiet -s -m "chore: release $VERSION"
git tag -a "$TAG" -m "NoteIt $VERSION"

echo "Committed 'chore: release $VERSION' and tagged $TAG."
echo "Review it with 'git show $TAG', then publish it with:"
echo
echo "    git push origin main $TAG"
