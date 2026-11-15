#!/bin/zsh
# Builds build/Tidemark.app from this checkout.
#   SIGN_ID   codesign identity. Default: Tidemark's own (scripts/identity.sh) if it exists, else ad-hoc.
#   DEBUG=1   a debug build, with sample data (`--sample`), `--selftest` and `--snapshot`; never install one.
#   TIDEMARK_SOURCE  the clone updates come from. Default: this checkout (update.sh sets it when building in a
#             worktree).
set -euo pipefail
cd "${0:A:h}/.."
source scripts/lib.sh

readonly built=build/Tidemark.app
readonly plist=$built/Contents/Info.plist
readonly minimum=27.0

# Use Tidemark's own identity (identity.sh) if it exists. Its keychain is unlocked with the password file, so
# codesign never prompts. Otherwise sign ad-hoc.
sign_args=()
if [[ -z ${SIGN_ID-} && -f $signing/password ]] \
   && security unlock-keychain -p "$(<$signing/password)" $keychain 2>/dev/null; then
  SIGN_ID=$identity
  sign_args=(--keychain $keychain)
fi
readonly sign_id=${SIGN_ID:--}
# Updates compare against the commit, with "+" for local changes. A folder that isn't a git clone (a downloaded
# ZIP) still builds, just without updates.
if git rev-parse --git-dir >/dev/null 2>&1 && git rev-parse HEAD >/dev/null 2>&1; then
  # The build number is the commit count, which a shallow clone gets wrong (1).
  [[ $(git rev-parse --is-shallow-repository) == false ]] \
    || { print -u2 "  this clone is shallow: \`git fetch --unshallow\` fetches its history, then build again"; exit 1 }
  readonly commit=$(git rev-parse --short=12 HEAD)$(git diff --quiet HEAD 2>/dev/null || print +)
  readonly version=$(git rev-list --count HEAD)
  readonly origin=${TIDEMARK_SOURCE:-$PWD}
else
  readonly commit=source version=1 origin=
fi

print "  building  Tidemark $(plutil -extract CFBundleShortVersionString raw Support/Info.plist)${DEBUG:+ (debug)}"

flags=(-Osize -wmo)
[[ ${DEBUG-} == 1 ]] && flags=(-Onone -g -D DEBUG)

rm -rf build
mkdir -p $built/Contents/{MacOS,Resources}
swiftc Sources/{Core,App}/*.swift Sources/Providers/**/*.swift -o $built/Contents/MacOS/Tidemark -module-name Tidemark \
  $flags -swift-version 6 -target "$(uname -m)-apple-macos$minimum"
[[ ${DEBUG-} == 1 ]] || strip -x $built/Contents/MacOS/Tidemark   # local symbols aren't needed at run time
rm -rf $built/Contents/MacOS/*.dSYM(N)

cp Support/Info.plist $plist
plutil -replace CFBundleVersion -string "$version" $plist
plutil -replace LSMinimumSystemVersion -string "$minimum" $plist
plutil -insert TidemarkCommit -string "$commit" $plist
[[ -n $origin ]] && plutil -insert TidemarkSource -string "$origin" $plist
# A fork with a GitHub OAuth App of its own (Copilot sign-in) builds with TIDEMARK_GITHUB_CLIENT_ID set.
[[ -n ${TIDEMARK_GITHUB_CLIENT_ID-} ]] && plutil -insert TidemarkGitHubClientID -string "$TIDEMARK_GITHUB_CLIENT_ID" $plist
iconset=$(mktemp -d)/AppIcon.iconset
$built/Contents/MacOS/Tidemark --icon $iconset
iconutil -c icns $iconset -o $built/Contents/Resources/AppIcon.icns
rm -rf $iconset:h

codesign --force --sign "$sign_id" $sign_args --options runtime --timestamp=none $built 2>/dev/null \
  || { print -u2 "  signing with \"$sign_id\" failed: \`make identity\` recreates Tidemark's identity"; exit 1 }
