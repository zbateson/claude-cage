# ============================================================================
# Helper functions
# ============================================================================

# Parse --dry-run, --verbose, --debug, --help, --version early
dry_run=false
verbose=false
debug=false
show_help=false
show_version=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) dry_run=true ;;
        --verbose|-v) verbose=true ;;
        --debug) debug=true ;;
        --help|-h) show_help=true ;;
        --version) show_version=true ;;
    esac
done

# --debug implies --verbose
[ "$debug" = true ] && verbose=true

# ANSI color codes
_yellow='\033[33m'
_cyan='\033[1;36m'
_white='\033[1;37m'
_red='\033[1;31m'
_reset='\033[0m'

# Wrapper function for commands that modify the system
# In dry-run mode, prints the command instead of executing it
# In verbose mode, prints the command before executing
run() {
    if [ "$dry_run" = true ]; then
        echo "[dry-run] $*"
        return 0
    fi
    if [ "$verbose" = true ]; then
        echo -e "${_yellow}[run] $*${_reset}" >&2
    fi
    "$@"
}

# Wrapper for commands that should be silent in normal mode
# In verbose mode, prints the command before executing
# In debug mode, shows command output instead of suppressing it
run_quiet() {
    if [ "$dry_run" = true ]; then
        echo "[dry-run] $*"
        return 0
    fi
    if [ "$verbose" = true ]; then
        echo -e "${_yellow}[run] $*${_reset}" >&2
    fi
    if [ "$debug" = true ]; then
        "$@"
    else
        "$@" >/dev/null
    fi
}

# Display help message
show_help() {
    cat << 'EOF'
claude-cage - A sandboxed git workflow for Claude Code

Usage: claude-cage [options] [subcommand] [-- args...]

Subcommands:
  git-merge               Fetch refs from intermediary for manual merge
  clean [ID...]           Remove cached session(s) (interactive if no ID given)
  clean --all             Remove all cached sessions for this project
  completion SHELL        Output shell completion script (bash or zsh)
  install-completions     Install shell completions for current shell

Options:
  --test                  Drop into a shell for testing instead of launching
  --direct-mount          Mount source directly without git sync
  --scoped                Scope intermediary to CWD subdirectory only
  --attach-session [TS]   Attach to an active session (optionally by timestamp)
  --all                   Remove all sessions (with clean subcommand)
  --dry-run               Show commands without executing
  --verbose, -v           Show commands as they execute
  --debug                 Show command output (implies --verbose)
  --help, -h              Show this help message
  --version               Show version number

Arguments after -- are passed through to the launch command.

Config files (loaded in order, later values override):
  /etc/claude-cage.conf              System-wide config
  ~/.config/claude-cage/config       User config
  includeIf matches                  Directory-scoped configs (set in system/user)
  .claude-cage                       Project config (at git root)

Examples:
  claude-cage                        Start sandbox with configured launch command
  claude-cage --test                 Drop into a shell for testing
  claude-cage --resume               Pass --resume to the launch command
  claude-cage --attach-session       Attach to an active session
  claude-cage clean                  Interactively select session cache(s) to remove
  claude-cage clean 20250206143022   Remove cache for specific session
  claude-cage clean --all            Remove all cached sessions for this project
  claude-cage git-merge              Fetch intermediary refs for manual merge

For more info, see: https://github.com/zbateson/claude-cage
EOF
}

# Output bash completion script
output_bash_completion() {
    cat << 'EOF'
# Bash completion for claude-cage
_claude_cage() {
    local cur prev words cword
    _init_completion 2>/dev/null || return

    local subcommands="git-merge clean completion install-completions"
    local flags="--test --direct-mount --scoped --attach-session --all --dry-run --verbose -v --debug --help -h --version"

    # Check if 'clean' subcommand is present in the command line
    local has_clean=false
    for word in "${words[@]}"; do
        [ "$word" = "clean" ] && has_clean=true
    done

    case "$prev" in
        --attach-session)
            local cache_dir="${CLAUDE_CAGE_CACHE:-$HOME/.cache/claude-cage}"
            if [ -d "$cache_dir/sessions" ]; then
                COMPREPLY=($(compgen -W "$(ls -1 "$cache_dir/sessions" 2>/dev/null)" -- "$cur"))
            fi
            return
            ;;
        completion)
            COMPREPLY=($(compgen -W "bash zsh" -- "$cur"))
            return
            ;;
    esac

    # After 'clean', complete session IDs and --all
    if [ "$has_clean" = true ]; then
        local cache_dir="${CLAUDE_CAGE_CACHE:-$HOME/.cache/claude-cage}"
        local sessions=""
        [ -d "$cache_dir/sessions" ] && sessions=$(ls -1 "$cache_dir/sessions" 2>/dev/null)
        COMPREPLY=($(compgen -W "$sessions --all" -- "$cur"))
        return
    fi

    if [[ "$cur" == -* ]]; then
        COMPREPLY=($(compgen -W "$flags" -- "$cur"))
    else
        COMPREPLY=($(compgen -W "$subcommands $flags" -- "$cur"))
    fi
}
complete -F _claude_cage claude-cage
EOF
}

# Output zsh completion script
output_zsh_completion() {
    cat << 'EOF'
#compdef claude-cage
_claude_cage() {
    local -a subcommands flags

    subcommands=(
        'git-merge:Fetch refs from intermediary for manual merge'
        'clean:Remove cached session(s) (interactive if no ID given)'
        'completion:Output shell completion script'
        'install-completions:Install shell completions for current shell'
    )

    flags=(
        '--test[Drop into a shell for testing]'
        '--direct-mount[Mount source directly without git sync]'
        '--scoped[Scope intermediary to CWD subdirectory only]'
        '--attach-session[Attach to an active session]:session:_claude_cage_sessions'
        '--all[Remove all sessions (with clean subcommand)]'
        '--dry-run[Show commands without executing]'
        '(-v --verbose)'{-v,--verbose}'[Show commands as they execute]'
        '--debug[Show command output (implies --verbose)]'
        '(-h --help)'{-h,--help}'[Show help message]'
        '--version[Show version number]'
    )

    _arguments -C $flags '1: :->command' '*::arg:->args'

    case "$state" in
        command) _describe -t subcommands 'subcommand' subcommands ;;
        args)
            case "${words[1]}" in
                clean) _claude_cage_sessions ;;
                completion) _values 'shell' bash zsh ;;
            esac
            ;;
    esac
}

_claude_cage_sessions() {
    local cache_dir="${CLAUDE_CAGE_CACHE:-$HOME/.cache/claude-cage}"
    [ -d "$cache_dir/sessions" ] && _describe -t sessions 'session' $(ls -1 "$cache_dir/sessions" 2>/dev/null)
}

_claude_cage "$@"
EOF
}
