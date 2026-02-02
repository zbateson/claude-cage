#compdef claude-cage
# Zsh completion for claude-cage
# Put this file in a directory in your $fpath (e.g., ~/.zsh/completions/)

_claude_cage() {
    local -a subcommands flags

    subcommands=(
        'git-merge:Fetch refs from intermediary for manual merge'
        'clean:Remove cached branch (interactive selection)'
        'clean-all:Remove all cached branches for this project'
    )

    flags=(
        '--test[Drop into a shell for testing instead of launching]'
        '--direct-mount[Mount source directly without git sync]'
        '--branch[Specify branch for clean command]:branch:_claude_cage_branches'
        '--dry-run[Show commands without executing]'
        '(-v --verbose)'{-v,--verbose}'[Show commands as they execute]'
        '--debug[Show command output (implies --verbose)]'
        '(-h --help)'{-h,--help}'[Show help message]'
        '--version[Show version number]'
    )

    _arguments -C \
        $flags \
        '1: :->command' \
        '*::arg:->args'

    case "$state" in
        command)
            _describe -t subcommands 'subcommand' subcommands
            ;;
        args)
            case "${words[1]}" in
                clean)
                    _arguments \
                        '--branch[Specify branch to clean]:branch:_claude_cage_branches'
                    ;;
            esac
            ;;
    esac
}

_claude_cage_branches() {
    local cache_dir="${CLAUDE_CAGE_CACHE:-$HOME/.cache/claude-cage}"
    if [ -d "$cache_dir/branches" ]; then
        local -a branches
        branches=(${(f)"$(ls -1 "$cache_dir/branches" 2>/dev/null)"})
        _describe -t branches 'cached branch' branches
    fi
}

_claude_cage "$@"
