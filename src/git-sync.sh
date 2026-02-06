# ============================================================================
# Git sync operations (commit-mapping based sync)
# ============================================================================

# Append a line to the sync log file (in intermediary)
# Arguments: $1=log_file, $2=commit_short, $3=direction, $4=message
sync_log() {
    local log_file="$1"
    local commit_short="$2"
    local direction="$3"
    local msg="$4"
    if [ -n "$log_file" ]; then
        printf '[%s] %s %-14s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$commit_short" "$direction" "$msg" >> "$log_file"
    fi
}

# Check if existing cage is in sync with source
# Returns: "no_cage" | "in_sync" | "needs_work_dir" | "needs_update"
# Arguments:
#   $1 - source_dir: The source project directory
#   $2 - intermediary_dir: The bare intermediary directory
#   $3 - work_dir: The cage work directory
check_cage_state() {
    local source_dir="$1"
    local intermediary_dir="$2"
    local work_dir="$3"

    # No intermediary at all
    if [ ! -d "$intermediary_dir" ]; then
        echo "no_cage"
        return
    fi

    # Intermediary exists but no work dir
    if [ ! -d "$work_dir" ]; then
        echo "needs_work_dir"
        return
    fi

    # Check if current branch exists in intermediary
    local branch_name
    branch_name=$(get_source_branch "$source_dir")
    if [ -n "$branch_name" ] && ! git -C "$intermediary_dir" rev-parse --verify "$branch_name" >/dev/null 2>&1; then
        echo "needs_update"
        return
    fi

    # Check if source HEAD is mapped in commit mapping
    local commit_map_path
    commit_map_path=$(get_commit_map_path "$intermediary_dir")
    if [ -f "$commit_map_path" ] && [ -n "$branch_name" ]; then
        local source_head
        source_head=$(git -C "$source_dir" rev-parse "$branch_name" 2>/dev/null)
        if [ -n "$source_head" ] && grep -q " ${source_head}$" "$commit_map_path" 2>/dev/null; then
            echo "in_sync"
            return
        fi
    fi

    echo "needs_update"
}

# Show diff of uncommitted changes in work directory
# Arguments:
#   $1 - work_dir: The cage work directory
show_cage_diff() {
    local work_dir="$1"
    echo ""
    echo "Changes in the cage:"
    echo "--------------------"
    git -C "$work_dir" diff 2>/dev/null
    git -C "$work_dir" diff --cached 2>/dev/null
    # Show untracked files
    local untracked
    untracked=$(git -C "$work_dir" ls-files --others --exclude-standard 2>/dev/null)
    if [ -n "$untracked" ]; then
        echo ""
        echo "Untracked files:"
        echo "$untracked" | sed 's/^/  /'
    fi
    echo "--------------------"
    echo ""
}

# Apply source commits to intermediary using fast-export with pathspec excludes
# Used for catching up the intermediary to source state
# Arguments:
#   $1 - source_dir: The source project directory
#   $2 - intermediary_dir: The bare intermediary directory
#   $3 - exclude_patterns: Pipe-delimited exclude patterns
apply_source_to_intermediary() {
    local source_dir="$1"
    local intermediary_dir="$2"
    local exclude_patterns="$3"

    local source_marks_path
    source_marks_path=$(get_source_marks_path "$intermediary_dir")
    local import_marks_path
    import_marks_path=$(get_import_marks_path "$intermediary_dir")
    local commit_map_path
    commit_map_path=$(get_commit_map_path "$intermediary_dir")
    local log_file="$intermediary_dir/sync.log"

    # Get source HEAD
    local source_head
    source_head=$(git -C "$source_dir" rev-parse HEAD 2>/dev/null)
    local source_short="${source_head:0:8}"

    # Check commit mapping: already mapped -> skip (loop prevention)
    if [ -f "$commit_map_path" ] && grep -q " ${source_head}$" "$commit_map_path"; then
        sync_log "$log_file" "$source_short" ">>intermediary" "already mapped, skipping (loop prevention)"
        return 0
    fi

    # Build :(exclude,glob) pathspec args
    local -a exclude_args=()
    if [ -n "$exclude_patterns" ]; then
        while IFS= read -r _ea; do
            exclude_args+=("$_ea")
        done < <(build_exclude_pathspecs "$exclude_patterns")
    fi

    local subject
    subject=$(git -C "$source_dir" log -1 --format=%s HEAD 2>/dev/null | head -c 50)
    sync_log "$log_file" "$source_short" ">>intermediary" "applying: $subject"

    # Export to temp file first so we can detect excluded-only commits before
    # fast-import. See comment in post-commit hook for full explanation.
    local export_err export_out
    export_err=$(mktemp 2>/dev/null || echo "/tmp/claude-cage-export-err.$$")
    export_out=$(mktemp 2>/dev/null || echo "/tmp/claude-cage-export-out.$$")

    git -C "$source_dir" fast-export \
        --import-marks="$source_marks_path" \
        --export-marks="$source_marks_path" \
        -1 HEAD \
        ${exclude_args:+-- "${exclude_args[@]}"} \
        >"$export_out" 2>"$export_err"
    local export_rc=$?

    if [ "$export_rc" -ne 0 ]; then
        sync_log "$log_file" "$source_short" ">>intermediary" "fast-export FAILED rc=$export_rc"
        [ -s "$export_err" ] && sync_log "$log_file" "$source_short" ">>intermediary" "export stderr: $(cat "$export_err")"
        rm -f "$export_err" "$export_out"
        return 1
    fi

    # Excluded-only commits: fast-export either drops the commit (small repos →
    # just a reset/empty) or emits an orphan root commit (large repos → commit
    # without a from line, because blob marks aren't in source-marks).
    if ! grep -q '^commit ' "$export_out" || ! grep -q '^from ' "$export_out"; then
        echo "0 $source_head" >> "$commit_map_path"
        sync_log "$log_file" "$source_short" ">>intermediary" "excluded-only commit, mapped to 0"
        rm -f "$export_err" "$export_out"
        return 0
    fi

    local import_err
    import_err=$(mktemp 2>/dev/null || echo "/tmp/claude-cage-import-err.$$")
    git -C "$intermediary_dir" fast-import \
        --import-marks="$import_marks_path" \
        --export-marks="$import_marks_path" \
        --quiet <"$export_out" 2>"$import_err"
    local import_rc=$?

    if [ "$import_rc" -ne 0 ]; then
        sync_log "$log_file" "$source_short" ">>intermediary" "fast-import FAILED rc=$import_rc"
        [ -s "$import_err" ] && sync_log "$log_file" "$source_short" ">>intermediary" "import stderr: $(cat "$import_err")"
        rm -f "$export_err" "$import_err" "$export_out"
        return 1
    fi
    rm -f "$export_err" "$import_err" "$export_out"

    # Update commit mapping
    build_commit_map_from_marks "$source_marks_path" "$import_marks_path" "$commit_map_path" "" ""

    # If source HEAD still not in mapping after marks join, record as excluded-only
    if ! grep -q " ${source_head}$" "$commit_map_path" 2>/dev/null; then
        echo "0 $source_head" >> "$commit_map_path"
        sync_log "$log_file" "$source_short" ">>intermediary" "excluded-only commit, mapped to 0"
    else
        sync_log "$log_file" "$source_short" ">>intermediary" "fast-import ok"
    fi

    return 0
}

# Apply changes from intermediary to source using format-patch/git-am
# Commit-mapping-based: walks commits, skips already-mapped ones
# Arguments:
#   $1 - source_dir: The original source directory
#   $2 - intermediary_dir: The bare intermediary directory
#   $3 - refname: The git ref that was pushed (e.g., refs/heads/main)
#   $4 - oldrev: The previous rev before the push
sync_to_source() {
    local source_dir="$1"
    local intermediary_dir="$2"
    local refname="$3"
    local oldrev="$4"
    local log_file="$intermediary_dir/sync.log"

    local branch_name="${refname#refs/heads/}"
    local newrev
    newrev=$(git -C "$intermediary_dir" rev-parse "$refname" 2>/dev/null)
    local newrev_short="${newrev:0:8}"

    local commit_map_path
    commit_map_path=$(get_commit_map_path "$intermediary_dir")

    # Determine which commits to process
    local commits
    if [ "$oldrev" = "0000000000000000000000000000000000000000" ] || [ -z "$oldrev" ]; then
        # New branch - find first parent in mapping to determine base
        local first_parent
        first_parent=$(git -C "$intermediary_dir" rev-parse "${newrev}^" 2>/dev/null) || true
        if [ -z "$first_parent" ]; then
            # Root commit
            echo "First commit on new branch, nothin' to sync yet"
            sync_log "$log_file" "$newrev_short" ">>source" "skipped root commit on $branch_name"
            return 0
        fi
        commits=$(git -C "$intermediary_dir" rev-list --topo-order --reverse "${first_parent}..${newrev}" 2>/dev/null)
    else
        commits=$(git -C "$intermediary_dir" rev-list --topo-order --reverse "${oldrev}..${newrev}" 2>/dev/null)
    fi

    if [ -z "$commits" ]; then
        echo "No new commits to sync"
        sync_log "$log_file" "$newrev_short" ">>source" "no commits in range"
        return 0
    fi

    echo "Bringin' changes home: $branch_name"

    local commit
    for commit in $commits; do
        local commit_short="${commit:0:8}"
        local commit_msg
        commit_msg=$(git -C "$intermediary_dir" log -1 --format=%s "$commit" 2>/dev/null)

        # Check if already mapped (skip)
        if [ -f "$commit_map_path" ] && grep -q "^${commit} " "$commit_map_path" 2>/dev/null; then
            sync_log "$log_file" "$commit_short" ">>source" "already mapped, skip"
            continue
        fi

        # Check if this is the initial import commit (has no meaningful source equivalent)
        if ! git -C "$intermediary_dir" rev-parse "${commit}^" >/dev/null 2>&1; then
            sync_log "$log_file" "$commit_short" ">>source" "skipped initial commit"
            continue
        fi

        echo "  ${commit_short}: ${commit_msg:0:50}"

        # Generate patch
        local patch
        patch=$(git -C "$intermediary_dir" format-patch -1 "$commit" --stdout 2>/dev/null)

        # Skip empty patches
        if ! echo "$patch" | grep -q "^diff --git"; then
            echo "  Empty patch, skipped."
            sync_log "$log_file" "$commit_short" ">>source" "empty patch, skipped"
            # Map to 0 (no source equivalent)
            echo "$commit 0" >> "$commit_map_path"
            continue
        fi

        # Check if source has this branch
        local source_has_branch=true
        if ! git -C "$source_dir" rev-parse --verify "$branch_name" >/dev/null 2>&1; then
            source_has_branch=false
            # New branch - find parent in mapping
            local parent_hash
            parent_hash=$(git -C "$intermediary_dir" rev-parse "${commit}^" 2>/dev/null)
            local source_parent=""
            if [ -f "$commit_map_path" ]; then
                source_parent=$(awk -v ih="$parent_hash" '$1 == ih { print $2; exit }' "$commit_map_path")
            fi
            if [ -n "$source_parent" ] && [ "$source_parent" != "0" ]; then
                git -C "$source_dir" checkout -b "$branch_name" "$source_parent" 2>/dev/null
                source_has_branch=true
                sync_log "$log_file" "$commit_short" ">>source" "created branch $branch_name from $source_parent"
            fi
        fi

        # Apply patch to source
        local current_branch
        current_branch=$(git -C "$source_dir" branch --show-current 2>/dev/null)

        sync_log "$log_file" "$commit_short" ">>source" "target=$branch_name current=$current_branch msg=$(echo "$commit_msg" | head -c 50)"

        if [ "$current_branch" = "$branch_name" ]; then
            # Simple case: user on same branch
            local am_output am_rc
            am_output=$(echo "$patch" | git -C "$source_dir" am --3way 2>&1) && am_rc=0 || am_rc=$?
            if [ "$am_rc" -eq 0 ]; then
                local new_source_hash
                new_source_hash=$(git -C "$source_dir" rev-parse HEAD)
                echo "$commit $new_source_hash" >> "$commit_map_path"
                echo "  Got it. Changes are in."
                sync_log "$log_file" "$commit_short" ">>source" "git-am ok (same branch) new=${new_source_hash:0:8}"
            else
                echo "  Well now, that didn't go smooth."
                git -C "$source_dir" am --abort 2>/dev/null || true
                save_failed_patch "$source_dir" "from-intermediary" "$patch" "$branch_name" "$commit_msg"
                sync_log "$log_file" "$commit_short" ">>source" "git-am FAILED rc=$am_rc: $(echo "$am_output" | tail -1)"
            fi
        else
            # User switched branches - apply via temp index
            echo "  You switched branches, applyin' to $branch_name without disturbin' your work..."

            local tmp_index="$source_dir/.git/claude-cage-tmp-index"

            local author_name author_email author_date
            author_name=$(echo "$patch" | grep "^From:" | head -1 | sed 's/^From: //' | sed 's/ <.*//')
            author_email=$(echo "$patch" | grep "^From:" | head -1 | sed 's/.*<\(.*\)>/\1/')
            author_date=$(echo "$patch" | grep "^Date:" | head -1 | sed 's/^Date: //')

            (
                export GIT_INDEX_FILE="$tmp_index"
                cd "$source_dir"

                git read-tree "$branch_name"

                local apply_output apply_rc
                apply_output=$(echo "$patch" | git apply --cached 2>&1) && apply_rc=0 || apply_rc=$?
                if [ "$apply_rc" -eq 0 ]; then
                    local tree
                    tree=$(git write-tree)

                    local parent
                    parent=$(git rev-parse "$branch_name")

                    export GIT_AUTHOR_NAME="$author_name"
                    export GIT_AUTHOR_EMAIL="$author_email"
                    [ -n "$author_date" ] && export GIT_AUTHOR_DATE="$author_date"

                    local new_commit
                    new_commit=$(git commit-tree "$tree" -p "$parent" -m "$commit_msg")

                    git update-ref "refs/heads/$branch_name" "$new_commit"

                    echo "$commit $new_commit" >> "$commit_map_path"
                    echo "  Got it. Changes are on $branch_name."
                    sync_log "$log_file" "$commit_short" ">>source" "applied via temp-index to $branch_name new_commit=${new_commit:0:8}"
                else
                    echo "  Patch didn't apply clean to $branch_name."
                    save_failed_patch "$source_dir" "from-intermediary" "$patch" "$branch_name" "$commit_msg"
                    sync_log "$log_file" "$commit_short" ">>source" "git-apply FAILED rc=$apply_rc on $branch_name: $(echo "$apply_output" | tail -1)"
                fi
            )

            rm -f "$tmp_index"
        fi
    done
}

# Start the pipe listener in background
# Arguments:
#   $1 - source_dir: The original source directory
#   $2 - intermediary_dir: The bare intermediary directory
#   $3 - pipe_path: The pipe file path
#   $4 - verbose: "true" to show sync output, anything else to suppress
# Sets: PIPE_LISTENER_PID
start_pipe_listener() {
    local source_dir="$1"
    local intermediary_dir="$2"
    local pipe_path="$3"
    local listener_verbose="${4:-false}"

    # Run listener in background
    (
        exec 3<>"$pipe_path"
        while read -r refname newrev oldrev <&3; do
            if [ -n "$refname" ]; then
                sync_log "$intermediary_dir/sync.log" "${newrev:0:8}" "pipe-recv" "refname=$refname newrev=${newrev:0:8} oldrev=${oldrev:0:8}"
                if [ "$debug" = true ]; then
                    echo -e "${_yellow}[pipe-listener] received: refname=$refname newrev=$newrev oldrev=$oldrev$(date +" at %H:%M:%S")${_reset}" >&2
                fi
                if [ "$listener_verbose" = true ]; then
                    sync_to_source "$source_dir" "$intermediary_dir" "$refname" "$oldrev"
                else
                    sync_to_source "$source_dir" "$intermediary_dir" "$refname" "$oldrev" >/dev/null 2>&1
                fi
            fi
        done
    ) &
    PIPE_LISTENER_PID=$!
}

# Stop the pipe listener
# Arguments:
#   $1 - listener_pid: PID of the listener process
stop_pipe_listener() {
    local listener_pid="$1"
    if [ -n "$listener_pid" ] && kill -0 "$listener_pid" 2>/dev/null; then
        kill "$listener_pid" 2>/dev/null
        wait "$listener_pid" 2>/dev/null
    fi
}

# Manual git merge from intermediary (for --git-merge option)
# Arguments:
#   $1 - source_dir: The original source directory
manual_git_merge() {
    local source_dir="$1"
    local scope_path="${2:-}"

    local intermediary_dir
    intermediary_dir=$(get_scoped_intermediary_path "$source_dir" "$scope_path")

    if [ ! -d "$intermediary_dir" ]; then
        echo "Nothin' to merge. No intermediary found."
        echo "Were you on a different branch when you started the cage?"
        exit 1
    fi

    # Add or update intermediary remote
    if git -C "$source_dir" remote | grep -q "^intermediary$"; then
        run git -C "$source_dir" remote set-url intermediary "$intermediary_dir"
    else
        run git -C "$source_dir" remote add intermediary "$intermediary_dir"
    fi

    echo "Grabbin' what Claude's been workin' on..."
    run git -C "$source_dir" fetch intermediary

    echo ""
    echo "Here's what's waitin' for ya:"
    git -C "$source_dir" branch -r 2>/dev/null | grep -E "^\\s*intermediary/" | sed 's/^/  /' || echo "  (none yet)"

    echo ""
    echo "When you're ready, just run:"
    echo "  git merge intermediary/<branch>"
}
