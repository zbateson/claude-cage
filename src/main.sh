# Guard: if we're being sourced just for function definitions, stop here
# This is used by run_with_network_namespace to get functions in subprocess
if [ "${CLAUDE_CAGE_SOURCING:-}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

# Handle --help and --version early (before config loading)
if [ "$show_help" = true ]; then
    show_help
    exit 0
fi

if [ "$show_version" = true ]; then
    echo "claude-cage $CLAUDE_CAGE_VERSION"
    exit 0
fi

# Handle completion subcommand early (doesn't need config)
if [ "${1:-}" = "completion" ]; then
    case "${2:-}" in
        bash) output_bash_completion; exit 0 ;;
        zsh) output_zsh_completion; exit 0 ;;
        *)
            echo "Usage: claude-cage completion [bash|zsh]"
            echo "Output shell completion script for the specified shell."
            exit 1
            ;;
    esac
fi

# Handle install-completions subcommand early (doesn't need config)
if [ "${1:-}" = "install-completions" ]; then
    config_builder_install_completions
    exit $?
fi

# Parse additional flags and subcommands
# Arguments we don't recognize get passed through to the launch command
test_mode=false
git_merge_mode=false
clean_mode=false
clean_all_mode=false
clean_branch=""
cli_direct_mount=false
passthrough_args=()
skip_next=false
for i in "$@"; do
    if [ "$skip_next" = true ]; then
        skip_next=false
        continue
    fi
    case "$i" in
        --test) test_mode=true ;;
        --direct-mount) cli_direct_mount=true ;;
        --dry-run) ;; # handled by helpers.sh
        --verbose|-v) ;; # handled by helpers.sh
        --debug) ;; # handled by helpers.sh
        git-merge) git_merge_mode=true ;;
        clean) clean_mode=true ;;
        clean-all) clean_all_mode=true ;;
        --branch)
            # Next arg is the branch name
            skip_next=true
            # Find the next argument
            found_next=false
            for j in "$@"; do
                if [ "$found_next" = true ]; then
                    clean_branch="$j"
                    break
                fi
                [ "$j" = "--branch" ] && found_next=true
            done
            ;;
        --branch=*) clean_branch="${i#--branch=}" ;;
        *) passthrough_args+=("$i") ;;
    esac
done

# Initialize and parse config
init_config "$@"

# Check for direct mount mode (CLI flag, config, or non-git directory)
direct_mount_mode=false

# Direct mount explicitly requested via CLI or config
if [ "$cli_direct_mount" = true ] || [ "$cfg_directMount" = "true" ]; then
    direct_mount_mode=true
# Not a git repo - check allowNonGit setting
elif ! is_git_repo "$cfg_source"; then
    case "$cfg_allowNonGit" in
        "true")
            direct_mount_mode=true
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
                if config_builder_prompt_yesno "Mount it directly and continue?" "y"; then
                    direct_mount_mode=true
                    echo ""
                    echo "To skip this prompt next time, add 'allowNonGit = true' to your config:"
                    echo "  /etc/claude-cage.conf           (system-wide)"
                    echo "  ~/.config/claude-cage/config    (user)"
                    echo ""
                else
                    echo "Alright, catch you later."
                    exit 0
                fi
            else
                echo "Run interactively to configure, or add allowNonGit = true to your config."
                exit 1
            fi
            ;;
    esac
fi

# Handle --git-merge early (doesn't need sandbox)
if [ "$git_merge_mode" = true ]; then
    if [ "$direct_mount_mode" = true ]; then
        echo "Can't do git-merge in direct mount mode. Nothin' to merge."
        exit 1
    fi
    manual_git_merge "$cfg_source"
    exit 0
fi

# Handle clean-all mode
if [ "$clean_all_mode" = true ]; then
    echo "This will remove ALL cached branches for: $cfg_source"
    echo ""

    cached_branches=$(list_cached_branches "$cfg_source")
    if [ -z "$cached_branches" ]; then
        echo "No cached branches found. Nothin' to clean."
        exit 0
    fi

    echo "Branches to be removed:"
    while IFS= read -r branch; do
        work_dir="$CLAUDE_CAGE_CACHE/branches/$branch/work$cfg_source"
        if is_work_dirty "$work_dir"; then
            echo -e "  $branch ${_yellow}(has uncommitted changes!)${_reset}"
        else
            echo "  $branch"
        fi
    done <<< "$cached_branches"
    echo ""

    if ! config_builder_prompt_yesno "Are you sure you want to delete all these?" "n"; then
        echo "Alright, nothin' deleted."
        exit 0
    fi

    while IFS= read -r branch; do
        echo ""
        echo "Cleaning branch: $branch"
        clean_branch_cache "$cfg_source" "$branch"
    done <<< "$cached_branches"

    # Clean up any stale state files
    clean_stale_state_files "$cfg_source"

    echo ""
    echo "All clean."
    exit 0
fi

# Handle clean mode (single branch)
if [ "$clean_mode" = true ]; then
    cached_branches=$(list_cached_branches "$cfg_source")
    if [ -z "$cached_branches" ]; then
        echo "No cached branches found. Nothin' to clean."
        exit 0
    fi

    # If branch specified, use it; otherwise prompt
    if [ -n "$clean_branch" ]; then
        # Sanitize the provided branch name
        clean_branch=$(sanitize_branch_name "$clean_branch")
        if ! echo "$cached_branches" | grep -qx "$clean_branch"; then
            echo "Branch '$clean_branch' not found in cache."
            echo ""
            echo "Available branches:"
            echo "$cached_branches" | sed 's/^/  /'
            exit 1
        fi
    else
        # Interactive selection
        echo "Which branch cache do you want to remove?"
        echo ""
        branch_array=()
        idx=1
        while IFS= read -r branch; do
            branch_array+=("$branch")
            work_dir="$CLAUDE_CAGE_CACHE/branches/$branch/work$cfg_source"
            if is_work_dirty "$work_dir"; then
                echo -e "  $idx) $branch ${_yellow}(has uncommitted changes!)${_reset}"
            else
                echo "  $idx) $branch"
            fi
            ((idx++))
        done <<< "$cached_branches"
        echo "  q) Cancel"
        echo ""

        while true; do
            printf "Choice: "
            read -r choice
            if [ "$choice" = "q" ] || [ "$choice" = "Q" ]; then
                echo "Alright, nothin' deleted."
                exit 0
            fi
            if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#branch_array[@]} ]; then
                clean_branch="${branch_array[$((choice-1))]}"
                break
            fi
            echo "Pick a number or 'q' to quit."
        done
    fi

    work_dir="$CLAUDE_CAGE_CACHE/branches/$clean_branch/work$cfg_source"

    echo ""
    echo "This will remove the cache for branch: $clean_branch"
    if is_work_dirty "$work_dir"; then
        echo ""
        echo -e "${_yellow}⚠️  WARNING: This branch has uncommitted changes that will be lost!${_reset}"
    fi
    echo ""

    if ! config_builder_prompt_yesno "Are you sure?" "n"; then
        echo "Alright, nothin' deleted."
        exit 0
    fi

    clean_branch_cache "$cfg_source" "$clean_branch"
    echo ""
    echo "Done. Branch '$clean_branch' cleaned up."
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

# Clean up any orphaned hooks from crashed sessions (git mode only)
if [ "$direct_mount_mode" = false ] && is_git_repo "$cfg_source"; then
    cleanup_orphaned_hooks "$cfg_source"
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
if [ "$direct_mount_mode" = false ]; then
    echo "  Auto-merge:    $cfg_autoMerge"
    echo "  Isolated:      $cfg_isolated"
fi
echo "  Network mode:  $cfg_networkMode"

if [ "$direct_mount_mode" = false ] && [ ${#cfg_display_lines[@]} -gt 0 ]; then
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

if [ "$direct_mount_mode" = true ]; then
    # Direct mount mode: mount source directory directly (no git sync)
    echo -e "${_cyan}Direct mount mode. Changes go straight to source.${_reset}"
    echo ""

    # Use source path directly - no intermediary or work dir needed
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

    # Check for other active sessions before doing anything destructive
    other_session_active=false
    if has_other_sessions "$cfg_source" "$source_branch"; then
        other_session_active=true
    fi

    # Register our session early (before any destructive operations)
    register_session "$cfg_source" "$source_branch"

    # Check if existing cage is in sync with source
    cage_state=$(check_cage_state "$cfg_source" "$work_dir" "$state_path")

    case "$cage_state" in
        "in_sync")
            echo "Cage is in sync with source. Pickin' up where we left off."
            ;;
        "ahead_clean")
            if [ "$other_session_active" = true ]; then
                echo "Source moved ahead, but another session's runnin'. Joinin' the existing cage."
            else
                echo "Source moved ahead but cage is clean. Startin' fresh."
                create_intermediary_clone "$cfg_source"
            fi
            ;;
        "ahead_dirty")
            if [ "$other_session_active" = true ]; then
                echo "Source moved ahead, but another session's runnin'. Joinin' the existing cage."
            else
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
            fi
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
        setup_source_post_commit "$cfg_source" "$cfg_exclude" "$intermediary_dir" "$source_branch" "$state_path" "$work_dir"
    fi
fi

# Pre-resolve domains for network filtering (so warnings appear before sandbox info)
pre_resolved_allow_ips=""
pre_resolved_block_ips=""
domains_pre_resolved=false
if [ "$cfg_networkMode" != "disabled" ] && [ -n "$cfg_networkMode" ]; then
    [ -n "$cfg_allow_domains" ] && pre_resolved_allow_ips=$(resolve_domains_for_docker "$cfg_allow_domains")
    [ -n "$cfg_block_domains" ] && pre_resolved_block_ips=$(resolve_domains_for_docker "$cfg_block_domains")
    domains_pre_resolved=true
fi

echo ""
echo "============================================"
echo ""
echo "Inside sandbox:"
echo "  $project_path              (working dir)"
if [ "$direct_mount_mode" = false ]; then
    echo "  /run$project_path          (git origin)"
fi
echo ""

# Start pipe listener if autoMerge enabled (git mode only)
if [ "$direct_mount_mode" = false ] && [ "$cfg_autoMerge" = "true" ]; then
    start_pipe_listener "$cfg_source" "$intermediary_dir" "$pipe_path" "$source_branch" "$state_path"
fi

# Set up cleanup handler for signals
cleanup_on_exit() {
    local exit_code=$?
    # Only run cleanup for git mode
    if [ "$direct_mount_mode" = false ]; then
        # Always unregister our session
        if [ -n "$source_branch" ]; then
            unregister_session "$cfg_source" "$source_branch"
        fi
        if [ -n "$PIPE_LISTENER_PID" ]; then
            stop_pipe_listener "$PIPE_LISTENER_PID"
            cleanup_pipe "$pipe_path"
        fi
        if [ "$cfg_autoMerge" = "true" ] && [ -n "$source_branch" ]; then
            cleanup_source_hooks "$cfg_source" "$source_branch"
        fi
    fi
    exit $exit_code
}
trap cleanup_on_exit EXIT INT TERM

# Determine what to run
if [ "$test_mode" = true ]; then
    # Test mode: drop into interactive shell
    launch_msg="Droppin' you into a shell for testing..."
    launch_cmd=""
else
    # Normal mode: run the configured launch command with any passthrough args
    if [ ${#passthrough_args[@]} -gt 0 ]; then
        launch_cmd="$cfg_launch ${passthrough_args[*]}"
        launch_msg="Launchin': $launch_cmd"
    else
        launch_cmd="$cfg_launch"
        launch_msg="Launchin': $cfg_launch"
    fi
fi

echo "$launch_msg"

if [ "$cfg_networkMode" != "disabled" ] && [ -n "$cfg_networkMode" ]; then
    echo "Network filtering enabled (mode: $cfg_networkMode)"
fi

# Show info messages last, right before entering sandbox
if [ "$direct_mount_mode" = true ]; then
    echo ""
    echo -e "${_cyan}⚠️  Direct mount: Changes are made directly to source files.${_reset}"
elif [ "$cfg_autoMerge" != "true" ]; then
    echo ""
    echo -e "${_cyan}⚠️  Auto-merge is OFF for this cage (branch: $source_branch).${_reset}"
    echo -e "${_cyan}   To bring changes back to source, run: ${_white}claude-cage git-merge${_reset}"
    echo -e "${_cyan}   (Must be run from branch '$source_branch')${_reset}"
fi

# Show host loopback info (mode-specific)
if [ "$cfg_mode" = "docker" ]; then
    echo ""
    echo -e "${_cyan}⚠️  Inside the sandbox, use host.docker.internal to reach host services${_reset}"
else
    echo ""
    echo -e "${_cyan}⚠️  Inside the sandbox, 10.0.2.2 maps to host 127.0.0.1${_reset}"
fi

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

# Cleanup is handled by the trap (cleanup_on_exit)
