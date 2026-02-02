#!/usr/bin/env bash
# config-builder.sh - Interactive config generator

# shellcheck source=src/helpers.sh
# Assumes helpers.sh is already sourced (for colors)

config_builder_prompt_yesno() {
    local prompt="$1"
    local default="${2:-y}"
    local yn_hint="[Y/n]"
    [ "$default" = "n" ] && yn_hint="[y/N]"

    while true; do
        printf "%s %s " "$prompt" "$yn_hint"
        read -r answer
        answer="${answer:-$default}"
        case "$answer" in
            [Yy]*) return 0 ;;
            [Nn]*) return 1 ;;
            *) echo "Come on, yes or no." ;;
        esac
    done
}

config_builder_prompt_choice() {
    local prompt="$1"
    shift
    local options=("$@")
    local count=${#options[@]}

    echo "$prompt"
    for i in "${!options[@]}"; do
        printf "  %d) %s\n" "$((i + 1))" "${options[$i]}"
    done

    while true; do
        printf "Choice [1-%d]: " "$count"
        read -r choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$count" ]; then
            return $((choice - 1))
        fi
        echo "Pick a number between 1 and $count, friend."
    done
}

config_builder_prompt_multi() {
    local prompt="$1"
    shift
    local options=("$@")
    local count=${#options[@]}
    local selected=()

    # Initialize all as selected
    for ((i = 0; i < count; i++)); do
        selected+=("1")
    done

    echo "$prompt"
    echo "(Hit a number to toggle, Enter when you're done)"
    echo

    while true; do
        for i in "${!options[@]}"; do
            local mark="[ ]"
            [ "${selected[$i]}" = "1" ] && mark="[x]"
            printf "  %d) %s %s\n" "$((i + 1))" "$mark" "${options[$i]}"
        done
        printf "\nToggle [1-%d] or hit Enter: " "$count"
        read -r choice

        if [ -z "$choice" ]; then
            # Return selected indices
            MULTI_RESULT=()
            for i in "${!selected[@]}"; do
                [ "${selected[$i]}" = "1" ] && MULTI_RESULT+=("$i")
            done
            return 0
        elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$count" ]; then
            local idx=$((choice - 1))
            if [ "${selected[$idx]}" = "1" ]; then
                selected[$idx]="0"
            else
                selected[$idx]="1"
            fi
            # Clear and redraw
            printf "\033[%dA\033[J" $((count + 2))
        fi
    done
}

config_builder_prompt_text() {
    local prompt="$1"
    local default="$2"

    if [ -n "$default" ]; then
        printf "%s [%s]: " "$prompt" "$default" >&2
    else
        printf "%s: " "$prompt" >&2
    fi
    read -r answer
    echo "${answer:-$default}"
}

# Offer to install shell completions
config_builder_install_completions() {
    local shell_name=""
    local install_path=""
    local completion_content=""

    # Detect shell
    if [ -n "$BASH_VERSION" ]; then
        shell_name="bash"
        install_path="$HOME/.local/share/bash-completion/completions/claude-cage"
    elif [ -n "$ZSH_VERSION" ]; then
        shell_name="zsh"
        install_path="$HOME/.zsh/completions/_claude-cage"
    else
        # Try to detect from $SHELL
        case "$SHELL" in
            */bash) shell_name="bash"; install_path="$HOME/.local/share/bash-completion/completions/claude-cage" ;;
            */zsh) shell_name="zsh"; install_path="$HOME/.zsh/completions/_claude-cage" ;;
        esac
    fi

    if [ -z "$shell_name" ]; then
        return 0  # Can't detect shell, skip
    fi

    # Check if already installed
    if [ -f "$install_path" ]; then
        return 0  # Already installed
    fi

    echo
    echo "Want tab-completion for claude-cage commands and flags?"
    if ! config_builder_prompt_yesno "Install $shell_name completions?" "y"; then
        return 0
    fi

    # Create directory
    mkdir -p "$(dirname "$install_path")"

    if [ "$shell_name" = "bash" ]; then
        cat > "$install_path" << 'BASH_WRAPPER'
# claude-cage bash completion (auto-generated wrapper)
# Loads completions dynamically from claude-cage
eval "$(claude-cage completion bash 2>/dev/null)"
BASH_WRAPPER
        echo "Installed to: $install_path"
        echo "Completions will be available in new bash sessions."

    elif [ "$shell_name" = "zsh" ]; then
        cat > "$install_path" << 'ZSH_WRAPPER'
#compdef claude-cage
# claude-cage zsh completion (auto-generated wrapper)
# Loads completions dynamically from claude-cage
eval "$(claude-cage completion zsh 2>/dev/null)"
ZSH_WRAPPER
        echo "Installed to: $install_path"

        # Check if fpath includes this directory
        local zshrc="$HOME/.zshrc"
        local fpath_line='fpath=(~/.zsh/completions $fpath)'
        if [ -f "$zshrc" ] && grep -q '\.zsh/completions' "$zshrc" 2>/dev/null; then
            echo "Completions will be available in new zsh sessions."
        else
            echo
            echo "Add this line to your ~/.zshrc (before compinit):"
            echo "  $fpath_line"
            echo
            if config_builder_prompt_yesno "Add it automatically?" "y"; then
                # Prepend to .zshrc so it's before any compinit
                if [ -f "$zshrc" ]; then
                    local tmp_zshrc
                    tmp_zshrc=$(mktemp)
                    echo "$fpath_line" > "$tmp_zshrc"
                    cat "$zshrc" >> "$tmp_zshrc"
                    mv "$tmp_zshrc" "$zshrc"
                else
                    echo "$fpath_line" > "$zshrc"
                fi
                echo "Added to ~/.zshrc"
            fi
            echo "Completions will be available in new zsh sessions."
        fi
    fi
}

config_builder_run() {
    local user_config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/claude-cage"
    local user_config="$user_config_dir/config"
    local project_config=".claude-cage"

    echo
    echo "═══════════════════════════════════════════════════════════════"
    echo "  No config found. Let's get you set up, friend."
    echo "═══════════════════════════════════════════════════════════════"
    echo

    # 1. Config location
    config_builder_prompt_choice "Where do you want me to save this thing?" \
        "$user_config (applies to all projects)" \
        "$project_config (this project only)"
    local config_location=$?
    local config_path="$user_config"
    [ $config_location -eq 1 ] && config_path="$project_config"

    echo

    # 2. Sandbox mode
    local mode_options=(
        "bwrap - Lightweight, Linux/WSL only"
        "docker - Works everywhere Docker runs"
    )
    config_builder_prompt_choice "How we runnin' this sandbox?" "${mode_options[@]}"
    local mode_choice=$?
    local mode="bwrap"
    [ $mode_choice -eq 1 ] && mode="docker"

    echo

    # 3. Common excludes
    local exclude_options=(
        ".env, .env.*"
        "secrets/, credentials/"
        "*.pem, *.key, *.p12"
        "application-*.properties (Spring Boot secrets)"
    )
    config_builder_prompt_multi "What should I keep outta the sandbox?" "${exclude_options[@]}"
    local exclude_patterns=()
    for idx in "${MULTI_RESULT[@]}"; do
        case $idx in
            0) exclude_patterns+=('".env"' '".env.*"') ;;
            1) exclude_patterns+=('"secrets/**"' '"credentials/**"') ;;
            2) exclude_patterns+=('"*.pem"' '"*.key"' '"*.p12"') ;;
            3) exclude_patterns+=('"application-*.properties"') ;;
        esac
    done

    echo

    # 4. Custom excludes
    if config_builder_prompt_yesno "Got any other patterns to exclude?" "n"; then
        echo "Gimme the patterns, comma-separated (e.g., 'private/**, *.secret'):"
        read -r custom_patterns
        if [ -n "$custom_patterns" ]; then
            IFS=',' read -ra customs <<< "$custom_patterns"
            for pattern in "${customs[@]}"; do
                pattern=$(echo "$pattern" | xargs)  # trim whitespace
                [ -n "$pattern" ] && exclude_patterns+=("\"$pattern\"")
            done
        fi
    fi

    echo

    # 5. Auto-merge
    echo "Auto-merge pushes your sandbox commits back to source in real-time."
    echo "Without it, you gotta run 'claude-cage git-merge' yourself."
    config_builder_prompt_yesno "Want auto-merge?" "y"
    local auto_merge=$?
    local auto_merge_str="false"
    [ $auto_merge -eq 0 ] && auto_merge_str="true"

    echo

    # 6. Allow non-git directories
    echo "Normally I work with git repos so I can sync changes back and forth."
    echo "But if you point me at a plain directory, I can still sandbox it - just no git magic."
    config_builder_prompt_yesno "Allow runnin' in non-git directories?" "y"
    local allow_non_git=$?
    local allow_non_git_str="false"
    [ $allow_non_git -eq 0 ] && allow_non_git_str="true"

    echo

    # 8. Caged directory symlinks
    echo "The .caged/ directory puts shortcuts to your sandbox branches right in your project."
    echo "Makes it easy to poke around and see what's happenin' in there."
    local create_caged_str="false"
    if config_builder_prompt_yesno "Create .caged/ shortcuts to your sandbox branches?" "n"; then
        create_caged_str="true"

        # Offer to add to root .gitignore
        local git_root
        git_root=$(git rev-parse --show-toplevel 2>/dev/null)
        if [ -n "$git_root" ]; then
            local gitignore="$git_root/.gitignore"
            if [ ! -f "$gitignore" ] || ! grep -q '^\.caged/\?$' "$gitignore" 2>/dev/null; then
                echo
                echo "The .caged/ directory has its own .gitignore, but addin' it to your"
                echo "project's .gitignore is extra insurance against accidentally committin' it."
                if config_builder_prompt_yesno "Add .caged/ to .gitignore?" "y"; then
                    echo ".caged/" >> "$gitignore"
                    echo "Added .caged/ to $gitignore"
                fi
            fi
        fi
    fi

    echo

    # 9. Launch command
    local launch_cmd
    launch_cmd=$(config_builder_prompt_text "What're we runnin' in there" "claude")

    echo

    # 10. Tool-specific mounts
    local additional_mounts=()
    if [ "$launch_cmd" = "claude" ]; then
        echo "Claude Code needs these mounted:"
        echo
        echo '    "~/.local/bin/claude",'
        echo '    "~/.gitconfig",'
        echo '    { source = "~/.claude", mode = "rw" },'
        echo '    { source = "~/.claude.json", mode = "rw" },'
        echo
        if config_builder_prompt_yesno "Add these mounts?" "y"; then
            # Check if ~/.claude and ~/.claude.json exist
            local claude_dir="$HOME/.claude"
            local claude_json="$HOME/.claude.json"
            local need_create=()

            [ ! -d "$claude_dir" ] && need_create+=("$claude_dir (directory)")
            [ ! -f "$claude_json" ] && need_create+=("$claude_json (file)")

            if [ ${#need_create[@]} -gt 0 ]; then
                echo
                echo "Hold on, these don't exist yet:"
                for item in "${need_create[@]}"; do
                    echo "  - $item"
                done
                if config_builder_prompt_yesno "Want me to create 'em?" "y"; then
                    [ ! -d "$claude_dir" ] && mkdir -p "$claude_dir" && echo "Created $claude_dir"
                    [ ! -f "$claude_json" ] && echo "{}" > "$claude_json" && echo "Created $claude_json"
                fi
            fi

            additional_mounts+=(
                '"~/.local/bin/claude"'
                '"~/.gitconfig"'
                '{ source = "~/.claude", mode = "rw" }'
                '{ source = "~/.claude.json", mode = "rw" }'
            )
        fi
        echo
    else
        # Not claude - offer just gitconfig
        if config_builder_prompt_yesno "Mount ~/.gitconfig? (read-only)" "y"; then
            additional_mounts+=('"~/.gitconfig"')
        fi
        echo
    fi

    # 11. Additional read-only mounts
    if config_builder_prompt_yesno "Any other read-only mounts you want mounted?" "n"; then
        echo "Gimme the paths, comma-separated:"
        read -r other_mounts
        if [ -n "$other_mounts" ]; then
            IFS=',' read -ra mounts <<< "$other_mounts"
            for mount in "${mounts[@]}"; do
                mount=$(echo "$mount" | xargs)  # trim
                [ -n "$mount" ] && additional_mounts+=("\"$mount\"")
            done
        fi
    fi

    echo

    # 12. Additional read-write mounts
    if config_builder_prompt_yesno "Any read-write mounts you need mounted?" "n"; then
        echo "Gimme the paths, comma-separated:"
        read -r rw_mounts
        if [ -n "$rw_mounts" ]; then
            IFS=',' read -ra mounts <<< "$rw_mounts"
            for mount in "${mounts[@]}"; do
                mount=$(echo "$mount" | xargs)  # trim
                [ -n "$mount" ] && additional_mounts+=("{ source = \"$mount\", mode = \"rw\" }")
            done
        fi
    fi

    echo

    # Build config content
    local config_content="claude_cage {"
    config_content+="\n    launch = \"$launch_cmd\","
    config_content+="\n    mode = \"$mode\","
    config_content+="\n    autoMerge = $auto_merge_str,"
    config_content+="\n    allowNonGit = $allow_non_git_str,"
    config_content+="\n    createCagedDir = $create_caged_str,"

    if [ ${#exclude_patterns[@]} -gt 0 ]; then
        local excludes_str
        excludes_str=$(IFS=', '; echo "${exclude_patterns[*]}")
        config_content+="\n    exclude = { $excludes_str },"
    fi

    if [ ${#additional_mounts[@]} -gt 0 ]; then
        config_content+="\n    additionalMounts = {"
        for mount in "${additional_mounts[@]}"; do
            config_content+="\n        $mount,"
        done
        config_content+="\n    },"
    fi

    # Remove trailing comma and close
    config_content="${config_content%,}"
    config_content+="\n}"

    echo "═══════════════════════════════════════════════════════════════"
    echo "  Here's what we got:"
    echo "═══════════════════════════════════════════════════════════════"
    echo
    echo -e "$config_content"
    echo

    if config_builder_prompt_yesno "Write this to $config_path?" "y"; then
        # Create directory if needed
        if [ $config_location -eq 0 ]; then
            mkdir -p "$user_config_dir"
        fi
        echo -e "$config_content" > "$config_path"
        echo
        echo "Saved to $config_path."

        # Offer to install shell completions
        config_builder_install_completions

        echo
        echo "You're good to go. Fire up claude-cage again when you're ready."
        return 0
    else
        echo "Alright, no config written. Come back when you're ready."
        return 1
    fi
}
