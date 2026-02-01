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

# Create the intermediary clone and work directory
create_intermediary_clone "$cfg_source"

# Paths for bwrap/docker
caged_dir="$cfg_source/.caged"
project_path="$cfg_source"

# Set up git hooks and communication pipe (if autoMerge enabled)
if [ "$cfg_autoMerge" = "true" ]; then
    setup_git_hooks "$caged_dir" "$project_path"
    setup_source_post_commit "$cfg_source" "$cfg_exclude"
fi

echo ""
echo "============================================"
echo ""
echo "Sandbox mount:"
echo "  $caged_dir"
echo "    -> $project_path/"
echo ""
echo "Inside sandbox:"
echo "  $project_path/intermediary/  (git origin)"
echo "  $project_path/work/          (working dir)"

if [ "$test_mode" = true ]; then
    echo ""

    # Start pipe listener if autoMerge enabled
    listener_pid=""
    if [ "$cfg_autoMerge" = "true" ]; then
        echo "Auto-merge enabled: pushes to intermediary will sync to source"
        listener_pid=$(start_pipe_listener "$cfg_source" "$caged_dir")
    fi

    if [ "$cfg_mode" = "docker" ]; then
        echo "Droppin' you into the Docker container for testing..."
        run_in_docker "$caged_dir" "$project_path"
    else
        echo "Droppin' you into the bwrap sandbox for testing..."
        run_in_bwrap "$caged_dir" "$project_path"
    fi

    # Stop pipe listener
    if [ -n "$listener_pid" ]; then
        stop_pipe_listener "$listener_pid"
        cleanup_pipe "$caged_dir"
    fi
else
    echo ""
    echo "Use --test to drop into a shell for testing."
fi
