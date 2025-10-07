# porg_completions.bash - Bash completion for porg
# Install: copy to /etc/bash_completion.d/porg_completions.bash and reload shell.

_porg_installed_pkgs() {
  # try to read installed DB (json) for names; fallback to empty
  local db="/var/lib/porg/db/installed.json"
  if [ -f "$db" ] && command -v jq >/dev/null 2>&1; then
    jq -r 'to_entries[] | .value.name // .key' "$db" 2>/dev/null
    return
  fi
  # fallback: list prefixes in /var/lib/porg/db (best-effort)
  if [ -d "/usr/ports" ]; then
    find /usr/ports -maxdepth 3 -type f -iname '*.ya*ml' -printf '%f\n' 2>/dev/null | sed -E 's/\.(ya?ml)$//i' | sed -E 's/^[^/]+-//'
  fi
}

_porg_available_pkgs() {
  # list package metafile basenames from /usr/ports
  if [ -d "/usr/ports" ]; then
    find /usr/ports -type f -iname '*.ya*ml' -printf '%f\n' 2>/dev/null | sed -E 's/\.(ya?ml)$//i'
  fi
}

_porg_commands() {
  printf "%s\n" "--init" "--install" "--remove" "--upgrade" "--resolve" "--audit" "--sync" "--db" "--logs" \
    "--search" "--info" "--graph" "--status" "--history" "--repair" "--completion" "--help" \
    "--dry-run" "--yes" "--quiet" "--progress" "--parallel" "--json" "--bwrap"
}

_porg_complete() {
  local cur prev opts cmds
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"
  cmds="$(_porg_commands)"

  # complete top-level commands
  if [ $COMP_CWORD -eq 1 ]; then
    COMPREPLY=( $(compgen -W "$cmds" -- "$cur") )
    return 0
  fi

  # complete arguments for certain commands
  case "${COMP_WORDS[1]}" in
    --install|-i)
      # suggest available packages
      opts="$(_porg_available_pkgs)"
      COMPREPLY=( $(compgen -W "$opts" -- "$cur") )
      ;;
    --remove|-r)
      opts="$(_porg_installed_pkgs)"
      COMPREPLY=( $(compgen -W "$opts" -- "$cur") )
      ;;
    --upgrade|-u)
      # suggest installed and available
      opts="$(printf "%s\n%s\n" "$(_porg_installed_pkgs)" "$(_porg_available_pkgs)" )"
      COMPRETRY=( $(compgen -W "$opts" -- "$cur") )
      COMPREPLY=( $(compgen -W "$opts" -- "$cur") )
      ;;
    --search)
      # no completion (free-text)
      COMPREPLY=()
      ;;
    --info|--graph)
      opts="$(printf "%s\n%s\n" "$(_porg_installed_pkgs)" "$(_porg_available_pkgs)")"
      COMPREPLY=( $(compgen -W "$opts" -- "$cur") )
      ;;
    --parallel)
      COMPREPLY=( $(compgen -W "1 2 4 8 16 32" -- "$cur") )
      ;;
    *)
      COMPREPLY=( $(compgen -W "$cmds" -- "$cur") )
      ;;
  esac
}

complete -F _porg_complete porg
