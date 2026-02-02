#compdef claude-cage
# Zsh completion for claude-cage
#
# Install options:
#   1. Run: eval "$(claude-cage completion zsh)"
#   2. Or copy this file to ~/.zsh/completions/_claude-cage
#      and add to ~/.zshrc (before compinit): fpath=(~/.zsh/completions $fpath)

_claude_cage() {
    local -a subcommands flags

    subcommands=(
        'git-merge:Fetch refs from intermediary for manual merge'
        'clean:Remove cached branch (interactive selection)'
        'clean-all:Remove all cached branches for this project'
        'completion:Output shell completion script'
    )

    flags=(
        '--test[Drop into a shell for testing]'
        '--direct-mount[Mount source directly without git sync]'
        '--branch[Specify branch for clean command]:branch:_claude_cage_branches'
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
                completion) _values 'shell' bash zsh ;;
            esac
            ;;
    esac
}

_claude_cage_branches() {
    local cache_dir="${CLAUDE_CAGE_CACHE:-$HOME/.cache/claude-cage}"
    [ -d "$cache_dir/branches" ] && _describe -t branches 'branch' $(ls -1 "$cache_dir/branches" 2>/dev/null)
}

_claude_cage "$@"
