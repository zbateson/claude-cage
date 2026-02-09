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
clean_all=false
cli_direct_mount=false
cli_scoped=false
cli_attach_session=""
cli_attach_session_mode=false
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
        --scoped) cli_scoped=true ;;
        --dry-run) ;; # handled by helpers.sh
        --verbose|-v) ;; # handled by helpers.sh
        --debug) ;; # handled by helpers.sh
        git-merge) git_merge_mode=true ;;
        clean) clean_mode=true ;;
        --all) clean_all=true ;;
        --attach-session)
            cli_attach_session_mode=true
            # Check if next arg looks like a timestamp (not a flag)
            skip_next=false
            found_next=false
            for j in "$@"; do
                if [ "$found_next" = true ]; then
                    if [[ "$j" =~ ^[0-9]{14}$ ]]; then
                        cli_attach_session="$j"
                        skip_next=true
                    fi
                    break
                fi
                [ "$j" = "--attach-session" ] && found_next=true
            done
            ;;
        --attach-session=*) cli_attach_session_mode=true; cli_attach_session="${i#--attach-session=}" ;;
        *) passthrough_args+=("$i") ;;
    esac
done

# If in clean mode, treat passthrough args as session IDs
clean_sessions=()
if [ "$clean_mode" = true ] && [ ${#passthrough_args[@]} -gt 0 ]; then
    clean_sessions=("${passthrough_args[@]}")
    passthrough_args=()
fi

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

# Compute scope_path early for commands that need it before main orchestration
scope_path=""
if [ "$cli_scoped" = true ] || [ "$cfg_git_scoped" = "true" ]; then
    scope_path=$(get_scope_path "$cfg_source")
fi

# Block --scoped when a broader intermediary already covers this scope
if [ -n "$scope_path" ] && check_broader_intermediary_exists "$cfg_source" "$scope_path"; then
    echo "Hold on. There's already a cage set up that covers this directory."
    echo "No need for --scoped — just run claude-cage from here without it."
    echo "Claude'll start focused in this directory automatically."
    exit 1
fi

# Handle --git-merge early (doesn't need sandbox)
if [ "$git_merge_mode" = true ]; then
    if [ "$direct_mount_mode" = true ]; then
        echo "Can't do git-merge in direct mount mode. Nothin' to merge."
        exit 1
    fi
    manual_git_merge "$cfg_source" "$scope_path"
    exit 0
fi

# Handle clean mode
if [ "$clean_mode" = true ]; then
    cached_sessions=$(list_cached_sessions "$cfg_source")
    if [ -z "$cached_sessions" ]; then
        echo "No cached sessions found. Nothin' to clean."
        exit 0
    fi

    # Build session arrays from cached_sessions for lookups
    session_array=()
    session_sources=()
    while IFS=' ' read -r sid sbranch ssource sscope; do
        session_array+=("$sid")
        session_sources+=("$ssource")
    done <<< "$cached_sessions"

    if [ "$clean_all" = true ]; then
        # --all: remove all sessions
        echo "This will remove ALL cached sessions for: $cfg_source"
        echo ""
        echo "Sessions to be removed:"
        while IFS=' ' read -r sid sbranch ssource sscope; do
            work_dir="$CLAUDE_CAGE_CACHE/sessions/$sid/work$ssource"
            scope_label=""
            [ -n "$sscope" ] && scope_label=" ${_cyan}(scoped: $sscope)${_reset}"
            if is_work_dirty "$work_dir"; then
                echo -e "  $sid  branch: $sbranch${scope_label} ${_yellow}(has uncommitted changes!)${_reset}"
            else
                echo -e "  $sid  branch: $sbranch${scope_label}"
            fi
        done <<< "$cached_sessions"
        echo ""

        if ! config_builder_prompt_yesno "Are you sure you want to delete all these?" "n"; then
            echo "Alright, nothin' deleted."
            exit 0
        fi

        while IFS=' ' read -r sid sbranch ssource sscope; do
            echo ""
            echo "Cleaning session: $sid"
            clean_session_cache "$ssource" "$sid"
        done <<< "$cached_sessions"

        echo ""
        echo "All clean."
        exit 0

    elif [ ${#clean_sessions[@]} -gt 0 ]; then
        # Session IDs specified as positional args
        # Validate all IDs first
        for csid in "${clean_sessions[@]}"; do
            if ! echo "$cached_sessions" | grep -q "^$csid "; then
                echo "Session '$csid' not found in cache."
                echo ""
                echo "Available sessions:"
                while IFS=' ' read -r sid sbranch ssource sscope; do
                    scope_label=""
                    [ -n "$sscope" ] && scope_label=" ${_cyan}(scoped: $sscope)${_reset}"
                    echo -e "  $sid  branch: $sbranch${scope_label}"
                done <<< "$cached_sessions"
                exit 1
            fi
        done

        if [ ${#clean_sessions[@]} -eq 1 ]; then
            # Single session: show details and confirm
            csid="${clean_sessions[0]}"
            # Look up source for this session
            clean_source="$cfg_source"
            for _ci in "${!session_array[@]}"; do
                if [ "${session_array[$_ci]}" = "$csid" ]; then
                    clean_source="${session_sources[$_ci]}"
                    break
                fi
            done

            work_dir="$CLAUDE_CAGE_CACHE/sessions/$csid/work$clean_source"
            echo ""
            echo "This will remove the cache for session: $csid"
            if is_work_dirty "$work_dir"; then
                echo ""
                echo -e "${_yellow}⚠️  WARNING: This session has uncommitted changes that will be lost!${_reset}"
            fi
            echo ""

            if ! config_builder_prompt_yesno "Are you sure?" "n"; then
                echo "Alright, nothin' deleted."
                exit 0
            fi

            clean_session_cache "$clean_source" "$csid"
            echo ""
            echo "Done. Session '$csid' cleaned up."
        else
            # Multiple sessions: show list and single confirm
            echo ""
            echo "Sessions to be removed:"
            for csid in "${clean_sessions[@]}"; do
                clean_source="$cfg_source"
                for _ci in "${!session_array[@]}"; do
                    if [ "${session_array[$_ci]}" = "$csid" ]; then
                        clean_source="${session_sources[$_ci]}"
                        break
                    fi
                done
                work_dir="$CLAUDE_CAGE_CACHE/sessions/$csid/work$clean_source"
                _sbranch=$(echo "$cached_sessions" | awk -v sid="$csid" '$1 == sid { print $2; exit }')
                _sscope=$(echo "$cached_sessions" | awk -v sid="$csid" '$1 == sid { print $4; exit }')
                scope_label=""
                [ -n "$_sscope" ] && scope_label=" ${_cyan}(scoped: $_sscope)${_reset}"
                if is_work_dirty "$work_dir"; then
                    echo -e "  $csid  branch: $_sbranch${scope_label} ${_yellow}(has uncommitted changes!)${_reset}"
                else
                    echo -e "  $csid  branch: $_sbranch${scope_label}"
                fi
            done
            echo ""

            if ! config_builder_prompt_yesno "Are you sure you want to delete these?" "n"; then
                echo "Alright, nothin' deleted."
                exit 0
            fi

            for csid in "${clean_sessions[@]}"; do
                clean_source="$cfg_source"
                for _ci in "${!session_array[@]}"; do
                    if [ "${session_array[$_ci]}" = "$csid" ]; then
                        clean_source="${session_sources[$_ci]}"
                        break
                    fi
                done
                echo ""
                echo "Cleaning session: $csid"
                clean_session_cache "$clean_source" "$csid"
            done

            echo ""
            echo "All clean."
        fi
        exit 0

    else
        # Interactive selection
        echo "Which session cache do you want to remove?"
        echo ""
        idx=1
        while IFS=' ' read -r sid sbranch ssource sscope; do
            work_dir="$CLAUDE_CAGE_CACHE/sessions/$sid/work$ssource"
            scope_label=""
            [ -n "$sscope" ] && scope_label=" ${_cyan}(scoped: $sscope)${_reset}"
            if is_work_dirty "$work_dir"; then
                echo -e "  $idx) $sid  branch: $sbranch${scope_label} ${_yellow}(has uncommitted changes!)${_reset}"
            else
                echo -e "  $idx) $sid  branch: $sbranch${scope_label}"
            fi
            idx=$((idx + 1))
        done <<< "$cached_sessions"
        echo "  a) Remove all sessions"
        echo "  q) Cancel"
        echo ""

        while true; do
            printf "Choice: "
            read -r choice
            if [ "$choice" = "q" ] || [ "$choice" = "Q" ]; then
                echo "Alright, nothin' deleted."
                exit 0
            fi
            if [ "$choice" = "a" ] || [ "$choice" = "A" ] || [ "$choice" = "all" ]; then
                # Confirm and delete all
                echo ""
                if ! config_builder_prompt_yesno "Are you sure you want to delete all sessions?" "n"; then
                    echo "Alright, nothin' deleted."
                    exit 0
                fi
                while IFS=' ' read -r sid sbranch ssource sscope; do
                    echo ""
                    echo "Cleaning session: $sid"
                    clean_session_cache "$ssource" "$sid"
                done <<< "$cached_sessions"
                echo ""
                echo "All clean."
                exit 0
            fi
            if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#session_array[@]} ]; then
                selected_session="${session_array[$((choice-1))]}"
                selected_source="${session_sources[$((choice-1))]}"
                work_dir="$CLAUDE_CAGE_CACHE/sessions/$selected_session/work$selected_source"

                echo ""
                echo "This will remove the cache for session: $selected_session"
                if is_work_dirty "$work_dir"; then
                    echo ""
                    echo -e "${_yellow}⚠️  WARNING: This session has uncommitted changes that will be lost!${_reset}"
                fi
                echo ""

                if ! config_builder_prompt_yesno "Are you sure?" "n"; then
                    echo "Alright, nothin' deleted."
                    exit 0
                fi

                clean_session_cache "$selected_source" "$selected_session"
                echo ""
                echo "Done. Session '$selected_session' cleaned up."
                exit 0
            fi
            echo "Pick a number, 'a' to remove all, or 'q' to quit."
        done
    fi
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
    repos_list_clean_orphans "$cfg_source" 2>/dev/null || true
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
# Validate launch command against known-safe launchers
_known_launchers="claude aider goose cline continue codex copilot"
_launch_basename=$(basename "${cfg_launch%% *}")
_launch_recognized=false
for _launcher in $_known_launchers; do
    if [ "$_launch_basename" = "$_launcher" ]; then
        _launch_recognized=true
        break
    fi
done
if [ "$_launch_recognized" = true ]; then
    echo "  Launch:        $cfg_launch"
else
    echo -e "  Launch:        ${_red}$cfg_launch${_reset}  ⚠️  unrecognized launch command"
fi
if [ "$direct_mount_mode" = false ]; then
    echo "  Auto-sync:     $cfg_autoSync"
    echo "  Isolated:      $cfg_isolated"
    if [ -n "$scope_path" ]; then
        echo "  Scoped to:     $scope_path"
    fi
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
session_work_root=""
intermediary_root=""
pipe_path=""
project_path="$cfg_source"

if [ "$direct_mount_mode" = true ]; then
    # Direct mount mode: mount source directory directly (no git sync)
    echo -e "${_cyan}Direct mount mode. Changes go straight to source.${_reset}"
    echo ""

    # Use source path directly - no intermediary or work dir needed
    work_dir="$cfg_source"
    session_work_root=$(dirname "$cfg_source")

else
    # Git mode: full cage setup with intermediary and work directories

    # Capture source branch before creating intermediary (for sync targeting)
    source_branch=$(get_source_branch "$cfg_source")
    if [ -z "$source_branch" ]; then
        echo "Hold on. Can't figure out what branch you're on."
        echo "You need to be on a branch (not detached HEAD) for auto-sync to work."
        if [ "$cfg_autoSync" = "true" ]; then
            echo "Either switch to a branch or disable autoSync in your config."
            exit 1
        fi
    fi

    # Check for pending patches from previous runs (interactive)
    pending_branches=$(list_pending_patch_branches "$cfg_source")
    if [ -n "$pending_branches" ]; then
        handle_pending_patches "$cfg_source"
        if [ "$PENDING_PATCHES_RESULT" = "quit" ]; then
            echo "Catch you later."
            exit 0
        fi
    fi

    intermediary_dir=$(get_scoped_intermediary_path "$cfg_source" "$scope_path")
    intermediary_root=$(get_intermediary_root)

    # Session selection flow: find reusable sessions, handle --attach-session
    find_reusable_session "$cfg_source"

    if [ "$cli_attach_session_mode" = true ]; then
        # --attach-session mode
        if [ -n "$cli_attach_session" ]; then
            # --attach-session <ts>: target specific session, must be active
            if ! session_is_active "$cfg_source" "$cli_attach_session"; then
                echo "Session $cli_attach_session ain't active. Use without a timestamp to pick up an inactive session."
                exit 1
            fi
            CLAUDE_CAGE_SESSION="$cli_attach_session"
            echo "Attachin' to session $cli_attach_session."
        else
            # --attach-session (no arg): auto-select or prompt
            active_count=0
            if [ -n "$REUSE_ACTIVE_SESSIONS" ]; then
                active_count=$(echo "$REUSE_ACTIVE_SESSIONS" | wc -l)
            fi

            if [ "$active_count" -eq 0 ]; then
                echo "No active sessions found to attach to."
                exit 1
            elif [ "$active_count" -eq 1 ]; then
                read -r asid abranch asource ascope <<< "$REUSE_ACTIVE_SESSIONS"
                CLAUDE_CAGE_SESSION="$asid"
                scope_label=""
                [ -n "$ascope" ] && scope_label=" (scoped: $ascope)"
                echo "Attachin' to session $asid on branch '$abranch'${scope_label}."
            else
                echo "Multiple active sessions found:"
                echo ""
                attach_ids=()
                aidx=1
                while IFS=' ' read -r asid abranch asource ascope; do
                    attach_ids+=("$asid")
                    scope_label=""
                    [ -n "$ascope" ] && scope_label=" ${_cyan}(scoped: $ascope)${_reset}"
                    echo -e "  $aidx) $asid  branch: $abranch${scope_label}"
                    ((aidx++))
                done <<< "$REUSE_ACTIVE_SESSIONS"
                echo ""

                while true; do
                    printf "Which session do you wanna attach to? "
                    read -r choice
                    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#attach_ids[@]} ]; then
                        CLAUDE_CAGE_SESSION="${attach_ids[$((choice-1))]}"
                        break
                    fi
                    echo "Pick a number."
                done
            fi
        fi
    else
        # Default mode (no --attach-session)
        case "$REUSE_SESSION_STATE" in
            "active")
                # Another session is running - create a fresh one alongside it
                echo "Another session's runnin' ($REUSE_SESSION_ID). Firin' up a fresh one alongside it."
                reuse_or_create_session "$cfg_source"
                ;;
            "clean")
                # Inactive clean session - reuse same-source only (handled by reuse_or_create_session)
                reuse_or_create_session "$cfg_source"
                ;;
            "dirty")
                # Inactive dirty session(s) - prompt
                dirty_count=0
                if [ -n "$REUSE_DIRTY_SESSIONS" ]; then
                    dirty_count=$(echo "$REUSE_DIRTY_SESSIONS" | wc -l)
                fi

                if [ "$dirty_count" -le 1 ]; then
                    # Single dirty session
                    dtype=$(echo "$REUSE_DIRTY_SESSIONS" | head -1 | awk '{print $3}')
                    dirty_desc="uncommitted changes"
                    case "$dtype" in
                        unpushed) dirty_desc="unpushed commits" ;;
                        uncommitted+unpushed) dirty_desc="uncommitted changes and unpushed commits" ;;
                    esac
                    scope_label=""
                    [ -n "$REUSE_SESSION_SCOPE" ] && scope_label=" (scoped: $REUSE_SESSION_SCOPE)"
                    echo "Found an existing cage ($REUSE_SESSION_ID) on branch '$REUSE_SESSION_BRANCH'${scope_label}."
                    echo "  It's got $dirty_desc."
                    echo ""
                    echo "What do you wanna do?"
                    echo "  1) Pick it up (cage stays on branch '$REUSE_SESSION_BRANCH')"
                    echo "  2) Start fresh (new session)"
                    echo "  q) Quit"
                    echo ""
                    echo "  Tip: run 'claude-cage clean' to clean up dirty sessions."
                    echo ""
                    while true; do
                        printf "Choice: "
                        read -r choice
                        case "$choice" in
                            1)
                                CLAUDE_CAGE_SESSION="$REUSE_SESSION_ID"
                                # Cross-scope override
                                if [ "$REUSE_SESSION_SOURCE" != "$cfg_source" ]; then
                                    cfg_source="$REUSE_SESSION_SOURCE"
                                    scope_path="${REUSE_SESSION_SCOPE:-}"
                                    intermediary_dir=$(get_scoped_intermediary_path "$cfg_source" "$scope_path")
                                fi
                                break
                                ;;
                            2)
                                reuse_or_create_session "$cfg_source"
                                break
                                ;;
                            q|Q) echo "Catch you later."; exit 0 ;;
                            *) echo "Pick 1, 2, or q." ;;
                        esac
                    done
                else
                    # Multiple dirty sessions - show all
                    echo "Found $dirty_count existing cages with uncommitted work:"
                    echo ""
                    dirty_entries=()
                    dirty_ids=()
                    didx=1
                    while IFS=' ' read -r dsid dbranch dtype dsource dscope; do
                        dirty_entries+=("$dsid $dbranch $dtype $dsource $dscope")
                        dirty_ids+=("$dsid")
                        dirty_label="uncommitted changes"
                        case "$dtype" in
                            unpushed) dirty_label="unpushed commits" ;;
                            uncommitted+unpushed) dirty_label="uncommitted changes + unpushed commits" ;;
                        esac
                        scope_label=""
                        [ -n "$dscope" ] && scope_label=" ${_cyan}(scoped: $dscope)${_reset}"
                        printf "  %d) %s  branch: %-20s (%s)%b\n" "$didx" "$dsid" "$dbranch" "$dirty_label" "$scope_label"
                        ((didx++))
                    done <<< "$REUSE_DIRTY_SESSIONS"
                    echo ""
                    echo "What do you wanna do?"
                    echo "  Pick a number to continue that session, or:"
                    echo "  n) Start fresh (new session)"
                    echo "  q) Quit"
                    echo ""
                    echo "  Tip: run 'claude-cage clean' to clean up dirty sessions."
                    echo ""
                    while true; do
                        printf "Choice: "
                        read -r choice
                        case "$choice" in
                            n|N)
                                reuse_or_create_session "$cfg_source"
                                break
                                ;;
                            q|Q) echo "Catch you later."; exit 0 ;;
                            *)
                                if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#dirty_ids[@]} ]; then
                                    CLAUDE_CAGE_SESSION="${dirty_ids[$((choice-1))]}"
                                    # Cross-scope override from the selected entry
                                    local _sel_sid _sel_branch _sel_dtype _sel_source _sel_scope
                                    read -r _sel_sid _sel_branch _sel_dtype _sel_source _sel_scope \
                                        <<< "${dirty_entries[$((choice-1))]}"
                                    if [ "$_sel_source" != "$cfg_source" ]; then
                                        cfg_source="$_sel_source"
                                        scope_path="${_sel_scope:-}"
                                        intermediary_dir=$(get_scoped_intermediary_path "$cfg_source" "$scope_path")
                                    fi
                                    break
                                fi
                                echo "Pick a number, n, or q."
                                ;;
                        esac
                    done
                fi
                ;;
            "none"|*)
                # No existing session - create fresh
                reuse_or_create_session "$cfg_source"
                ;;
        esac
    fi

    export CLAUDE_CAGE_SESSION

    # Clean up inactive clean sessions we're not using
    cleanup_stale_sessions "$cfg_source"

    # Now compute paths using the selected session
    work_dir=$(get_work_path "$cfg_source")
    session_work_root=$(get_session_work_root)
    pipe_path=$(get_pipe_path "$cfg_source")

    # Check for other active sessions before doing anything destructive
    other_session_active=false
    if has_other_sessions "$cfg_source"; then
        other_session_active=true
    fi

    # Register our session early (before any destructive operations)
    register_session "$cfg_source"

    # Check if existing cage is in sync with source
    cage_state=$(check_cage_state "$cfg_source" "$intermediary_dir" "$work_dir")

    case "$cage_state" in
        "in_sync")
            echo "Pickin' up where we left off."
            # Current branch is in sync, but other branches may have new commits
            if catchup_intermediary_branches "$cfg_source" "$intermediary_dir"; then
                # Branches were updated - refresh work dir's remote-tracking refs
                git -C "$work_dir" fetch "$intermediary_dir" '+refs/heads/*:refs/remotes/origin/*' --quiet 2>/dev/null || true
            fi
            ;;
        "needs_work_dir")
            if [ "$other_session_active" = true ] && [ "$cli_attach_session_mode" = true ]; then
                echo "Attachin' to active session's workspace."
            else
                echo "Intermediary exists but work dir is gone. Rebuildin' workspace..."
                create_intermediary_clone "$cfg_source" "$scope_path"
            fi
            ;;
        "needs_update")
            if [ "$other_session_active" = true ]; then
                echo "Source moved ahead, but another session's runnin'. Joinin' the existing cage."
            else
                echo "Source moved ahead. Catchin' up..."
                create_intermediary_clone "$cfg_source" "$scope_path"
            fi
            ;;
        "no_cage"|*)
            # No existing cage, create fresh
            create_intermediary_clone "$cfg_source" "$scope_path"
            ;;
    esac

    # Set up .caged/ symlinks if enabled
    if [ "$cfg_createCagedDir" = "true" ]; then
        setup_caged_symlinks "$cfg_source" "$scope_path"
    fi

    # Set up git hooks and communication pipe (if autoSync enabled)
    if [ "$cfg_autoSync" = "true" ]; then
        setup_git_hooks "$cfg_source" "$intermediary_dir" "$pipe_path"
        setup_source_post_commit "$cfg_source" "$cfg_exclude" "$intermediary_dir"
        setup_source_post_merge "$cfg_source" "$cfg_exclude" "$intermediary_dir"
    fi

    # Set up work repo pre-commit hook:
    # - Block merges in scoped intermediaries (unreliable without full tree)
    # - Block force-added ignored files if configured (default: true)
    if [ "$cfg_git_blockForceAdd" = "true" ] || [ -n "$scope_path" ]; then
        setup_work_pre_commit "$work_dir" "$scope_path"
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
    echo "  /run$intermediary_dir      (git origin)"
fi
echo ""

# Start pipe listener if autoSync enabled (git mode only)
if [ "$direct_mount_mode" = false ] && [ "$cfg_autoSync" = "true" ]; then
    start_pipe_listener "$cfg_source" "$intermediary_dir" "$pipe_path" "$verbose"
fi

# Set up cleanup handler for signals
cleanup_on_exit() {
    local exit_code=$?
    # Only run cleanup for git mode
    if [ "$direct_mount_mode" = false ]; then
        # Always unregister our session
        unregister_session "$cfg_source"
        # Deferred cleanup: if this scoped intermediary is now superseded
        if [ -n "${scope_path:-}" ]; then
            maybe_cleanup_superseded_intermediary "$cfg_source" "$scope_path"
        fi
        if [ -n "$PIPE_LISTENER_PID" ]; then
            stop_pipe_listener "$PIPE_LISTENER_PID"
            cleanup_pipe "$pipe_path"
        fi
        if [ "$cfg_autoSync" = "true" ]; then
            cleanup_source_hooks "$cfg_source"
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
# Docker mode prints these from inside the container (after package installs)
if [ "$cfg_mode" != "docker" ]; then
    if [ "$direct_mount_mode" = true ]; then
        echo ""
        echo -e "${_cyan}⚠️  Direct mount: Changes are made directly to source files.${_reset}"
    elif [ "$cfg_autoSync" != "true" ]; then
        echo ""
        echo -e "${_cyan}⚠️  Auto-sync is OFF for this cage (branch: $source_branch).${_reset}"
        echo -e "${_cyan}   To bring changes back to source, run: ${_white}claude-cage git-merge${_reset}"
        echo -e "${_cyan}   (Must be run from branch '$source_branch')${_reset}"
    fi

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
    run_in_docker "$intermediary_root" "$session_work_root" "$intermediary_dir" "$work_dir" "$pipe_path" "$project_path" $launch_cmd
else
    # Use network-isolated bwrap if network filtering is enabled
    if [ "$cfg_networkMode" != "disabled" ] && [ -n "$cfg_networkMode" ]; then
        run_in_bwrap_with_network "$intermediary_root" "$session_work_root" "$intermediary_dir" "$work_dir" "$pipe_path" "$project_path" $launch_cmd
    else
        run_in_bwrap "$intermediary_root" "$session_work_root" "$intermediary_dir" "$work_dir" "$pipe_path" "$project_path" $launch_cmd
    fi
fi

# Cleanup is handled by the trap (cleanup_on_exit)
