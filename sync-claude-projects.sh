#!/usr/bin/env bash
  # sync-claude-projects - Shares selected folders of 'user' with 'claude-code'.
  #
  # Every folder listed in /etc/claude-projects.conf is bind-mounted into a
  # root-owned tree that mirrors its path under /home/user:
  #     /home/user/server/wordpress -> /var/lib/claude-code/user/server/wordpress
  # and claude-code gets one symlink per top-level folder in its home:
  #     /home/claude-code/user-server -> /var/lib/claude-code/user/server
  # The mount points live outside the claude-code home on purpose: claude-code
  # can rename anything in its own home, so a mount point there could be swapped
  # for a symlink and make root mount a folder over a system path at boot.
  #
  # The script also sets ACLs on the shared folders and updates the folder lists
  # in /home/claude-code/.claude/settings.json (all other keys are kept).
  #
  # Usage:
  #   sudo sync-claude-projects           # Dry run: show what would change
  #   sudo sync-claude-projects --apply   # Apply the changes
  #
  # Config (/etc/claude-projects.conf), one entry per line, '#' starts a comment line:
  #   rw   /home/user/server/wordpress
  #   ro   /home/user/Drive/VENDING
  #   deny /home/user/server/wordpress/crt
  set -euo pipefail
  umask 022

  CONF=/etc/claude-projects.conf
  OWNER=user
  AGENT=claude-code
  SRC_ROOT=/home/$OWNER
  SHARE=/var/lib/claude-code/$OWNER
  AGENT_HOME=/home/$AGENT
  PREFIX=user-
  SETTINGS=$AGENT_HOME/.claude/settings.json
  FSTAB=/etc/fstab
  BEGIN='# BEGIN claude-projects (managed by sync-claude-projects)'
  END='# END claude-projects'
  # Always in sandbox.filesystem.denyRead of claude-code
  STATIC_DENY_READ=("$SRC_ROOT" "$AGENT_HOME/.claude/.credentials.json" "$SHARE/**/.env")
  # Always in permissions.deny of claude-code (added if missing, never removed)
  STATIC_DENY_RULES=("Read(~/.claude/.credentials.json)")

  die()  { echo "sync-claude-projects: $*" >&2; exit 1; }
  warn() { echo "Warning: $*" >&2; }
  run()  { if ((APPLY)); then "$@"; else printf '[dry-run]'; printf ' %q' "$@"; echo; fi; }
  as_agent() { runuser -u "$AGENT" -- "$@"; }
  esc()   { local s=${1//\\/\\134}; s=${s// /\\040}; printf '%s' "${s//$'\t'/\\011}"; }
  unesc() { local s=${1//\\040/ }; s=${s//\\011/$'\t'}; printf '%s' "${s//\\134/\\}"; }
  has()   { local x=$1 i; shift; for i in "$@"; do [[ $i == "$x" ]] && return 0; done; return 1; }
  json_arr() { if (($#)); then printf '%s\n' "$@" | jq -R . | jq -s .; else echo '[]'; fi; }
  rel_of()    { printf '%s' "${1#"$SRC_ROOT/"}"; }
  target_of() { printf '%s' "$SHARE/$(rel_of "$1")"; }
  top_of()    { local r; r=$(rel_of "$1"); printf '%s' "${r%%/*}"; }

  APPLY=0
  case ${1:-} in
    "") ;;
    --apply) APPLY=1 ;;
    *) echo "Usage: sudo sync-claude-projects [--apply]" >&2; exit 1 ;;
  esac

  [[ $EUID -eq 0 ]] || die "Must be run with sudo"
  for c in jq setfacl findmnt mountpoint realpath runuser flock; do
    command -v "$c" >/dev/null || die "Missing '$c'"
  done
  [[ -f $CONF ]] || die "Missing $CONF"
  id "$AGENT" >/dev/null 2>&1 || die "User $AGENT does not exist"
  exec 9>/run/lock/sync-claude-projects.lock
  flock -n 9 || die "Another run is already in progress"

  # --- 1. Read and validate the config ---
  RW=() RO=() DENY=()
  n=0
  while IFS= read -r line || [[ -n $line ]]; do
    n=$((n + 1))
    [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
    read -r mode src <<<"$line"
    [[ -n ${src:-} ]] || die "Line $n: Missing path"
    [[ $src == "$SRC_ROOT"/* ]] || die "Line $n: Path must be under $SRC_ROOT/: $src"
    [[ $src != */ && $src != *//* && /$src/ != */../* && /$src/ != */./* ]] \
      || die "Line $n: Path must be normalized (no trailing '/', '//', '.' or '..'): $src"
    case $mode in
      rw|ro)
        if [[ ! -d $src ]]; then warn "Skipped, no such folder: $src"; continue; fi
        [[ $(realpath -e -- "$src") == "$src" ]] || die "Line $n: Path goes through a symlink: $src"
        if [[ $mode == rw ]]; then RW+=("$src"); else RO+=("$src"); fi ;;
      deny) DENY+=("$src") ;;
      *) die "Line $n: Unknown mode '$mode' (expected rw, ro or deny)" ;;
    esac
  done < "$CONF"

  SHARED=("${RW[@]}" "${RO[@]}")
  declare -A seen=()
  for a in "${SHARED[@]}"; do
    [[ -z ${seen[$a]:-} ]] || die "Duplicate entry: $a"
    seen[$a]=1
    for b in "${SHARED[@]}"; do
      if [[ $b == "$a"/* ]]; then die "Nested entries are not allowed: $b is inside $a"; fi
    done
  done

  DENY_OK=() DENY_T=()
  for p in "${DENY[@]}"; do
    inside=0
    for s in "${SHARED[@]}"; do if [[ $p == "$s"/* ]]; then inside=1; fi; done
    if ((inside)); then DENY_OK+=("$p"); DENY_T+=("$(target_of "$p")")
    else warn "Deny path is not inside a shared folder, ignored: $p"; fi
  done

  ALL_T=() RW_T=() LINES=() TOPS=()
  for s in "${SHARED[@]}"; do
    t=$(target_of "$s"); ALL_T+=("$t")
    if has "$s" "${RW[@]}"; then RW_T+=("$t"); opts=bind,nofail; else opts=bind,ro,nofail; fi
    LINES+=("$(esc "$s") $(esc "$t") none $opts 0 0")
    top=$(top_of "$s")
    has "$top" "${TOPS[@]}" || TOPS+=("$top")
  done

  # --- 2. Entries removed or changed since the last run ---
  prune_up() {   # Remove empty folders from $1 up to (not including) $SHARE
    local d=$1
    while [[ $d == "$SHARE"/* ]]; do
      if [[ -d $d && ! -L $d ]] && ! mountpoint -q "$d" && [[ -z $(ls -A "$d") ]]; then
        run rmdir "$d"
      else
        break
      fi
      d=${d%/*}
    done
  }
  mapfile -t OLD < <(awk -v b="$BEGIN" -v e="$END" '$0==b{f=1;next} $0==e{f=0} f && NF && $1 !~ /^#/' "$FSTAB")
  for line in "${OLD[@]}"; do
    if has "$line" "${LINES[@]}"; then continue; fi
    read -r osrc ot _ <<<"$line"; osrc=$(unesc "$osrc"); ot=$(unesc "$ot")
    [[ $ot == "$SHARE"/* ]] || die "Unexpected mount point in the managed fstab block: $ot"
    if mountpoint -q "$ot"; then run umount "$ot"; fi
    if ! has "$osrc" "${SHARED[@]}" && [[ -d $osrc ]]; then
      run setfacl -R -P -x "u:$AGENT" "$osrc" || true
      run find "$osrc" -type d -exec setfacl -x "d:u:$AGENT" {} + || true
    fi
    if ! has "$ot" "${ALL_T[@]}"; then prune_up "$ot"; fi
  done

  # --- 3. Mount points (root-owned tree) and fstab ---
  run install -d -o root -g root -m 755 "${SHARE%/*}" "$SHARE"
  for t in "${ALL_T[@]}"; do
    if [[ ! -d $t ]]; then run install -d -o root -g root -m 755 "$t"; fi
  done

  new=$(mktemp); newjson=$(mktemp); trap 'rm -f "$new" "$newjson"' EXIT
  awk -v b="$BEGIN" -v e="$END" '$0==b{f=1;next} $0==e{f=0;next} !f' "$FSTAB" > "$new"
  { echo "$BEGIN"; if ((${#LINES[@]})); then printf '%s\n' "${LINES[@]}"; fi; echo "$END"; } >> "$new"
  if cmp -s "$FSTAB" "$new"; then
    echo "fstab: No changes"
  else
    diff -u "$FSTAB" "$new" || true
    if ((APPLY)); then
      findmnt --verify --tab-file "$new" || die "The new fstab failed verification, nothing was written"
      cp -a "$FSTAB" "$FSTAB.bak.$(date +%F-%H%M%S)"
      cat "$new" > "$FSTAB"
    fi
  fi
  run systemctl daemon-reload
  run mount -a

  # --- 4. ACLs (deny last, so it wins over the recursive grants) ---
  for s in "${RW[@]}"; do
    run setfacl -R -P -m "u:$AGENT:rwX" "$s"
    run find "$s" -type d -exec setfacl -d -m "u:$AGENT:rwX,u:$OWNER:rwX" {} +
  done
  for s in "${RO[@]}"; do
    run setfacl -R -P -m "u:$AGENT:rX" "$s"
    run find "$s" -type d -exec setfacl -d -m "u:$AGENT:rX" {} +
  done
  for p in "${DENY_OK[@]}"; do
    if [[ ! -e $p ]]; then warn "Deny path does not exist (yet): $p"; continue; fi
    run setfacl -R -P -m "u:$AGENT:---" "$p"
    if [[ -d $p ]]; then run find "$p" -type d -exec setfacl -d -m "u:$AGENT:---" {} +; fi
  done

  # --- 5. Symlinks in the claude-code home (created as claude-code) ---
  for top in "${TOPS[@]}"; do
    link=$AGENT_HOME/$PREFIX$top dest=$SHARE/$top
    if [[ -L $link ]]; then
      [[ $(readlink "$link") == "$dest" ]] && continue
      run as_agent ln -sfn -- "$dest" "$link"
    elif [[ -e $link ]]; then
      warn "$link exists and is not a symlink, left untouched"
    else
      run as_agent ln -s -- "$dest" "$link"
    fi
  done
  for link in "$AGENT_HOME/$PREFIX"*; do
    [[ -L $link ]] || continue
    dest=$(readlink "$link")
    [[ $dest == "$SHARE"/* ]] || continue
    if ! has "${dest#"$SHARE/"}" "${TOPS[@]}"; then run as_agent rm -- "$link"; fi
  done

  # --- 6. settings.json of claude-code (read and written as claude-code, never as root) ---
  cur=''
  if as_agent test -e "$SETTINGS"; then
    cur=$(as_agent cat -- "$SETTINGS") || die "Cannot read $SETTINGS"
  fi
  [[ -n ${cur//[[:space:]]/} ]] || cur='{}'
  jq empty <<<"$cur" 2>/dev/null || die "$SETTINGS is not valid JSON, fix it first"
  jq --argjson dirs  "$(json_arr "${ALL_T[@]}")" \
     --argjson rw    "$(json_arr "${RW_T[@]}")" \
     --argjson dread "$(json_arr "${STATIC_DENY_READ[@]}" "${DENY_T[@]}")" \
     --argjson rules "$(json_arr "${STATIC_DENY_RULES[@]}")" '
    .permissions.additionalDirectories = $dirs
    | .sandbox.filesystem.allowWrite = $rw
    | .sandbox.filesystem.denyRead = $dread
    | .permissions.deny = reduce $rules[] as $r ((.permissions.deny // []);
        if any(.[]; . == $r) then . else . + [$r] end)' <<<"$cur" > "$newjson"

  if diff -u <(jq . <<<"$cur") "$newjson"; then
    echo "settings.json: No changes"
  elif ((APPLY)); then
    if as_agent test -e "$SETTINGS"; then
      as_agent cp -p -- "$SETTINGS" "$SETTINGS.bak.$(date +%F-%H%M%S)"
    else
      as_agent mkdir -p -- "${SETTINGS%/*}"
    fi
    as_agent tee -- "$SETTINGS" < "$newjson" >/dev/null
  fi
  ((APPLY)) || echo "This was a dry run. To apply: sudo sync-claude-projects --apply"

