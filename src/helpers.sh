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
        "$@" >/dev/null 2>&1
    fi
}

# Display help message
show_help() {
    cat << 'EOF'
claude-cage - A sandboxed git workflow for Claude Code

Usage: claude-cage [options] [subcommand] [-- args...]

Subcommands:
  git-merge       Fetch refs from intermediary for manual merge
  clean           Remove cached branch (interactive selection)
  clean-all       Remove all cached branches for this project

Options:
  --test          Drop into a shell for testing instead of launching
  --direct-mount  Mount source directly without git sync
  --branch NAME   Specify branch for clean command
  --dry-run       Show commands without executing
  --verbose, -v   Show commands as they execute
  --debug         Show command output (implies --verbose)
  --help, -h      Show this help message
  --version       Show version number

Arguments after -- are passed through to the launch command.

Config files (loaded in order, later values override):
  /etc/claude-cage.conf              System-wide config
  ~/.config/claude-cage/config       User config
  <ancestors>/.claude-cage           Ancestor directory configs
  .claude-cage                       Project config

Examples:
  claude-cage                    Start sandbox with configured launch command
  claude-cage --test             Drop into a shell for testing
  claude-cage --resume           Pass --resume to the launch command
  claude-cage clean              Interactively select branch cache to remove
  claude-cage clean --branch main  Remove cache for 'main' branch
  claude-cage git-merge          Fetch intermediary refs for manual merge

For more info, see: https://github.com/zbateson/claude-cage
EOF
}
