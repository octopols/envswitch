#!/usr/bin/env zsh
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  envswitch — dynamic environment loader for zsh
#  Source this file from your .zshrc. That's it.
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# ── Config ────────────────────────────────────────────────────
export ENVSWITCH_DIR="${ENVSWITCH_DIR:-$HOME/.envs}"
export ENVSWITCH_EDITOR="${ENVSWITCH_EDITOR:-${EDITOR:-code}}"
export ENVSWITCH_PROTECT="${ENVSWITCH_PROTECT:-production:prod}"

# ── Internal state ────────────────────────────────────────────
typeset -a  _ENVSWITCH_LOADED_VARS
typeset -a  _ENVSWITCH_SHELL_SNAPSHOT
typeset -g  _ENVSWITCH_ACTIVE_ENV=""
typeset -g  _ENVSWITCH_AUTO_LOADED=""       # "auto" if loaded by hook
typeset -g  _ENVSWITCH_HAS_DIR_TAGS=false   # any env files have dir: tags?
typeset -g  _ENVSWITCH_CACHED_DIR=""        # last resolved directory
typeset -g  _ENVSWITCH_CACHED_BRANCH=""     # last resolved branch
typeset -g  _ENVSWITCH_CACHED_CONTEXT=""    # last resolved project prefix

# Dir map: parallel arrays built at startup/refresh
#   _ENVSWITCH_DM_DIRS[i]     = expanded dir path
#   _ENVSWITCH_DM_BRANCHES[i] = branch glob (or empty)
#   _ENVSWITCH_DM_ENVS[i]     = env file basename (without .env)
typeset -a _ENVSWITCH_DM_DIRS
typeset -a _ENVSWITCH_DM_BRANCHES
typeset -a _ENVSWITCH_DM_ENVS

# ── Helpers ───────────────────────────────────────────────────

_es_info()  { print -P "%F{cyan} ›%f $1" }
_es_ok()    { print -P "%F{green} ✓%f $1" }
_es_warn()  { print -P "%F{yellow} !%f $1" }
_es_err()   { print -P "%F{red} ✗%f $1" }

_es_varnames() {
  local file="$1"
  sed -E 's/^export[[:space:]]+//' "$file" \
    | grep -E '^[A-Za-z_][A-Za-z0-9_]*=' \
    | sed 's/=.*//'
}

_es_is_protected() {
  local name="$1"
  local IFS=':'
  for p in ${=ENVSWITCH_PROTECT}; do
    [[ "$name" == "$p" ]] && return 0
  done
  return 1
}

_es_mask() {
  local val="$1"
  if [[ -z "$val" ]]; then
    echo "(empty)"
  elif (( ${#val} <= 8 )); then
    echo "$val"
  else
    echo "${val:0:4}••••${val: -4}"
  fi
}

# Read a metadata tag from an env file header
# Usage: _es_read_tag <file> <tagname>  →  echoes value or empty
_es_read_tag() {
  local file="$1" tag="$2"
  sed -n "s/^#[[:space:]]*${tag}:[[:space:]]*//p" "$file" | head -1 | sed 's/[[:space:]]*$//'
}

# ── Dir/branch cache ─────────────────────────────────────────
# Scans all env files for # dir: and # branch: tags.
# Builds parallel arrays for fast lookup on cd.

_es_build_dirmap() {
  _ENVSWITCH_DM_DIRS=()
  _ENVSWITCH_DM_BRANCHES=()
  _ENVSWITCH_DM_ENVS=()
  _ENVSWITCH_HAS_DIR_TAGS=false

  [[ ! -d "$ENVSWITCH_DIR" ]] && return

  local envfiles=("$ENVSWITCH_DIR"/*.env(N))
  for f in "${envfiles[@]}"; do
    local dir_tag="$(_es_read_tag "$f" "dir")"
    [[ -z "$dir_tag" ]] && continue

    # Expand ~ in dir tag
    dir_tag="${dir_tag/#\~/$HOME}"
    # Remove trailing slash
    dir_tag="${dir_tag%/}"

    local branch_tag="$(_es_read_tag "$f" "branch")"
    local envname="$(basename "$f" .env)"

    _ENVSWITCH_DM_DIRS+=("$dir_tag")
    _ENVSWITCH_DM_BRANCHES+=("$branch_tag")
    _ENVSWITCH_DM_ENVS+=("$envname")
    _ENVSWITCH_HAS_DIR_TAGS=true
  done
}

# ── Context resolution ────────────────────────────────────────
# Given current PWD and optionally a branch, find the project
# context prefix (e.g., "growth" from "growth_staging").

# Get current git branch (cheap — reads .git/HEAD)
_es_current_branch() {
  git branch --show-current 2>/dev/null
}

# Resolve which env should auto-load for current dir+branch.
# Echoes the env name, or empty if no match.
_es_resolve_auto() {
  local current_dir="$PWD"
  local best_match=""
  local best_depth=0
  local needs_git=false

  # First pass: find dirs that match PWD, check if git is needed
  local -a candidate_indices=()
  for (( i=1; i<=${#_ENVSWITCH_DM_DIRS}; i++ )); do
    local d="${_ENVSWITCH_DM_DIRS[$i]}"
    # Prefix match: PWD starts with this dir
    if [[ "$current_dir" == "$d" || "$current_dir" == "$d/"* ]]; then
      candidate_indices+=($i)
      [[ -n "${_ENVSWITCH_DM_BRANCHES[$i]}" ]] && needs_git=true
    fi
  done

  (( ${#candidate_indices} == 0 )) && return

  # Get branch only if needed
  local branch=""
  if $needs_git; then
    branch="$(_es_current_branch)"
  fi

  # Second pass: find best (deepest dir) match
  for idx in "${candidate_indices[@]}"; do
    local d="${_ENVSWITCH_DM_DIRS[$idx]}"
    local b="${_ENVSWITCH_DM_BRANCHES[$idx]}"
    local depth="${#d}"

    # If this entry has a branch pattern, check it
    if [[ -n "$b" ]]; then
      # Glob match
      if [[ -z "$branch" ]] || [[ "$branch" != ${~b} ]]; then
        continue
      fi
    fi

    # Deepest directory wins
    if (( depth > best_depth )); then
      best_depth=$depth
      best_match="${_ENVSWITCH_DM_ENVS[$idx]}"
    fi
  done

  echo "$best_match"
}

# Extract the project prefix from an env name.
# "growth_staging" → "growth", "staging" → ""
_es_extract_prefix() {
  local name="$1"
  if [[ "$name" == *_* ]]; then
    echo "${name%_*}"
  fi
}

# Get current context prefix based on dir+branch
_es_current_context() {
  local current_dir="$PWD"
  local branch=""

  # Quick check: any dir matches at all?
  local has_match=false
  local check_git=false
  for (( i=1; i<=${#_ENVSWITCH_DM_DIRS}; i++ )); do
    local d="${_ENVSWITCH_DM_DIRS[$i]}"
    if [[ "$current_dir" == "$d" || "$current_dir" == "$d/"* ]]; then
      has_match=true
      [[ -n "${_ENVSWITCH_DM_BRANCHES[$i]}" ]] && check_git=true
    fi
  done

  $has_match || return

  # Get branch only if a matching dir has branch patterns
  if $check_git; then
    branch="$(_es_current_branch)"
  fi

  # Find deepest matching entry and extract its prefix
  local best_env=""
  local best_depth=0
  for (( i=1; i<=${#_ENVSWITCH_DM_DIRS}; i++ )); do
    local d="${_ENVSWITCH_DM_DIRS[$i]}"
    local b="${_ENVSWITCH_DM_BRANCHES[$i]}"
    local depth="${#d}"

    [[ "$current_dir" != "$d" && "$current_dir" != "$d/"* ]] && continue

    if [[ -n "$b" ]]; then
      [[ -z "$branch" || "$branch" != ${~b} ]] && continue
    fi

    if (( depth > best_depth )); then
      best_depth=$depth
      best_env="${_ENVSWITCH_DM_ENVS[$i]}"
    fi
  done

  [[ -n "$best_env" ]] && _es_extract_prefix "$best_env"
}

# ── Core commands ─────────────────────────────────────────────

# Load an env file by basename or full path
# Context-aware: if a project prefix is active, tries prefix_name first
loadenv() {
  local requested="$1"
  local file=""
  local resolved_name=""
  local show_context=false

  if [[ "$requested" == /* || "$requested" == ./* ]]; then
    # Absolute / relative path — use directly
    file="$requested"
  else
    # Context-aware resolution
    if $_ENVSWITCH_HAS_DIR_TAGS; then
      local ctx="$(_es_current_context)"
      if [[ -n "$ctx" ]]; then
        # Try prefix_name first
        local prefixed="${ctx}_${requested}"
        if [[ -f "${ENVSWITCH_DIR}/${prefixed}.env" ]]; then
          resolved_name="$prefixed"
          file="${ENVSWITCH_DIR}/${prefixed}.env"
          show_context=true
        fi
      fi
    fi

    # Fallback to plain name
    if [[ -z "$file" ]]; then
      resolved_name="$requested"
      file="${ENVSWITCH_DIR}/${requested}.env"

      # Show fallback message if we had context but prefixed didn't exist
      if [[ -n "${ctx:-}" ]]; then
        _es_info "Context: \e[1m${ctx}\e[0m (${ctx}_${requested} not found, using ${requested})"
      fi
    fi
  fi

  if [[ ! -f "$file" ]]; then
    _es_err "Env file not found: $file"
    return 1
  fi

  # Check protection on the RESOLVED name
  local check_name="${resolved_name:-$(basename "$file" .env)}"
  # Protection checks the full name AND the suffix
  # So "growth_production" is protected if "growth_production" or "production" is in the list
  local suffix="${check_name#*_}"
  if _es_is_protected "$check_name" || { [[ "$check_name" == *_* ]] && _es_is_protected "$suffix"; }; then
    print -Pn "%F{red} ! Load %B${check_name}%b env? (y/n):%f "
    local confirm
    read confirm
    [[ "$confirm" != "y" ]] && return
  fi

  # Unload previous env first
  unsetenv --quiet

  # Snapshot current shell vars
  _ENVSWITCH_SHELL_SNAPSHOT=("${(@f)$(env | sed 's/=.*//' | sort)}")

  # Collect variable names we're about to set
  _ENVSWITCH_LOADED_VARS=($(_es_varnames "$file"))

  # Source with auto-export
  set -a
  source "$file"
  set +a

  _ENVSWITCH_ACTIVE_ENV="$(basename "$file" .env)"
  _ENVSWITCH_AUTO_LOADED=""

  if $show_context; then
    local ctx="$(_es_extract_prefix "$_ENVSWITCH_ACTIVE_ENV")"
    _es_info "Context: \e[1m${ctx}\e[0m"
  fi

  _es_ok "Loaded \e[1m${_ENVSWITCH_ACTIVE_ENV}\e[0m  (${#_ENVSWITCH_LOADED_VARS[@]} vars)"
}

# Internal: load for auto-trigger (no protection prompt, sets auto flag)
_es_auto_load() {
  local envname="$1"
  local reason="$2"
  local file="${ENVSWITCH_DIR}/${envname}.env"

  [[ ! -f "$file" ]] && return 1

  # Don't reload if same env is already active
  [[ "$_ENVSWITCH_ACTIVE_ENV" == "$envname" ]] && return 0

  # Unload previous
  unsetenv --quiet

  _ENVSWITCH_SHELL_SNAPSHOT=("${(@f)$(env | sed 's/=.*//' | sort)}")
  _ENVSWITCH_LOADED_VARS=($(_es_varnames "$file"))

  set -a
  source "$file"
  set +a

  _ENVSWITCH_ACTIVE_ENV="$envname"
  _ENVSWITCH_AUTO_LOADED="auto"
  _es_ok "Auto-loaded \e[1m${envname}\e[0m  (${reason})"
}

# Unload all vars from the current env
unsetenv() {
  local quiet=false
  [[ "$1" == "--quiet" ]] && quiet=true

  if (( ! ${#_ENVSWITCH_LOADED_VARS[@]} )); then
    $quiet || _es_info "Nothing to clear"
    return
  fi

  for var in "${_ENVSWITCH_LOADED_VARS[@]}"; do
    unset "$var"
  done
  local prev="$_ENVSWITCH_ACTIVE_ENV"
  _ENVSWITCH_LOADED_VARS=()
  _ENVSWITCH_ACTIVE_ENV=""
  _ENVSWITCH_AUTO_LOADED=""
  _ENVSWITCH_CACHED_DIR=""
  _ENVSWITCH_CACHED_BRANCH=""
  _ENVSWITCH_CACHED_CONTEXT=""
  $quiet || _es_ok "Cleared \e[1m${prev}\e[0m environment"
}

# ── envstatus ─────────────────────────────────────────────────
envstatus() {
  local show_full=false
  [[ "$1" == "--full" || "$1" == "-f" ]] && show_full=true

  local col_name="\e[37m"
  local col_val="\e[33m"
  local col_dim="\e[90m"
  local col_head="\e[36m"
  local col_reset="\e[0m"

  if [[ -z "$_ENVSWITCH_ACTIVE_ENV" ]]; then
    _es_info "No environment loaded"
    if $show_full; then
      printf "\n${col_head}━━ Shell environment (%d vars) ━━━━━━━━━━━━━${col_reset}\n" "$(env | wc -l | tr -d ' ')"
      env | sort | while IFS='=' read -r key val; do
        printf "  ${col_dim}%-30s${col_reset} %s\n" "$key" "$val"
      done
    else
      local count="$(env | wc -l | tr -d ' ')"
      _es_info "${count} shell variables present. Use ${col_name}envstatus --full${col_reset} to see them."
    fi
    return
  fi

  # Header
  print -P "%F{cyan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%f"
  print -P " Active env: %F{green}%B${_ENVSWITCH_ACTIVE_ENV}%b%f"
  [[ -n "$_ENVSWITCH_AUTO_LOADED" ]] && print -P " Loaded by:  %F{240}auto (dir/branch match)%f"
  [[ -n "$_ENVSWITCH_CACHED_CONTEXT" ]] && print -P " Context:    %F{yellow}${_ENVSWITCH_CACHED_CONTEXT}%f"
  print -P " Env vars:   %F{yellow}${#_ENVSWITCH_LOADED_VARS[@]}%f"
  print -P " Shell vars: %F{240}${#_ENVSWITCH_SHELL_SNAPSHOT[@]}%f"
  print -P "%F{cyan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%f"

  # Loaded env vars
  printf "\n${col_head} Loaded from ${_ENVSWITCH_ACTIVE_ENV}.env${col_reset}\n\n"
  for var in "${_ENVSWITCH_LOADED_VARS[@]}"; do
    local val="${(P)var}"
    if ! $show_full; then
      val="$(_es_mask "$val")"
    fi
    printf "  ${col_name}%-30s${col_reset} ${col_val}%s${col_reset}\n" "$var" "$val"
  done

  # Shell vars
  printf "\n${col_head} Shell environment (%d vars)${col_reset}\n\n" "${#_ENVSWITCH_SHELL_SNAPSHOT[@]}"
  if $show_full; then
    for var in "${_ENVSWITCH_SHELL_SNAPSHOT[@]}"; do
      [[ "$var" == _ENVSWITCH_* ]] && continue
      (( ${_ENVSWITCH_LOADED_VARS[(Ie)$var]} )) && continue
      local val="${(P)var}"
      if (( ${#val} > 80 )); then
        val="${val:0:77}..."
      fi
      printf "  ${col_dim}%-30s${col_reset} %s\n" "$var" "$val"
    done
  else
    local i=0
    for var in "${_ENVSWITCH_SHELL_SNAPSHOT[@]}"; do
      [[ "$var" == _ENVSWITCH_* ]] && continue
      (( ${_ENVSWITCH_LOADED_VARS[(Ie)$var]} )) && continue
      printf "  ${col_dim}%-24s${col_reset}" "$var"
      (( i++ ))
      (( i % 3 == 0 )) && printf "\n"
    done
    (( i % 3 != 0 )) && printf "\n"
    printf "\n${col_dim}  Tip: envstatus --full  to reveal all values${col_reset}\n"
  fi
  echo ""
}

# ── envls ─────────────────────────────────────────────────────
envls() {
  if [[ ! -d "$ENVSWITCH_DIR" ]]; then
    _es_warn "Env directory doesn't exist yet: $ENVSWITCH_DIR"
    _es_info "Run: addenv to create your first one"
    return
  fi
  local envfiles=("$ENVSWITCH_DIR"/*.env(N))
  if (( ${#envfiles} == 0 )); then
    _es_info "No env files in $ENVSWITCH_DIR"
    return
  fi
  print -P "%F{cyan}━━ Available environments ━━━━━━━━━━━━━━━━━━━━━━%f"
  for f in "${envfiles[@]}"; do
    local name="$(basename "$f" .env)"
    local varcount=$(_es_varnames "$f" | wc -l | tr -d ' ')
    local dir_tag="$(_es_read_tag "$f" "dir")"
    local branch_tag="$(_es_read_tag "$f" "branch")"

    local marker=""
    [[ "$name" == "$_ENVSWITCH_ACTIVE_ENV" ]] && marker=" %F{green}◀ active%f"

    local tags=""
    [[ -n "$dir_tag" ]] && tags=" %F{240}dir:${dir_tag}"
    [[ -n "$branch_tag" ]] && tags="${tags} branch:${branch_tag}"
    [[ -n "$tags" ]] && tags="${tags}%f"

    if _es_is_protected "$name" || { [[ "$name" == *_* ]] && _es_is_protected "${name#*_}"; }; then
      print -P "  %F{red}* %-24s%f %F{240}${varcount} vars%f${tags}${marker}" "$name"
    else
      print -P "  %F{green}   %-24s%f %F{240}${varcount} vars%f${tags}${marker}" "$name"
    fi
  done
}

# ── addenv (interactive when no args) ─────────────────────────
addenv() {
  local final_name=""
  local dir_tag=""
  local branch_tag=""

  if [[ -n "$1" ]]; then
    # Quick mode: addenv <name>
    final_name="$1"
  else
    # Interactive mode
    print -P "%F{cyan}━━ Create new environment ━━━━━━━━━━━%f"
    echo ""

    # Step 1: env name
    printf "  Name (e.g. staging, dev, api_keys): "
    local env_name
    read env_name
    if [[ -z "$env_name" ]]; then
      _es_err "Name is required"
      return 1
    fi

    # Step 2: project prefix (optional)
    printf "  Project prefix? (e.g. growth, payments — enter to skip): "
    local prefix
    read prefix

    if [[ -n "$prefix" ]]; then
      final_name="${prefix}_${env_name}"
    else
      final_name="$env_name"
    fi

    # Step 3: auto-load directory (optional)
    printf "  Auto-load for directory? (e.g. ~/monorepo — enter to skip): "
    local dir_input
    read dir_input
    if [[ -n "$dir_input" ]]; then
      dir_tag="${dir_input}"

      # Step 4: branch pattern (only ask if dir was set)
      printf "  Branch pattern? (e.g. growth/* — enter to skip): "
      local branch_input
      read branch_input
      [[ -n "$branch_input" ]] && branch_tag="$branch_input"
    fi

    echo ""
  fi

  # Ensure directory exists
  mkdir -p "$ENVSWITCH_DIR"

  local file="${ENVSWITCH_DIR}/${final_name}.env"
  if [[ -f "$file" ]]; then
    _es_warn "File already exists: ${final_name}.env"
    _es_info "Opening in editor..."
  else
    # Build the header
    {
      echo "# ── ${final_name} environment ──"
      echo "# Loaded via envswitch · created $(date +%Y-%m-%d)"
      [[ -n "$dir_tag" ]] && echo "# dir: ${dir_tag}"
      [[ -n "$branch_tag" ]] && echo "# branch: ${branch_tag}"
      echo "#"
      echo "# Add your variables below:"
      echo "# API_KEY=your_key_here"
      echo "# DATABASE_URL=postgres://..."
      echo ""
    } > "$file"
    _es_ok "Created ${final_name}.env"

    if [[ -n "$dir_tag" ]]; then
      local auto_msg="auto-loads in ${dir_tag}"
      [[ -n "$branch_tag" ]] && auto_msg="${auto_msg} on ${branch_tag}"
      _es_info "$auto_msg"
    fi
  fi

  # Open in configured editor
  _es_info "Opening with ${ENVSWITCH_EDITOR}..."
  ${=ENVSWITCH_EDITOR} "$file"

  # Refresh everything
  _es_build_dirmap
  _es_register_aliases
}

# ── editenv ───────────────────────────────────────────────────
editenv() {
  local name="$1"
  if [[ -z "$name" ]]; then
    _es_err "Usage: editenv <n>"
    return 1
  fi

  local file="${ENVSWITCH_DIR}/${name}.env"
  if [[ ! -f "$file" ]]; then
    _es_err "No env file found: $name"
    _es_info "Run 'addenv ${name}' to create it"
    return 1
  fi

  _es_info "Opening with ${ENVSWITCH_EDITOR}..."
  ${=ENVSWITCH_EDITOR} "$file"

  # Refresh in case dir/branch tags changed
  _es_build_dirmap
}

# ── rmenv ─────────────────────────────────────────────────────
rmenv() {
  local name="$1"
  if [[ -z "$name" ]]; then
    _es_err "Usage: rmenv <n>"
    return 1
  fi

  local file="${ENVSWITCH_DIR}/${name}.env"
  if [[ ! -f "$file" ]]; then
    _es_err "No env file found: $file"
    return 1
  fi

  echo -n "Remove ${name}.env? (y/n): "
  local confirm
  read confirm
  [[ "$confirm" != "y" ]] && return

  rm "$file"
  _es_ok "Removed ${name}.env"

  [[ "$_ENVSWITCH_ACTIVE_ENV" == "$name" ]] && unsetenv
  _es_build_dirmap
  _es_register_aliases
}

# ── Config commands ───────────────────────────────────────────
setenvdir() {
  local dir="$1"
  if [[ -z "$dir" ]]; then
    _es_info "Current env dir: $ENVSWITCH_DIR"
    _es_info "Usage: setenvdir /path/to/envs"
    return
  fi
  dir="${dir/#\~/$HOME}"
  export ENVSWITCH_DIR="$dir"
  _es_ok "Env directory set to: $ENVSWITCH_DIR"
  _es_build_dirmap
  _es_register_aliases
}

setenveditor() {
  local editor="$1"
  if [[ -z "$editor" ]]; then
    _es_info "Current editor: $ENVSWITCH_EDITOR"
    _es_info "Usage: setenveditor vim"
    return
  fi
  export ENVSWITCH_EDITOR="$editor"
  _es_ok "Editor set to: $ENVSWITCH_EDITOR"
}

protectenv() {
  local name="$1"
  if [[ -z "$name" ]]; then
    _es_info "Currently protected: ${ENVSWITCH_PROTECT//:/, }"
    _es_info "Usage: protectenv <n>  |  unprotectenv <n>"
    return
  fi
  if _es_is_protected "$name"; then
    _es_warn "$name is already protected"
    return
  fi
  export ENVSWITCH_PROTECT="${ENVSWITCH_PROTECT}:${name}"
  _es_ok "$name is now protected (requires confirmation)"
}

unprotectenv() {
  local name="$1"
  if [[ -z "$name" ]]; then
    _es_err "Usage: unprotectenv <n>"
    return 1
  fi
  local new_list=""
  local IFS=':'
  for p in ${=ENVSWITCH_PROTECT}; do
    [[ "$p" != "$name" ]] && new_list="${new_list}:${p}"
  done
  export ENVSWITCH_PROTECT="${new_list#:}"
  _es_ok "$name is no longer protected"
}

# ── envrefresh ────────────────────────────────────────────────
# Re-check dir+branch and reload if needed
envrefresh() {
  _es_build_dirmap
  if ! $_ENVSWITCH_HAS_DIR_TAGS; then
    _es_info "No dir/branch tags found in any env files"
    return
  fi
  # Force re-evaluation by clearing cache
  _ENVSWITCH_CACHED_DIR=""
  _ENVSWITCH_CACHED_BRANCH=""
  _es_chpwd_hook
}

# ── Help ──────────────────────────────────────────────────────
envhelp() {
  print -P ""
  print -P "%F{cyan}%B━━━ envswitch ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%b%f"
  print -P ""
  print -P "  %F{green}%B<name>%b%f                 Load env (auto-generated command)"
  print -P "  %F{green}loadenv%f <name>         Load env by name or path"
  print -P "  %F{green}unsetenv%f               Unload current env"
  print -P "  %F{green}envstatus%f              Show active env + all vars (masked)"
  print -P "  %F{green}envstatus --full%f       Show all vars with full values"
  print -P "  %F{green}envls%f                  List all available envs"
  print -P "  %F{green}addenv%f [name]          Create new env (interactive if no args)"
  print -P "  %F{green}editenv%f <name>         Open existing env in editor"
  print -P "  %F{green}rmenv%f <name>           Delete an env file"
  print -P "  %F{green}envrefresh%f             Re-scan dir/branch tags and reload"
  print -P ""
  print -P "  %F{yellow}setenvdir%f [path]       View/change env directory"
  print -P "  %F{yellow}setenveditor%f [cmd]     View/change editor"
  print -P "  %F{yellow}protectenv%f <name>      Require confirmation to load"
  print -P "  %F{yellow}unprotectenv%f <name>    Remove load confirmation"
  print -P ""
  print -P " %F{240}Auto-loading:%f"
  print -P "  Add %F{white}# dir: ~/path%f and %F{white}# branch: pattern%f to env file headers."
  print -P "  envswitch auto-loads matching envs on cd and branch switch."
  print -P "  Only tag your safe defaults (staging) — never tag production."
  print -P "  When in context, typing %F{white}production%f resolves to %F{white}{project}_production%f."
  print -P ""
  if $_ENVSWITCH_HAS_DIR_TAGS; then
    print -P " %F{240}Active dir mappings:%f"
    for (( i=1; i<=${#_ENVSWITCH_DM_DIRS}; i++ )); do
      local b="${_ENVSWITCH_DM_BRANCHES[$i]}"
      [[ -z "$b" ]] && b="(any)"
      print -P "   %F{white}${_ENVSWITCH_DM_ENVS[$i]}%f → ${_ENVSWITCH_DM_DIRS[$i]} @ ${b}"
    done
    print -P ""
  fi
  print -P "  %F{cyan}Dir:%f    $ENVSWITCH_DIR"
  print -P "  %F{cyan}Editor:%f $ENVSWITCH_EDITOR"
  print -P ""
}

# ── Dynamic alias registration ────────────────────────────────
_es_register_aliases() {
  if (( ${+_ENVSWITCH_REGISTERED} )); then
    for fn in "${_ENVSWITCH_REGISTERED[@]}"; do
      unfunction "$fn" 2>/dev/null
    done
  fi
  typeset -ga _ENVSWITCH_REGISTERED=()

  [[ ! -d "$ENVSWITCH_DIR" ]] && return

  local envfiles=("$ENVSWITCH_DIR"/*.env(N))

  # Collect unique suffixes for context-aware aliases
  # e.g., growth_staging + payments_staging → "staging" gets an alias
  typeset -A suffix_seen
  typeset -A full_seen

  for f in "${envfiles[@]}"; do
    local name="$(basename "$f" .env)"
    full_seen[$name]=1

    if [[ "$name" == *_* ]]; then
      local suffix="${name#*_}"
      suffix_seen[$suffix]=1
    fi
  done

  # Register full-name aliases (growth_staging, payments_production, etc.)
  for name in "${(@k)full_seen}"; do
    # Skip if it would conflict with a builtin/existing command
    if ! (( ${+_ENVSWITCH_REGISTERED[(r)$name]} )); then
      eval "${name}() { loadenv \"${name}\"; }"
      _ENVSWITCH_REGISTERED+=("$name")
    fi
  done

  # Register suffix aliases (staging, production, etc.)
  # These are context-aware — loadenv handles resolution
  for suffix in "${(@k)suffix_seen}"; do
    # Only register if not already registered as a full name
    if ! (( ${+full_seen[$suffix]} )) && ! (( ${_ENVSWITCH_REGISTERED[(Ie)$suffix]} )); then
      eval "${suffix}() { loadenv \"${suffix}\"; }"
      _ENVSWITCH_REGISTERED+=("$suffix")
    fi
  done
}

# ── chpwd hook (auto-load on cd) ─────────────────────────────
_es_chpwd_hook() {
  # Bail if no dir tags exist
  $_ENVSWITCH_HAS_DIR_TAGS || return

  # Skip if user manually loaded something (not auto)
  if [[ -n "$_ENVSWITCH_ACTIVE_ENV" && "$_ENVSWITCH_AUTO_LOADED" != "auto" ]]; then
    return
  fi

  local resolved="$(_es_resolve_auto)"

  if [[ -n "$resolved" ]]; then
    local current_dir="$PWD"
    local branch="$(_es_current_branch 2>/dev/null)"

    # Cache hit — don't reload
    if [[ "$_ENVSWITCH_CACHED_DIR" == "$current_dir" && "$_ENVSWITCH_CACHED_BRANCH" == "${branch:-none}" ]]; then
      return
    fi

    _ENVSWITCH_CACHED_DIR="$current_dir"
    _ENVSWITCH_CACHED_BRANCH="${branch:-none}"
    _ENVSWITCH_CACHED_CONTEXT="$(_es_extract_prefix "$resolved")"

    local reason="dir:$PWD"
    [[ -n "$branch" ]] && reason="${reason}, branch:${branch}"
    _es_auto_load "$resolved" "$reason"
  else
    # Left all mapped directories — clear auto-loaded env
    if [[ "$_ENVSWITCH_AUTO_LOADED" == "auto" ]]; then
      _es_ok "Left mapped directory, clearing \e[1m${_ENVSWITCH_ACTIVE_ENV}\e[0m"
      unsetenv --quiet
      _ENVSWITCH_CACHED_DIR=""
      _ENVSWITCH_CACHED_BRANCH=""
      _ENVSWITCH_CACHED_CONTEXT=""
    fi
  fi
}

# ── git wrapper (detect branch changes) ──────────────────────
# Only intercepts branch-changing subcommands, passes everything
# else straight to real git with zero overhead.

_es_real_git="$(command -v git)"

git() {
  local subcmd="$1"

  # Run real git
  "$_es_real_git" "$@"
  local ret=$?

  # Only check after branch-changing commands
  case "$subcmd" in
    checkout|switch|pull|merge|rebase)
      # Only if we have dir tags and we're in a mapped dir
      if $_ENVSWITCH_HAS_DIR_TAGS; then
        local new_branch="$("$_es_real_git" branch --show-current 2>/dev/null)"
        if [[ -n "$new_branch" && "$new_branch" != "$_ENVSWITCH_CACHED_BRANCH" ]]; then
          _ENVSWITCH_CACHED_BRANCH=""  # force re-evaluation
          _es_chpwd_hook
        fi
      fi
      ;;
  esac

  return $ret
}

# ── Prompt integration ────────────────────────────────────────
envswitch_prompt_info() {
  if [[ -n "$_ENVSWITCH_ACTIVE_ENV" ]]; then
    if _es_is_protected "$_ENVSWITCH_ACTIVE_ENV" || \
       { [[ "$_ENVSWITCH_ACTIVE_ENV" == *_* ]] && _es_is_protected "${_ENVSWITCH_ACTIVE_ENV#*_}"; }; then
      print -n "[%F{red}%B${_ENVSWITCH_ACTIVE_ENV}%b%f] "
    else
      print -n "[%F{yellow}${_ENVSWITCH_ACTIVE_ENV}%f] "
    fi
  fi
}

# ── Tab completion ────────────────────────────────────────────
_envswitch_complete() {
  local envfiles=("$ENVSWITCH_DIR"/*.env(N))
  local names=()
  for f in "${envfiles[@]}"; do
    names+=("$(basename "$f" .env)")
  done
  compadd -a names
}

compdef _envswitch_complete loadenv
compdef _envswitch_complete editenv
compdef _envswitch_complete rmenv
compdef _envswitch_complete protectenv
compdef _envswitch_complete unprotectenv

# ── Init ──────────────────────────────────────────────────────
autoload -U colors && colors
setopt PROMPT_SUBST
mkdir -p "$ENVSWITCH_DIR" 2>/dev/null
_es_build_dirmap
_es_register_aliases

# Set default prompt (override by setting ENVSWITCH_PROMPT=false before sourcing,
# or by setting your own PROMPT after sourcing)
if [[ "${ENVSWITCH_PROMPT}" != "false" ]]; then
  PROMPT='%F{cyan}%n@%m%f $(envswitch_prompt_info)%F{green}%~%f %# '
fi

# Register chpwd hook (only if dir tags exist)
autoload -Uz add-zsh-hook
add-zsh-hook chpwd _es_chpwd_hook
