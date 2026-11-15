# Shared by the scripts (sourced).

readonly app=~/Applications/Tidemark.app
readonly identifier=io.github.tbgihu.tidemark
readonly support=~/Library/"Application Support"/Tidemark
readonly signing=$support/signing
readonly keychain=$signing/tidemark.keychain-db
readonly identity="Tidemark Local Signing"
readonly marker=tidemark:security                                 # Tidemark's Keychain items (SecretStore)
readonly stage=~/Library/Caches/Tidemark/update
readonly lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
readonly webdata=~/Library/WebKit/$identifier                      # web sign-ins' isolated data stores
# Every Keychain item Tidemark writes, one per way of signing in (a unit test keeps this in step with the providers).
readonly secret_items=(oauth-tokens admin-api-keys openai-chatgpt-tokens openai-admin-keys copilot-tokens cursor-sessions
  antigravity-cli xai-management-keys openrouter-api-keys warp-api-keys deepseek-api-keys kimi-code-keys
  moonshot-api-keys zai-api-keys minimax-api-keys ollama-api-keys opencode-api-keys elevenlabs-api-keys)

# One installer or updater at a time (shlock removes a lock whose process is gone).
lock() {
  mkdir -p $stage:h
  local tries=0
  until shlock -f $stage.lock -p $$; do
    (( ++tries > 1200 )) && { print -u2 "  another install or update is running"; exit 1 }
    sleep 0.1
  done
  trap 'rm -f $stage.lock' EXIT
}

# Waits up to 5 s for process <pid> to exit.
await_exit() {
  zmodload zsh/zselect                                            # a 50 ms wait without starting a process
  for _ in {1..100}; do kill -0 $1 2>/dev/null || break; zselect -t 5 || true; done
}

running() { pgrep -x -U $UID Tidemark >/dev/null }

# Quits a running Tidemark.
stop_app() {
  if pkill -TERM -x -U $UID Tidemark 2>/dev/null; then
    for _ in {1..50}; do running || break; sleep 0.1; done
  fi
}

# The commit the installed Tidemark was built from, without the "+" of local changes.
installed() {
  local commit
  commit=$(plutil -extract TidemarkCommit raw $app/Contents/Info.plist 2>/dev/null) || return 0
  print ${commit%+}
}

# Puts <Tidemark.app> in place of the installed one with two renames, so a half-copied app is never installed.
place() {
  [[ -x $1/Contents/MacOS/Tidemark ]] || { print -u2 "  no complete Tidemark.app at $1: nothing installed"; exit 1 }
  mkdir -p $app:h
  rm -rf $app.old
  [[ -d $app ]] && mv $app $app.old
  if ! mv $1 $app; then
    [[ -d $app.old ]] && mv $app.old $app                         # put the installed one back
    print -u2 "  could not move the new Tidemark.app into place: kept the installed one"
    exit 1
  fi
  rm -rf $app.old
  $lsregister -f $app                                             # never re-registers the login item
  print "  installed Tidemark $(plutil -extract CFBundleShortVersionString raw $app/Contents/Info.plist)"
}

# How this clone stands against its upstream, from the commits only it has (<ahead>) and only the upstream has
# (<behind>): current, ahead (a developer's own commits: nothing to update to), behind (a fast-forward updates it)
# or diverged (a rewritten history: only resetting the clone can update it, which is never done for you).
relation() {
  if (( $2 == 0 )); then
    (( $1 == 0 )) && print current || print ahead
  elif (( $1 == 0 )); then
    print behind
  else
    print diverged
  fi
}

# Whether <dir> is a Tidemark clone at its top: never a home folder, the root or a link, and never another project.
is_our_clone() {
  local dir=$1
  [[ -d $dir && ! -L $dir && $dir != $HOME && $dir != / ]] || return 1
  [[ $(git -C $dir rev-parse --show-toplevel 2>/dev/null) == $dir ]] || return 1
  [[ -f $dir/scripts/uninstall.sh
     && $(plutil -extract CFBundleIdentifier raw $dir/Support/Info.plist 2>/dev/null) == $identifier ]]
}

# Prints why removing clone <dir> would lose work of yours, one reason a line, and succeeds when there is any:
# changes not committed, commits not pushed, branches never pushed, stashes, or worktrees of its own.
clone_unsafe() {
  local dir=$1 reasons=() name upstream track
  [[ -n $(git -C $dir status --porcelain 2>/dev/null) ]] && reasons+=("    changes that aren't committed")
  git -C $dir for-each-ref --format='%(refname:short)|%(upstream)|%(upstream:track)' refs/heads |
    while IFS='|' read -r name upstream track; do
      if [[ -z $upstream ]]; then reasons+=("    branch $name, never pushed")
      elif [[ $track == *ahead* ]]; then reasons+=("    commits on $name that aren't pushed")
      fi
    done
  [[ -n $(git -C $dir stash list 2>/dev/null) ]] && reasons+=("    stashed changes")
  # Its own worktrees, other than the update's in the caches (removed before the clone).
  git -C $dir worktree list --porcelain 2>/dev/null | while read -r key path; do
    [[ $key == worktree && $path != $dir && $path != $stage:h/* && $path != $stage ]] && reasons+=("    a worktree at $path")
  done
  (( $#reasons )) || return 1
  print -l -- $reasons
}

# Moves <path> to the Trash, where it can still be recovered; deletes it where there is no Trash tool.
trash_or_rm() {
  [[ -x /usr/bin/trash ]] && /usr/bin/trash $1 2>/dev/null && return 0
  rm -rf $1
}
