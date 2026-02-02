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
    echo "(Toggle with number, Enter when done)"
    echo

    while true; do
        for i in "${!options[@]}"; do
            local mark="[ ]"
            [ "${selected[$i]}" = "1" ] && mark="[x]"
            printf "  %d) %s %s\n" "$((i + 1))" "$mark" "${options[$i]}"
        done
        printf "\nToggle [1-%d] or Enter to confirm: " "$count"
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
        printf "%s [%s]: " "$prompt" "$default"
    else
        printf "%s: " "$prompt"
    fi
    read -r answer
    echo "${answer:-$default}"
}

config_builder_run() {
    local user_config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/claude-cage"
    local user_config="$user_config_dir/config"
    local project_config=".claude-cage"

    echo
    echo "═══════════════════════════════════════════════════════════════"
    echo "  No config found. Let's get you set up."
    echo "═══════════════════════════════════════════════════════════════"
    echo

    # 1. Config location
    config_builder_prompt_choice "Where should I save the config?" \
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
    config_builder_prompt_choice "Sandbox mode:" "${mode_options[@]}"
    local mode_choice=$?
    local mode="bwrap"
    [ $mode_choice -eq 1 ] && mode="docker"

    echo

    # 3. Common excludes
    local exclude_options=(
        ".env, .env.*"
        "secrets/, credentials/"
        "*.pem, *.key, *.p12"
        ".git/config (may contain tokens)"
    )
    config_builder_prompt_multi "Common patterns to exclude from sandbox:" "${exclude_options[@]}"
    local exclude_patterns=()
    for idx in "${MULTI_RESULT[@]}"; do
        case $idx in
            0) exclude_patterns+=('".env"' '".env.*"') ;;
            1) exclude_patterns+=('"secrets/**"' '"credentials/**"') ;;
            2) exclude_patterns+=('"*.pem"' '"*.key"' '"*.p12"') ;;
            3) exclude_patterns+=('".git/config"') ;;
        esac
    done

    echo

    # 4. Custom excludes
    if config_builder_prompt_yesno "Add custom exclude patterns?" "n"; then
        echo "Enter patterns (comma-separated, e.g., 'private/**, *.secret'):"
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
    echo "Auto-merge syncs commits from sandbox to source in real-time."
    echo "Without it, you'll run 'claude-cage git-merge' manually."
    config_builder_prompt_yesno "Enable auto-merge?" "y"
    local auto_merge=$?
    local auto_merge_str="false"
    [ $auto_merge -eq 0 ] && auto_merge_str="true"

    echo

    # 6. Launch command
    echo "What command should run inside the sandbox?"
    local launch_cmd
    launch_cmd=$(config_builder_prompt_text "Launch command" "claude")

    echo

    # 7. Tool-specific mounts (Claude Code)
    local additional_mounts=()
    echo "Some AI coding tools need config directories mounted into the sandbox."
    echo
    if config_builder_prompt_yesno "Add Claude Code mounts? (~/.claude, ~/.claude.json)" "y"; then
        # Check if they exist
        local claude_dir="$HOME/.claude"
        local claude_json="$HOME/.claude.json"
        local need_create=()

        [ ! -d "$claude_dir" ] && need_create+=("$claude_dir (directory)")
        [ ! -f "$claude_json" ] && need_create+=("$claude_json (file)")

        if [ ${#need_create[@]} -gt 0 ]; then
            echo
            echo "These don't exist yet:"
            for item in "${need_create[@]}"; do
                echo "  - $item"
            done
            if config_builder_prompt_yesno "Create them now?" "y"; then
                [ ! -d "$claude_dir" ] && mkdir -p "$claude_dir" && echo "Created $claude_dir"
                [ ! -f "$claude_json" ] && echo "{}" > "$claude_json" && echo "Created $claude_json"
            fi
        fi

        additional_mounts+=(
            '{ source = "~/.claude", mode = "rw" }'
            '{ source = "~/.claude.json", mode = "rw" }'
        )
    fi

    echo

    # 8. Other tool mounts
    if config_builder_prompt_yesno "Add other read-only mounts? (e.g., ~/.gitconfig)" "n"; then
        echo "Enter paths (comma-separated):"
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

    # Build config content
    local config_content="claude_cage {"
    config_content+="\n    launch = \"$launch_cmd\","
    config_content+="\n    mode = \"$mode\","
    config_content+="\n    autoMerge = $auto_merge_str,"

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
    echo "  Config preview:"
    echo "═══════════════════════════════════════════════════════════════"
    echo
    echo -e "$config_content"
    echo

    if config_builder_prompt_yesno "Write this config to $config_path?" "y"; then
        # Create directory if needed
        if [ $config_location -eq 0 ]; then
            mkdir -p "$user_config_dir"
        fi
        echo -e "$config_content" > "$config_path"
        echo
        echo "Config saved to $config_path"
        echo "You're all set. Run claude-cage again to get started."
        return 0
    else
        echo "Alright, no config written. Come back when you're ready."
        return 1
    fi
}
