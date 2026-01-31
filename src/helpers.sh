# ============================================================================
# Helper functions
# ============================================================================

# Parse --dry-run, --verbose, --debug early
dry_run=false
verbose=false
debug=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) dry_run=true ;;
        --verbose|-v) verbose=true ;;
        --debug) debug=true ;;
    esac
done

# --debug implies --verbose
[ "$debug" = true ] && verbose=true

# ANSI color codes
_yellow='\033[33m'
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
