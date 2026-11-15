#!/bin/zsh
# Installs build/Tidemark.app as ~/Applications/Tidemark.app, quitting the running one first, and opens it.
# The app is replaced in place (same path, bundle identifier and signing identity), so its login item and
# notification permission carry over: nothing is registered again, and nothing asks for Keychain access.
set -euo pipefail
cd "${0:A:h}/.."
source scripts/lib.sh

lock
first=true
[[ -d $app ]] && first=false
stop_app
place build/Tidemark.app
rm -rf $stage/Tidemark.app $stage/commit                          # a prepared update this build supersedes
if $first; then
  print "  note      Tidemark opens at login: turn it off in its settings"
fi
open $app
