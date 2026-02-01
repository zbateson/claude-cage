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

# Handle --git-merge early (doesn't need sandbox)
if [ "$git_merge_mode" = true ]; then
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

# Display parsed config
echo "Configuration loaded from: $local_config"
echo ""
echo "  Project:       $cfg_project"
echo "  User:          $cfg_user"
echo "  Source:        $cfg_source"
echo "  Mounted as:    $cfg_mounted"
echo "  Mode:          $cfg_mode"
echo "  Auto-merge:    $cfg_autoMerge"
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

# Paths for bwrap/docker
intermediary_dir=$(get_cage_path "$cfg_source" "intermediary")
work_dir=$(get_cage_path "$cfg_source" "work")
pipe_path=$(get_pipe_path "$cfg_source")
state_path=$(get_state_path "$cfg_source")
project_path="$cfg_source"

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

# Set up git hooks and communication pipe (if autoMerge enabled)
if [ "$cfg_autoMerge" = "true" ]; then
    setup_git_hooks "$cfg_source" "$intermediary_dir" "$pipe_path"
    setup_source_pre_commit "$cfg_source" "$cfg_exclude" "$source_branch"
    setup_source_post_commit "$cfg_source" "$cfg_exclude" "$intermediary_dir" "$source_branch" "$state_path"
fi

echo ""
echo "============================================"
echo ""
echo "Inside sandbox:"
echo "  $project_path              (working dir)"
echo "  /run/claude-cage/intermediary  (git origin)"

if [ "$test_mode" = true ]; then
    echo ""

    # Start pipe listener if autoMerge enabled
    PIPE_LISTENER_PID=""
    if [ "$cfg_autoMerge" = "true" ]; then
        echo "Auto-merge enabled: pushes to intermediary will sync to source ($source_branch)"
        start_pipe_listener "$cfg_source" "$intermediary_dir" "$pipe_path" "$source_branch"
    fi

    if [ "$cfg_mode" = "docker" ]; then
        echo "Droppin' you into the Docker container for testing..."
        run_in_docker "$intermediary_dir" "$work_dir" "$pipe_path" "$project_path"
    else
        echo "Droppin' you into the bwrap sandbox for testing..."
        # Use network-isolated bwrap if network filtering is enabled
        if [ "$cfg_networkMode" != "disabled" ] && [ -n "$cfg_networkMode" ]; then
            echo "Network filtering enabled (mode: $cfg_networkMode)"
            run_in_bwrap_with_network "$intermediary_dir" "$work_dir" "$pipe_path" "$project_path"
        else
            run_in_bwrap "$intermediary_dir" "$work_dir" "$pipe_path" "$project_path"
        fi
    fi

    # Stop pipe listener and clean up hooks
    if [ -n "$PIPE_LISTENER_PID" ]; then
        stop_pipe_listener "$PIPE_LISTENER_PID"
        cleanup_pipe "$pipe_path"
    fi
    if [ "$cfg_autoMerge" = "true" ]; then
        cleanup_source_hooks "$cfg_source"
    fi
else
    echo ""
    echo "Use --test to drop into a shell for testing."
fi
