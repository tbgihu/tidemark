#!/bin/zsh
# Removes Tidemark from this Mac: the app and everything it stored (your accounts' Keychain items, settings, history,
# the signing identity, web sign-in sessions, privacy permissions, caches and logs), then this clone, to the Trash.
# Lists all of it and asks you to type `uninstall` first; --yes doesn't ask (for scripts). A clone that holds work
# that isn't on GitHub is kept, and says why. Each step reports `removed`, `kept` or `failed`; running it again once
# nothing is left does nothing.
set -euo pipefail
source "${0:A:h}/lib.sh"

yes=false remove_clone=
while (( $# )); do
  case $1 in
    --yes) yes=true ;;
    --remove-clone) remove_clone=${2-}; shift ;;                   # the last step, run from a copy (see below)
    *) print -u2 "usage: uninstall.sh [--yes]"; exit 64 ;;
  esac
  shift
done

say() { printf "  %-9s %s\n" $1 $2 }

# The last step: this runs from a copy outside the clone, so removing it can't pull the script from under itself.
if [[ -n $remove_clone ]]; then
  cd /
  if ! is_our_clone $remove_clone; then say failed "clone $remove_clone: not a Tidemark clone, left as it is"; exit 1; fi
  if trash_or_rm $remove_clone; then
    say removed "this clone, $remove_clone (to the Trash)"
    print "\n  Tidemark is removed. Your shell may still be in the removed folder: \`cd ~\`."
  else
    say failed "clone $remove_clone"; exit 1
  fi
  exit 0
fi

readonly clone=${0:A:h:h}
present() { [[ -e $1 ]] }
had_caches() { present $stage:h || present ~/Library/Caches/$identifier || present ~/Library/HTTPStorages/$identifier }

# What exists, and what this removes.
removes=()
present $app && removes+=("the app, $app, with its login item and notifications")
removes+=("your accounts' Keychain items")
present $support && removes+=("settings, usage history and cached costs")
present $signing && removes+=("the signing identity")
present $webdata && removes+=("web sign-in sessions")
removes+=("Tidemark's privacy permissions")
had_caches && removes+=("caches")
present ~/Library/Logs/Tidemark && removes+=("logs")
removing_clone=false unsafe=
if is_our_clone $clone; then
  if unsafe=$(clone_unsafe $clone); then :; else removing_clone=true; removes+=("this clone, $clone (to the Trash)"); fi
fi

print "Tidemark: uninstall"
for item in $removes; do say remove $item; done
if [[ -n $unsafe ]]; then
  say keep "this clone, $clone: it has work that isn't on GitHub"
  print -l -- ${(f)unsafe}
fi
print "  by hand   Tidemark's entry in System Settings › Notifications, if you want it gone"

if ! $yes; then
  [[ -t 0 ]] || { print -u2 "  uninstall asks for confirmation: run it in a terminal, or pass --yes"; exit 1 }
  print -n "\nType uninstall to remove all of this: "
  read -r answer
  [[ $answer == uninstall ]] || { print "  Nothing was removed."; exit 1 }
fi
print

# Taking the lock creates the caches folder: whether there were caches is known before.
caches=false
had_caches && caches=true
lock
stop_app
# Only the app can unregister its login item and clear its notifications; it reports each, and the Keychain items
# it removes. Should it stop early, everything else is still done below, and it says so rather than failing the run.
failed=false
if [[ -x $app/Contents/MacOS/Tidemark ]]; then
  code=0
  $app/Contents/MacOS/Tidemark --uninstall || code=$?
  if (( code == 1 )); then
    failed=true                                                   # a step it reported as failed, above
  elif (( code )); then
    say note "Tidemark's own clean-up stopped early (exit $code): the rest is done here"
  fi
  $lsregister -u $app 2>/dev/null || true
fi
remove() {                                                        # <what> <path>…: only what exists, and says so
  local what=$1; shift
  local paths=(${^~@}(N))
  (( $#paths )) || return 0
  rm -rf $paths && say removed $what || { say failed $what; failed=true }
}
remove "the app" $app $app.old

# If the app was already gone: Tidemark's own items (marked in their generic attribute), never another's.
ours() { security find-generic-password -s $identifier -a $1 2>/dev/null | grep -qF "\"gena\"<blob>=\"$marker\"" }
deleted=0
for item in $secret_items; do
  for name in $item "$item#"{1..64}; do
    ours $name || { [[ $name == $item ]] && continue || break }
    security delete-generic-password -s $identifier -a $name >/dev/null 2>&1 && (( ++deleted ))
  done
done
(( deleted )) && say removed "$deleted Keychain items left behind"
if [[ -f $keychain ]]; then
  security delete-keychain $keychain 2>/dev/null && say removed "the signing keychain" || { say failed "the signing keychain"; failed=true }
fi
remove "settings, history and the signing identity" $support
remove "web sign-in sessions" $webdata
defaults delete $identifier 2>/dev/null && say removed preferences || true
tccutil reset All $identifier >/dev/null 2>&1 && say removed "privacy permissions" || true
remove logs ~/Library/Logs/Tidemark
if $caches; then
  remove caches $stage:h ~/Library/Caches/$identifier ~/Library/HTTPStorages/$identifier "$HOME/Library/HTTPStorages/$identifier.*"
else
  rm -rf $stage:h                                                  # only the lock
fi
remove "saved window state" ~/Library/"Saved Application State"/$identifier.savedState
git -C $clone worktree prune 2>/dev/null || true                  # the update's worktree lived in the caches

if $failed; then
  print -u2 "\n  Some steps failed (above); run it again once they are resolved."
  exit 1
fi
if $removing_clone; then
  # Last, from a copy outside the clone: the script and its library are in the clone being removed.
  copy=$(mktemp -d)
  cp ${0:A} ${0:A:h}/lib.sh $copy/
  cd /
  exec zsh $copy/uninstall.sh --remove-clone $clone
fi
print "\n  Tidemark is removed.$([[ -n $unsafe ]] && print ' This clone is kept: push or remove its work, then delete it.')"
