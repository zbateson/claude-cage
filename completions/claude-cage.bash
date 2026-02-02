# Bash completion for claude-cage
# Put this file in /etc/bash_completion.d/ or source it from ~/.bashrc

_claude_cage() {
    local cur prev words cword
    _init_completion || return

    local subcommands="git-merge clean clean-all"
    local flags="--test --direct-mount --branch --dry-run --verbose -v --debug --help -h --version"

    case "$prev" in
        --branch)
            # Complete with cached branches
            local cache_dir="${CLAUDE_CAGE_CACHE:-$HOME/.cache/claude-cage}"
            if [ -d "$cache_dir/branches" ]; then
                local branches=$(ls -1 "$cache_dir/branches" 2>/dev/null)
                COMPREPLY=($(compgen -W "$branches" -- "$cur"))
            fi
            return
            ;;
    esac

    # If first non-option argument, offer subcommands
    local has_subcommand=false
    for word in "${words[@]:1:$cword-1}"; do
        case "$word" in
            git-merge|clean|clean-all)
                has_subcommand=true
                break
                ;;
        esac
    done

    if [ "$has_subcommand" = false ]; then
        if [[ "$cur" == -* ]]; then
            COMPREPLY=($(compgen -W "$flags" -- "$cur"))
        else
            COMPREPLY=($(compgen -W "$subcommands $flags" -- "$cur"))
        fi
    else
        # After subcommand, only offer relevant flags
        case "${words[1]}" in
            clean)
                COMPREPLY=($(compgen -W "--branch" -- "$cur"))
                ;;
            *)
                COMPREPLY=($(compgen -W "$flags" -- "$cur"))
                ;;
        esac
    fi
}

complete -F _claude_cage claude-cage
