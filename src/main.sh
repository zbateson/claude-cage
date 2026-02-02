# Guard: if we're being sourced just for function definitions, stop here
# This is used by run_with_network_namespace to get functions in subprocess
if [ "${CLAUDE_CAGE_SOURCING:-}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

# Parse additional flags and subcommands
test_mode=false
git_merge_mode=false
for arg in "$@"; do
    case "$arg" in
        --test) test_mode=true ;;
        git-merge) git_merge_mode=true ;;
    esac
done

# Initialize and parse config
init_config "$@"

# Check if we're in a git repo
non_git_mode=false
if ! is_git_repo "$cfg_source"; then
    case "$cfg_allowNonGit" in
        "true")
            non_git_mode=true
            ;;
        "false")
            echo "Hold on there. This ain't a git repository."
            echo "And your config says allowNonGit = false."
            echo "Either initialize a git repo here, or change your config."
            exit 1
            ;;
        "unset"|*)
            echo "Hold on there. This ain't a git repository."
            echo "I can still sandbox it for you, but there won't be any git sync magic."
            echo ""
            if [ -t 0 ]; then
                if config_builder_prompt_yesno "Want me to remember this choice? (allowNonGit = true)" "y"; then
                    # Find the most appropriate config file to update
                    local_cfg=".claude-cage"
                    if [ -f "$local_cfg" ]; then
                        # Append to existing local config
                        echo "" >> "$local_cfg"
                        echo "claude_cage { allowNonGit = true }" >> "$local_cfg"
                        echo "Added allowNonGit = true to $local_cfg"
                    elif [ -f "$user_config" ]; then
                        # Append to user config
                        echo "" >> "$user_config"
                        echo "claude_cage { allowNonGit = true }" >> "$user_config"
                        echo "Added allowNonGit = true to $user_config"
                    else
                        # Create a local config
                        echo "claude_cage { allowNonGit = true }" > "$local_cfg"
                        echo "Created $local_cfg with allowNonGit = true"
                    fi
                    echo ""
                fi
                non_git_mode=true
            else
                echo "Run interactively to configure, or add allowNonGit = true to your config."
                exit 1
            fi
            ;;
    esac
fi

# Handle --git-merge early (doesn't need sandbox)
if [ "$git_merge_mode" = true ]; then
    if [ "$non_git_mode" = true ]; then
        echo "Can't do git-merge in a non-git directory. Nothin' to merge."
        exit 1
    fi
    manual_git_merge "$cfg_source"
    exit 0
fi

# Check isolation tool is available
if [ "$cfg_mode" = "docker" ]; then
    check_docker
else
    check_bwrap
    # Check slirp4netns and user namespaces if network filtering is enabled
    if [ "$cfg_networkMode" != "disabled" ] && [ -n "$cfg_networkMode" ]; then
        check_userns
        check_slirp4netns
        check_iptables
    fi
fi

# Show banner if enabled
if [ "$cfg_showBanner" = "true" ]; then
    print_banner
fi

# Display parsed config - show config sources
echo "Configuration loaded from:"
for cfg in "${config_files[@]}"; do
    if [ -f "$cfg" ]; then
        echo "  $cfg"
    fi
done
echo ""
echo "  Project:       $cfg_project"
echo "  Source:        $cfg_source"
echo "  Mode:          $cfg_mode"
echo "  Launch:        $cfg_launch"
echo "  Auto-merge:    $cfg_autoMerge"
echo "  Isolated:      $cfg_isolated"
echo "  Network mode:  $cfg_networkMode"

if [ ${#cfg_display_lines[@]} -gt 0 ]; then
    echo ""
    echo "Excludes by source:"
    for line in "${cfg_display_lines[@]}"; do
        IFS='|' read -r source patterns <<< "$line"
        echo "  [$source] $patterns"
    done
fi

if [ ${#cfg_mounts[@]} -gt 0 ]; then
    echo ""
    echo "Additional mounts:"
    for mount_entry in "${cfg_mounts[@]}"; do
        IFS='|' read -r mount_source mount_dest <<< "$mount_entry"
        if [ "$mount_source" = "$mount_dest" ]; then
            echo "  $mount_source"
        else
            echo "  $mount_source -> $mount_dest"
        fi
    done
fi

echo ""

# Set up paths and git-related state (or skip for non-git mode)
source_branch=""
PIPE_LISTENER_PID=""
intermediary_dir=""
work_dir=""
branch_work_root=""
branch_intermediary_root=""
pipe_path=""
state_path=""
project_path="$cfg_source"

if [ "$non_git_mode" = true ]; then
    # Non-git mode: mount source directory directly
    echo -e "${_cyan}Running in non-git mode. Changes go directly to source.${_reset}"
    echo ""

    # Use source path directly - no intermediary or work dir needed
    # We'll mount the parent directory containing the project
    work_dir="$cfg_source"
    branch_work_root=$(dirname "$cfg_source")

else
    # Git mode: full cage setup with intermediary and work directories

    # Capture source branch before creating intermediary (for sync targeting)
    source_branch=$(get_source_branch "$cfg_source")
    if [ -z "$source_branch" ]; then
        echo "Hold on. Can't figure out what branch you're on."
        echo "You need to be on a branch (not detached HEAD) for auto-merge to work."
        if [ "$cfg_autoMerge" = "true" ]; then
            echo "Either switch to a branch or disable autoMerge in your config."
            exit 1
        fi
    fi

    # Set branch for path construction
    CLAUDE_CAGE_BRANCH="$source_branch"
    export CLAUDE_CAGE_BRANCH

    # Check for pending patches from previous runs (interactive)
    pending_branches=$(list_pending_patch_branches "$cfg_source")
    if [ -n "$pending_branches" ]; then
        handle_pending_patches "$cfg_source"
        if [ "$PENDING_PATCHES_RESULT" = "quit" ]; then
            echo "Catch you later."
            exit 0
        fi
    fi

    # Paths for bwrap/docker
    intermediary_dir=$(get_cage_path "$cfg_source" "intermediary")
    work_dir=$(get_cage_path "$cfg_source" "work")
    branch_work_root=$(get_branch_work_root)
    branch_intermediary_root=$(get_branch_intermediary_root)
    pipe_path=$(get_pipe_path "$cfg_source")
    state_path=$(get_state_path "$cfg_source")

    # Check if existing cage is in sync with source
    cage_state=$(check_cage_state "$cfg_source" "$work_dir" "$state_path")

    case "$cage_state" in
        "in_sync")
            echo "Cage is in sync with source. Pickin' up where we left off."
            ;;
        "ahead_clean")
            echo "Source moved ahead but cage is clean. Startin' fresh."
            create_intermediary_clone "$cfg_source"
            ;;
        "ahead_dirty")
            handle_dirty_cage "$cfg_source" "$work_dir" "$intermediary_dir" "$state_path" "$cfg_exclude"
            case "$DIRTY_CAGE_RESULT" in
                "recreate")
                    create_intermediary_clone "$cfg_source"
                    ;;
                "exit")
                    echo "Alright, we'll sort this out later."
                    exit 0
                    ;;
                # "continue" - just proceed with existing cage
            esac
            ;;
        "no_cage"|*)
            # No existing cage, create fresh
            create_intermediary_clone "$cfg_source"
            ;;
    esac

    # Set up .caged/ symlinks if enabled
    if [ "$cfg_createCagedDir" = "true" ]; then
        setup_caged_symlinks "$cfg_source"
    fi

    # Set up git hooks and communication pipe (if autoMerge enabled)
    if [ "$cfg_autoMerge" = "true" ]; then
        setup_git_hooks "$cfg_source" "$intermediary_dir" "$pipe_path"
        setup_source_pre_commit "$cfg_source" "$cfg_exclude" "$source_branch"
        setup_source_post_commit "$cfg_source" "$cfg_exclude" "$intermediary_dir" "$source_branch" "$state_path"
    fi
fi

echo ""
echo "============================================"
echo ""
echo "Inside sandbox:"
echo "  $project_path              (working dir)"
if [ "$non_git_mode" = false ]; then
    echo "  /run$project_path          (git origin)"
fi
echo ""

# Start pipe listener if autoMerge enabled (git mode only)
if [ "$non_git_mode" = false ] && [ "$cfg_autoMerge" = "true" ]; then
    start_pipe_listener "$cfg_source" "$intermediary_dir" "$pipe_path" "$source_branch"
fi

# Determine what to run
if [ "$test_mode" = true ]; then
    # Test mode: drop into interactive shell
    launch_msg="Droppin' you into a shell for testing..."
    launch_cmd=""
else
    # Normal mode: run the configured launch command
    launch_msg="Launchin': $cfg_launch"
    launch_cmd="$cfg_launch"
fi

echo "$launch_msg"

if [ "$cfg_networkMode" != "disabled" ] && [ -n "$cfg_networkMode" ]; then
    echo "Network filtering enabled (mode: $cfg_networkMode)"
fi

# Show info messages last, right before entering sandbox
if [ "$non_git_mode" = true ]; then
    echo ""
    echo -e "${_cyan}⚠️  Non-git mode: Changes are made directly to source files.${_reset}"
elif [ "$cfg_autoMerge" != "true" ]; then
    echo ""
    echo -e "${_cyan}⚠️  Auto-merge is OFF for this cage (branch: $source_branch).${_reset}"
    echo -e "${_cyan}   To bring changes back to source, run: ${_white}claude-cage git-merge${_reset}"
    echo -e "${_cyan}   (Must be run from branch '$source_branch')${_reset}"
fi

echo ""
echo -e "${_cyan}⚠️  Inside the sandbox, 10.0.2.2 maps to host 127.0.0.1${_reset}"

# Show confirmation prompt (unless hidden)
if [ "$cfg_hideConfirmationPrompt" != "true" ]; then
    echo ""
    echo "To skip this prompt, set hideConfirmationPrompt = true in your config."
    read -n 1 -s -r -p "Press any key to continue..." </dev/tty || true
    echo ""
fi

if [ "$cfg_mode" = "docker" ]; then
    run_in_docker "$branch_intermediary_root" "$branch_work_root" "$intermediary_dir" "$work_dir" "$pipe_path" "$project_path" $launch_cmd
else
    # Use network-isolated bwrap if network filtering is enabled
    if [ "$cfg_networkMode" != "disabled" ] && [ -n "$cfg_networkMode" ]; then
        run_in_bwrap_with_network "$branch_intermediary_root" "$branch_work_root" "$intermediary_dir" "$work_dir" "$pipe_path" "$project_path" $launch_cmd
    else
        run_in_bwrap "$branch_intermediary_root" "$branch_work_root" "$intermediary_dir" "$work_dir" "$pipe_path" "$project_path" $launch_cmd
    fi
fi

# Stop pipe listener and clean up hooks (git mode only)
if [ "$non_git_mode" = false ]; then
    if [ -n "$PIPE_LISTENER_PID" ]; then
        stop_pipe_listener "$PIPE_LISTENER_PID"
        cleanup_pipe "$pipe_path"
    fi
    if [ "$cfg_autoMerge" = "true" ]; then
        cleanup_source_hooks "$cfg_source" "$source_branch"
    fi
fi
