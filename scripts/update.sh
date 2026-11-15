#!/bin/zsh
# Tidemark's updates. The install is this git clone; an update brings it up to its upstream and rebuilds.
#
#   update.sh            `make update`: prepare, then install right away and reopen Tidemark.
#   update.sh check      fetch and compare; exits 10 when something newer than the installed Tidemark exists, 3
#                        offline, 11 when the clone's history has diverged from its upstream. Nothing is built.
#   update.sh prepare    fetch, and when the upstream (or this clone) is ahead of the installed Tidemark, build that
#                        commit into the stage. Nothing installed changes. Tidemark runs this every 2 hours unless
#                        its updates are set to Manually. Exits 3 when offline, 11 when diverged (nothing built).
#   update.sh install [--after <pid>]
#                        wait for <pid> (Tidemark) to exit, prepare again unless the stage was readied in the last
#                        10 minutes, fast-forward the clone, put the new Tidemark.app in place and open it. If
#                        anything fails the installed Tidemark stays as it was and is opened again.
#
# Never moves the clone backwards or across local commits, never resets it, and never prompts, since there may be no
# terminal. A clone whose history diverged from its upstream (after a history rewrite) is reported as such, never as
# up to date: `git fetch origin && git reset --hard origin/main && make install` in the clone brings it back.
set -euo pipefail
cd "${0:A:h}/.."
source scripts/lib.sh
git rev-parse --git-dir >/dev/null 2>&1 || { print "  not a git clone, so there is nothing to update from"; exit 0 }
export GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=15"

# Fetches, then sets `target` to the commit to install: the upstream, or this clone if it is ahead; and `state` to
# how the clone stands against its upstream (`relation`).
latest() {
  mkdir -p $stage
  touch $stage/checked
  git fetch --quiet 2>/dev/null || { offline=1; print "  could not fetch, so using the commits already here" }
  local head=$(git rev-parse --short=12 HEAD)
  target=$(git rev-parse --short=12 '@{upstream}' 2>/dev/null) || target=$head
  local counts=(${=$(git rev-list --left-right --count HEAD...@{upstream} 2>/dev/null)})
  state=$(relation ${counts[1]:-0} ${counts[2]:-0})
  git merge-base --is-ancestor $head $target 2>/dev/null || target=$head      # local commits: build those
}

# Says, and exits 11, when the clone can't be updated without resetting it.
diverged() {
  [[ $state == diverged ]] || return 0
  print "  diverged  this copy's history differs from the source: run"
  print "            git fetch origin && git reset --hard origin/main && make install"
  exit 11
}

# Reports whether something newer than the installed Tidemark exists. Fetches and compares only.
check() {
  latest
  diverged
  if [[ $target == $(installed) ]]; then print "  up to date ($target)"; return 0; fi
  print "  available $target"
  return 10
}

prepare() {
  local target state
  latest
  diverged
  rm -rf $stage/src                                               # left by a build that failed or was interrupted

  if [[ $target == $(installed) ]]; then
    rm -rf $stage/Tidemark.app $stage/commit
    print "  up to date ($target)"
    return
  fi
  if [[ -d $stage/Tidemark.app && $(cat $stage/commit 2>/dev/null) == $target ]]; then
    touch $stage/commit                                           # confirmed the latest just now
    print "  ready     $target"
    return
  fi

  print "  building  $target"
  rm -rf $stage/Tidemark.app $stage/commit
  git worktree prune                                              # forget one that was deleted, by an uninstall too
  git worktree add --quiet --detach $stage/src $target
  if ! (repo=$PWD; cd $stage/src && TIDEMARK_SOURCE=$repo scripts/build.sh >/dev/null); then
    git worktree remove --force $stage/src
    print "  could not build $target"
    return 1
  fi
  mv $stage/src/build/Tidemark.app $stage/Tidemark.app
  $lsregister -u $stage/Tidemark.app 2>/dev/null || true          # only the installed app is Tidemark to macOS
  git worktree remove --force $stage/src
  print $target > $stage/commit
  print "  ready     $target"
}

install() {
  if [[ ${1-} == --after ]]; then
    await_exit $2
    shift 2
  fi
  # Whatever happens, Tidemark (the new one, or the old one if anything failed) runs again afterwards.
  trap 'rm -f $stage.lock; [[ -d $app ]] && open $app' EXIT
  # Install the latest commit, or what is staged when offline. A stage that a prepare built or confirmed in the
  # last 10 minutes counts as the latest, unlike one that a later `check` merely fetched past.
  offline=0
  local fresh=($stage/commit(Nmm-10))
  if ! [[ -d $stage/Tidemark.app && -n $fresh ]]; then prepare || true; fi
  [[ -d $stage/Tidemark.app ]] || return 0
  local target=$(<$stage/commit)
  if [[ $target == $(installed) ]]; then
    print "  up to date ($target)"
  elif ! git merge --ff-only --quiet $target 2>/dev/null; then
    print "  could not fast-forward to $target, so kept $(installed)"
  else
    stop_app
    (place $stage/Tidemark.app) || true                           # puts the installed one back if it can't
  fi
  rm -rf $stage/Tidemark.app $stage/commit                        # else every launch would try it again
}

case ${1-} in
  prepare) lock; offline=0; prepare; exit $(( offline ? 3 : 0 )) ;;           # 3: could not reach the remote
  check) lock; offline=0; check && rc=0 || rc=$?; (( offline )) && exit 3; exit $rc ;;   # 10: one is available, 11: diverged
  install) shift; lock; install "$@" ;;
  "")
    lock
    offline=0
    prepare
    [[ -d $stage/Tidemark.app ]] || exit 0
    install
    ;;
  *) print -u2 "usage: update.sh [check | prepare | install [--after <pid>]]"; exit 64 ;;
esac
