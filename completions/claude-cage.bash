# Bash completion for claude-cage
#
# Install options:
#   1. Run: eval "$(claude-cage completion bash)"
#   2. Or copy this file to ~/.local/share/bash-completion/completions/claude-cage
#   3. Or source from ~/.bashrc: source /path/to/claude-cage.bash

_claude_cage() {
    local cur prev words cword
    _init_completion 2>/dev/null || return

    local subcommands="git-merge clean clean-all completion install-completions"
    local flags="--test --direct-mount --branch --dry-run --verbose -v --debug --help -h --version"

    case "$prev" in
        --branch)
            local cache_dir="${CLAUDE_CAGE_CACHE:-$HOME/.cache/claude-cage}"
            if [ -d "$cache_dir/branches" ]; then
                COMPREPLY=($(compgen -W "$(ls -1 "$cache_dir/branches" 2>/dev/null)" -- "$cur"))
            fi
            return
            ;;
        completion)
            COMPREPLY=($(compgen -W "bash zsh" -- "$cur"))
            return
            ;;
    esac

    if [[ "$cur" == -* ]]; then
        COMPREPLY=($(compgen -W "$flags" -- "$cur"))
    else
        COMPREPLY=($(compgen -W "$subcommands $flags" -- "$cur"))
    fi
}
complete -F _claude_cage claude-cage
