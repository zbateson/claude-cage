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
    local line
    line=$(printf '[%s] %s %-14s %s' "$(date '+%Y-%m-%d %H:%M:%S')" "$commit_short" "$direction" "$msg")
    [ -n "$log_file" ] && printf '%s\n' "$line" >> "$log_file"
    if [ -n "${CLAUDE_CAGE_SESSION_LOG:-}" ] && [ -f "$CLAUDE_CAGE_SESSION_LOG" ]; then
        printf '[sync] %s\n' "$line" >> "$CLAUDE_CAGE_SESSION_LOG"
    fi
}

# Check if source working tree has uncommitted changes (staged, unstaged, or untracked)
# Arguments: $1=source_dir
source_is_dirty() {
    local source_dir="$1"
    [ -n "$(git -C "$source_dir" status --porcelain 2>/dev/null)" ]
}

# Copy dirty files (modified, deleted, untracked) from source to work dir.
# Used at startup with syncActiveBranch so Claude sees the user's in-progress edits.
# Arguments:
#   $1 - source_dir: The source project directory
#   $2 - work_dir: The cage work directory
#   $3 - scope_path: Scope path (empty for unscoped)
#   $4 - cfg_exclude: Pipe-delimited exclude patterns
copy_dirty_files_to_work() {
    local source_dir="$1"
    local work_dir="$2"
    local scope_path="$3"
    local cfg_exclude="$4"

    # Build exclude pathspec args
    local -a exclude_args=()
    if [ -n "$cfg_exclude" ]; then
        while IFS= read -r _ea; do
            exclude_args+=("$_ea")
        done < <(build_exclude_pathspecs "$cfg_exclude")
    fi

    local copied=0 deleted=0

    # Parse NUL-separated status entries directly from git (no command subst —
    # bash $() strips NUL bytes). Format: XY<space>path<NUL>
    # Renames/copies add a second NUL-separated entry for the new path.
    while IFS= read -r -d '' entry; do
        [ -z "$entry" ] && continue

        local xy="${entry:0:2}"
        local filepath="${entry:3}"

        # Renames/copies: filepath is the NEW name, next NUL entry is the OLD name
        if [[ "$xy" == R* ]] || [[ "$xy" == C* ]]; then
            local oldpath=""
            IFS= read -r -d '' oldpath || true

            # For scoped repos: skip files outside scope, strip prefix
            local dest_old="$oldpath"
            local dest_new="$filepath"
            if [ -n "$scope_path" ]; then
                case "$oldpath" in
                    "$scope_path/"*) dest_old="${oldpath#"$scope_path/"}" ;;
                    *) dest_old="" ;;
                esac
                case "$filepath" in
                    "$scope_path/"*) dest_new="${filepath#"$scope_path/"}" ;;
                    *) dest_new="" ;;
                esac
            fi

            # Delete old path from work if it was in scope
            if [ -n "$dest_old" ] && [ -f "$work_dir/$dest_old" ]; then
                rm -f "$work_dir/$dest_old"
                deleted=$((deleted + 1))
            fi

            # Copy new path to work if it was in scope and exists on disk
            if [ -n "$dest_new" ] && [ -e "$source_dir/$filepath" ]; then
                mkdir -p "$work_dir/$(dirname "$dest_new")"
                [ -f "$work_dir/$dest_new" ] && chmod u+w "$work_dir/$dest_new" 2>/dev/null || true
                cp -a "$source_dir/$filepath" "$work_dir/$dest_new"
                copied=$((copied + 1))
            fi
            continue
        fi

        # For scoped repos: skip files outside scope, strip prefix
        local dest="$filepath"
        if [ -n "$scope_path" ]; then
            case "$filepath" in
                "$scope_path/"*) dest="${filepath#"$scope_path/"}" ;;
                *) continue ;;
            esac
        fi

        # Check if file was deleted
        if [ ! -e "$source_dir/$filepath" ]; then
            if [ -e "$work_dir/$dest" ]; then
                rm -f "$work_dir/$dest"
                deleted=$((deleted + 1))
            fi
            continue
        fi

        # Copy file to work dir
        mkdir -p "$work_dir/$(dirname "$dest")"
        [ -f "$work_dir/$dest" ] && chmod u+w "$work_dir/$dest" 2>/dev/null || true
        cp -a "$source_dir/$filepath" "$work_dir/$dest"
        copied=$((copied + 1))
    done < <(git -C "$source_dir" status --porcelain -z -- . ${exclude_args:+"${exclude_args[@]}"} 2>/dev/null)

    local total=$((copied + deleted))
    if [ "$total" -gt 0 ]; then
        echo "Carried over $copied file(s) from your workin' tree${deleted:+, removed $deleted}."
    fi
}

# Copy carry files between source and work dir (outside git).
# Carry files are gitignored files that should persist across sessions
# (e.g., CLAUDE.md). Git-tracked files are skipped — git handles those.
# Arguments:
#   $1 - direction: "to_work" or "to_source"
#   $2 - source_dir: The source project directory
#   $3 - work_dir: The cage work directory
#   $4 - scope_path: Scope path (empty for unscoped)
#   $5 - cfg_carry: Pipe-delimited carry file paths
copy_carry_files() {
    local direction="$1"
    local source_dir="$2"
    local work_dir="$3"
    local scope_path="$4"
    local carry_str="$5"

    [ -z "$carry_str" ] && return 0

    local -a paths carried_names=()
    IFS='|' read -ra paths <<< "$carry_str"

    for filepath in "${paths[@]}"; do
        [ -z "$filepath" ] && continue

        # Skip git-tracked files — git handles those through the normal pipeline.
        # Directories may contain a mix of tracked/untracked files, so always
        # carry them (tracked files are identical in both repos anyway).
        if [ ! -d "$source_dir/$filepath" ] && \
           git -C "$source_dir" ls-files --error-unmatch "$filepath" >/dev/null 2>&1; then
            continue
        fi

        # Scope filtering: skip files outside scope, strip prefix for work
        local work_filepath="$filepath"
        if [ -n "$scope_path" ]; then
            case "$filepath" in
                "$scope_path/"*) work_filepath="${filepath#"$scope_path/"}" ;;
                *) continue ;;  # Outside scope, skip
            esac
        fi

        local from_path to_path
        if [ "$direction" = "to_work" ]; then
            from_path="$source_dir/$filepath"
            to_path="$work_dir/$work_filepath"
        else
            from_path="$work_dir/$work_filepath"
            to_path="$source_dir/$filepath"
        fi

        if [ -e "$from_path" ]; then
            if [ -d "$from_path" ]; then
                # Use /. to merge contents, not nest inside existing dir
                mkdir -p "$to_path"
                # Ensure existing dest files are writable (handles r--r--r-- files)
                [ -d "$to_path" ] && chmod -R u+w "$to_path" 2>/dev/null || true
                cp -a "$from_path/." "$to_path/"
            else
                mkdir -p "$(dirname "$to_path")"
                [ -f "$to_path" ] && chmod u+w "$to_path" 2>/dev/null || true
                cp -a "$from_path" "$to_path"
            fi
            carried_names+=("$filepath")
        fi
    done

    if [ ${#carried_names[@]} -gt 0 ]; then
        local names_str
        names_str=$(IFS=', '; echo "${carried_names[*]}")
        if [ "$direction" = "to_work" ]; then
            echo "Carried $names_str into the cage."
        else
            echo "Carried $names_str back to source."
        fi
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

    # Read scope_path from intermediary metadata (empty for unscoped)
    local scope_path=""
    local scope_path_file
    scope_path_file=$(get_scope_path_file "$intermediary_dir")
    if [ -f "$scope_path_file" ]; then
        scope_path=$(cat "$scope_path_file")
    fi

    # When scoped, fast-export must run from git root (pathspecs are CWD-relative)
    local export_dir="$source_dir"
    if [ -n "$scope_path" ]; then
        local git_root_file
        git_root_file=$(get_git_root_file "$intermediary_dir")
        if [ -f "$git_root_file" ]; then
            export_dir=$(cat "$git_root_file")
        fi
    fi

    # Get source HEAD
    local source_head
    source_head=$(git -C "$source_dir" rev-parse HEAD 2>/dev/null)
    local source_short="${source_head:0:8}"

    # Check commit mapping: already mapped -> skip (loop prevention)
    if [ -f "$commit_map_path" ] && grep -q " ${source_head}$" "$commit_map_path"; then
        sync_log "$log_file" "$source_short" ">>intermediary" "already mapped, skipping (loop prevention)"
        return 0
    fi

    # Build combined pathspec args: scope include + exclude
    local -a pathspec_args=()
    [ -n "$scope_path" ] && pathspec_args+=("$scope_path/")
    if [ -n "$exclude_patterns" ]; then
        while IFS= read -r _ea; do
            pathspec_args+=("$_ea")
        done < <(build_exclude_pathspecs "$exclude_patterns")
    fi

    local subject
    subject=$(git -C "$source_dir" log -1 --format=%s HEAD 2>/dev/null | head -c 50)
    sync_log "$log_file" "$source_short" ">>intermediary" "applying: $subject"

    # For merge commits, ensure all parents have marks in source-marks before fast-export.
    # See comment in claude-cage-sync-commit for full explanation.
    if git -C "$source_dir" rev-parse --verify "HEAD^2" >/dev/null 2>&1; then
        local _parent_hash _int_parent _max_mark _new_mark
        for _parent_hash in $(git -C "$source_dir" rev-list --parents -1 HEAD | cut -d' ' -f2-); do
            if [ -f "$source_marks_path" ] && grep -q " ${_parent_hash}$" "$source_marks_path" 2>/dev/null; then
                continue
            fi
            _int_parent=$(awk -v sh="$_parent_hash" '$2 == sh && $1 != "0" { print $1; exit }' "$commit_map_path" 2>/dev/null)
            if [ -n "$_int_parent" ] && [ -f "$source_marks_path" ] && [ -f "$import_marks_path" ]; then
                _max_mark=$(awk '{ gsub(/^:/,"",$1); id=$1+0; if(id>m) m=id } END { print m+0 }' \
                    "$source_marks_path" "$import_marks_path" 2>/dev/null)
                _new_mark=$((_max_mark + 1))
                echo ":$_new_mark $_parent_hash" >> "$source_marks_path"
                echo ":$_new_mark $_int_parent" >> "$import_marks_path"
                sync_log "$log_file" "$source_short" ">>intermediary" "added missing parent mark :$_new_mark for ${_parent_hash:0:8}"
            fi
        done
    fi

    # Export to temp file first so we can detect excluded-only commits before
    # fast-import. See comment in post-commit hook for full explanation.
    local export_err export_out
    export_err=$(make_temp_file "export-err")
    export_out=$(make_temp_file "export-out")

    git -C "$export_dir" fast-export \
        --import-marks="$source_marks_path" \
        --export-marks="$source_marks_path" \
        -1 HEAD \
        ${pathspec_args:+-- "${pathspec_args[@]}"} \
        >"$export_out" 2>"$export_err"
    local export_rc=$?

    if [ "$export_rc" -ne 0 ]; then
        sync_log "$log_file" "$source_short" ">>intermediary" "fast-export FAILED rc=$export_rc"
        [ -s "$export_err" ] && sync_log "$log_file" "$source_short" ">>intermediary" "export stderr: $(cat "$export_err")"
        rm -f "$export_err" "$export_out"
        return 1
    fi

    # Strip scope prefix from fast-export paths (scoped intermediaries only)
    [ -n "$scope_path" ] && strip_scope_prefix "$export_out" "$scope_path/" "$intermediary_dir"

    # Excluded-only detection: no commit line means fast-export dropped it entirely.
    if ! grep -q '^commit ' "$export_out"; then
        echo "0 $source_head" >> "$commit_map_path"
        sync_log "$log_file" "$source_short" ">>intermediary" "excluded-only commit (no commit line), mapped to 0"
        rm -f "$export_err" "$export_out"
        return 0
    fi

    # No from line: check if parent is in marks to distinguish excluded-only from marks gap.
    if ! grep -q '^from ' "$export_out"; then
        local _parent _parent_marked=false
        _parent=$(git -C "$source_dir" rev-parse HEAD^ 2>/dev/null) || true
        if [ -n "$_parent" ] && [ -f "$source_marks_path" ] && grep -q " ${_parent}$" "$source_marks_path" 2>/dev/null; then
            _parent_marked=true
        fi
        if [ "$_parent_marked" = true ] || [ -z "$_parent" ]; then
            echo "0 $source_head" >> "$commit_map_path"
            sync_log "$log_file" "$source_short" ">>intermediary" "excluded-only commit, mapped to 0"
            rm -f "$export_err" "$export_out"
            return 0
        fi
        # Marks gap: inject intermediary branch HEAD as parent
        local _current_branch _int_head
        _current_branch=$(git -C "$source_dir" branch --show-current 2>/dev/null)
        _int_head=$(git -C "$intermediary_dir" rev-parse "$_current_branch" 2>/dev/null) || true
        # Branch may not exist in intermediary yet — create from default branch
        if [ -z "$_int_head" ]; then
            local _default_branch _default_head
            _default_branch=$(git -C "$intermediary_dir" symbolic-ref --short HEAD 2>/dev/null)
            _default_head=$(git -C "$intermediary_dir" rev-parse "$_default_branch" 2>/dev/null) || true
            if [ -n "$_default_head" ]; then
                git -C "$intermediary_dir" branch "$_current_branch" "$_default_head" 2>/dev/null || true
                _int_head="$_default_head"
                sync_log "$log_file" "$source_short" ">>intermediary" "created branch $_current_branch from $_default_branch"
            fi
        fi
        if [ -n "$_int_head" ]; then
            sync_log "$log_file" "$source_short" ">>intermediary" "marks gap: injecting parent ${_int_head:0:8}"
            awk -v parent="$_int_head" '/^(merge |deleteall$)/ && !done { print "from " parent; done=1 } { print }' \
                "$export_out" > "$export_out.fix" && mv "$export_out.fix" "$export_out"
        else
            echo "0 $source_head" >> "$commit_map_path"
            sync_log "$log_file" "$source_short" ">>intermediary" "excluded-only (no intermediary HEAD)"
            rm -f "$export_err" "$export_out"
            return 0
        fi
    fi

    local import_err
    import_err=$(make_temp_file "import-err")
    git -C "$intermediary_dir" fast-import \
        --import-marks="$import_marks_path" \
        --export-marks="$import_marks_path" \
        --quiet <"$export_out" 2>"$import_err"
    local import_rc=$?

    if [ "$import_rc" -ne 0 ]; then
        sync_log "$log_file" "$source_short" ">>intermediary" "fast-import FAILED rc=$import_rc"
        [ -s "$import_err" ] && sync_log "$log_file" "$source_short" ">>intermediary" "import stderr: $(cat "$import_err")"
        local _import_msg="fast-import failed for $source_short (rc=$import_rc)"
        [ -s "$import_err" ] && _import_msg="$_import_msg: $(cat "$import_err")"
        echo -e "\033[1;31mclaude-cage:\033[0m $_import_msg" >&2
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

# Update commit map and marks files after syncing a commit to source.
# Records the mapping and adds marks so the post-commit hook can reference
# these commits as parents in subsequent fast-export calls.
# Arguments: $1=source_hash, $2=intermediary_hash, $3=commit_map_path,
#            $4=source_marks_path, $5=import_marks_path
update_marks_after_sync() {
    local source_hash="$1" intermediary_hash="$2"
    local commit_map_path="$3" source_marks_path="$4" import_marks_path="$5"
    echo "$intermediary_hash $source_hash" >> "$commit_map_path"
    if [ -f "$source_marks_path" ] && [ -f "$import_marks_path" ]; then
        local _max_mark _new_mark
        _max_mark=$(awk '{ gsub(/^:/,"",$1); id=$1+0; if(id>m) m=id } END { print m+0 }' \
            "$source_marks_path" "$import_marks_path" 2>/dev/null)
        _new_mark=$((_max_mark + 1))
        echo ":$_new_mark $source_hash" >> "$source_marks_path"
        echo ":$_new_mark $intermediary_hash" >> "$import_marks_path"
    fi
}

# Apply changes from intermediary to source
# Commit-mapping-based: walks first-parent commits, skips already-mapped ones
# Merge commits: creates real merge on source via commit-tree (two parents)
# Regular commits: applied via git-am (same branch) or temp-index (switched branch)
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
    local source_marks_path
    source_marks_path=$(get_source_marks_path "$intermediary_dir")
    local import_marks_path
    import_marks_path=$(get_import_marks_path "$intermediary_dir")

    # Read scope_path from intermediary metadata (empty for unscoped)
    local scope_path=""
    local scope_path_file
    scope_path_file=$(get_scope_path_file "$intermediary_dir")
    if [ -f "$scope_path_file" ]; then
        scope_path=$(cat "$scope_path_file")
    fi

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
        commits=$(git -C "$intermediary_dir" rev-list --first-parent --topo-order --reverse "${first_parent}..${newrev}" 2>/dev/null)
    else
        commits=$(git -C "$intermediary_dir" rev-list --first-parent --topo-order --reverse "${oldrev}..${newrev}" 2>/dev/null)
    fi

    if [ -z "$commits" ]; then
        echo "No new commits to sync"
        sync_log "$log_file" "$newrev_short" ">>source" "no commits in range"
        return 0
    fi

    echo "Bringin' changes home: $branch_name"

    # Hash used to target CLAUDE_CAGE_SYNCING at this intermediary's hook only
    local _sync_hash
    _sync_hash=$(path_hash "$source_dir")

    # Track last mapped source hash for fast-forwarding the branch when we
    # encounter an unmapped commit after a run of already-mapped ones
    local last_mapped_source_hash=""

    # Stash dirty working tree before applying commits (syncActiveBranch mode)
    local did_stash=false
    local current_branch
    current_branch=$(git -C "$source_dir" branch --show-current 2>/dev/null) || true

    # Skip active branch unless syncActiveBranch is enabled
    if [ "$current_branch" = "$branch_name" ] && [ "${cfg_syncActiveBranch:-}" != "true" ]; then
        echo "Skippin' sync to $branch_name — that's your active branch."
        echo "Run 'claude-cage git-merge' when you're ready to bring changes in."
        sync_log "$log_file" "$newrev_short" ">>source" "skipped: $branch_name is active branch (syncActiveBranch off)"
        return 0
    fi

    if [ "$current_branch" = "$branch_name" ] && source_is_dirty "$source_dir"; then
        # Stage untracked files so stash captures them (respects .gitignore)
        git -C "$source_dir" add -A 2>/dev/null || true
        local stash_output
        stash_output=$(git -C "$source_dir" stash push -m "claude-cage: WIP before sync batch" 2>&1) || true
        if echo "$stash_output" | grep -q "Saved working directory"; then
            did_stash=true
            sync_log "$log_file" "--------" ">>source" "stashed dirty tree before sync"
        fi
    fi

    local commit
    for commit in $commits; do
        local commit_short="${commit:0:8}"
        local commit_msg
        commit_msg=$(git -C "$intermediary_dir" log -1 --format=%s "$commit" 2>/dev/null)

        # Check if already mapped (skip, but track for fast-forward)
        if [ -f "$commit_map_path" ] && grep -q "^${commit} " "$commit_map_path" 2>/dev/null; then
            last_mapped_source_hash=$(awk -v ih="$commit" '$1 == ih { print $2; exit }' "$commit_map_path")
            sync_log "$log_file" "$commit_short" ">>source" "already mapped, skip"
            continue
        fi

        # Fast-forward source branch to last mapped commit if it's behind
        # (commits arrived via another branch but this branch wasn't advanced)
        if [ -n "$last_mapped_source_hash" ] && [ "$last_mapped_source_hash" != "0" ]; then
            local _ff_branch_hash
            _ff_branch_hash=$(git -C "$source_dir" rev-parse --verify "$branch_name" 2>/dev/null) || true
            if [ -n "$_ff_branch_hash" ] && [ "$_ff_branch_hash" != "$last_mapped_source_hash" ]; then
                if git -C "$source_dir" merge-base --is-ancestor "$_ff_branch_hash" "$last_mapped_source_hash" 2>/dev/null; then
                    local _ff_root
                    _ff_root=$(git -C "$source_dir" rev-parse --show-toplevel)
                    CLAUDE_CAGE_SYNCING=1 git -C "$_ff_root" update-ref "refs/heads/$branch_name" "$last_mapped_source_hash"
                    sync_log "$log_file" "$commit_short" ">>source" "fast-forward $branch_name to ${last_mapped_source_hash:0:8} before apply"
                    local _ff_current
                    _ff_current=$(git -C "$_ff_root" branch --show-current 2>/dev/null) || true
                    if [ "$_ff_current" = "$branch_name" ]; then
                        git -C "$_ff_root" reset --hard 2>/dev/null
                    fi
                fi
            fi
            last_mapped_source_hash=""
        fi

        # Check if this is the initial import commit (has no meaningful source equivalent)
        if ! git -C "$intermediary_dir" rev-parse "${commit}^" >/dev/null 2>&1; then
            sync_log "$log_file" "$commit_short" ">>source" "skipped initial commit"
            continue
        fi

        echo "  ${commit_short}: ${commit_msg:0:50}"

        # Check if this is a merge commit (has second parent)
        local cage_second_parent=""
        cage_second_parent=$(git -C "$intermediary_dir" rev-parse --verify "${commit}^2" 2>/dev/null) || true

        # Generate patch (git log --format=email handles both regular and merge
        # commits; format-patch silently skips merges so we don't use it)
        local patch
        patch=$(git -C "$intermediary_dir" log -1 -p --binary --format=email --first-parent "$commit" 2>/dev/null)

        # Skip empty patches
        if ! echo "$patch" | grep -q "^diff --git"; then
            echo "  Empty patch, skipped."
            sync_log "$log_file" "$commit_short" ">>source" "empty patch, skipped"
            # Map to 0 (no source equivalent)
            echo "$commit 0" >> "$commit_map_path"
            continue
        fi

        # Merge commits: create a real merge on source with both parents.
        # Uses commit-tree + update-ref so no hooks fire (prevents sync loops).
        if [ -n "$cage_second_parent" ]; then
            # Look up source equivalent of second parent
            local source_second_parent=""
            if [ -f "$commit_map_path" ]; then
                source_second_parent=$(awk -v ih="$cage_second_parent" '$1 == ih { print $2; exit }' "$commit_map_path")
            fi

            if [ -z "$source_second_parent" ] || [ "$source_second_parent" = "0" ]; then
                echo "  Can't sync this merge — second parent ain't on source."
                echo "  Push the branch to the remote first, then merge."
                save_failed_patch "$source_dir" "from-intermediary" "$patch" "$branch_name" "$commit_msg" "" "$scope_path"
                sync_log "$log_file" "$commit_short" ">>source" "merge FAILED: second parent ${cage_second_parent:0:8} not mapped"
                continue
            fi

            local source_first_parent
            source_first_parent=$(git -C "$source_dir" rev-parse "$branch_name" 2>/dev/null)

            if [ -z "$source_first_parent" ]; then
                echo "  Can't sync merge — branch $branch_name don't exist on source."
                save_failed_patch "$source_dir" "from-intermediary" "$patch" "$branch_name" "$commit_msg" "" "$scope_path"
                sync_log "$log_file" "$commit_short" ">>source" "merge FAILED: branch $branch_name missing on source"
                continue
            fi

            sync_log "$log_file" "$commit_short" ">>source" "merge on $branch_name: first=${source_first_parent:0:8} second=${source_second_parent:0:8}"

            local git_root
            git_root=$(git -C "$source_dir" rev-parse --show-toplevel)
            local tmp_index="$git_root/.git/claude-cage-tmp-index"

            local author_name author_email author_date
            author_name=$(echo "$patch" | grep "^From:" | head -1 | sed 's/^From: //' | sed 's/ <.*//')
            author_email=$(echo "$patch" | grep "^From:" | head -1 | sed 's/.*<\(.*\)>/\1/')
            author_date=$(echo "$patch" | grep "^Date:" | head -1 | sed 's/^Date: //')

            local commit_full_msg
            commit_full_msg=$(git -C "$intermediary_dir" log -1 --format=%B "$commit" 2>/dev/null)

            (
                export GIT_INDEX_FILE="$tmp_index"
                cd "$git_root"
                git read-tree "$branch_name"

                local -a apply_args=(--cached)
                [ -n "$scope_path" ] && apply_args+=(--directory="$scope_path")
                local apply_output apply_rc
                apply_output=$(echo "$patch" | git apply "${apply_args[@]}" 2>&1) && apply_rc=0 || apply_rc=$?

                if [ "$apply_rc" -eq 0 ]; then
                    local tree new_commit
                    tree=$(git write-tree)

                    export GIT_AUTHOR_NAME="$author_name"
                    export GIT_AUTHOR_EMAIL="$author_email"
                    [ -n "$author_date" ] && export GIT_AUTHOR_DATE="$author_date"

                    new_commit=$(git commit-tree "$tree" \
                        -p "$source_first_parent" \
                        -p "$source_second_parent" \
                        -m "$commit_full_msg")

                    unset GIT_INDEX_FILE
                    git update-ref "refs/heads/$branch_name" "$new_commit"

                    # If user is on this branch, update their working tree
                    local _current
                    _current=$(git branch --show-current 2>/dev/null)
                    if [ "$_current" = "$branch_name" ]; then
                        git reset --hard 2>/dev/null
                    fi

                    update_marks_after_sync "$new_commit" "$commit" "$commit_map_path" "$source_marks_path" "$import_marks_path"
                    echo "  Got it. Merge is in on $branch_name."
                    sync_log "$log_file" "$commit_short" ">>source" "merge ok on $branch_name new=${new_commit:0:8}"
                else
                    echo "  Merge patch didn't apply clean to $branch_name."
                    save_failed_patch "$source_dir" "from-intermediary" "$patch" "$branch_name" "$commit_msg" "" "$scope_path"
                    sync_log "$log_file" "$commit_short" ">>source" "merge FAILED on $branch_name: $(echo "$apply_output" | tail -1)"
                fi
            )
            rm -f "$tmp_index"
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
                git -C "$source_dir" branch "$branch_name" "$source_parent" 2>/dev/null
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
            local -a am_args=(--3way)
            [ -n "$scope_path" ] && am_args+=(--directory="$scope_path")
            local am_output am_rc
            am_output=$(echo "$patch" | CLAUDE_CAGE_SYNCING="$_sync_hash" git -C "$source_dir" am "${am_args[@]}" 2>&1) && am_rc=0 || am_rc=$?
            if [ "$am_rc" -eq 0 ]; then
                local new_source_hash
                new_source_hash=$(git -C "$source_dir" rev-parse HEAD)
                update_marks_after_sync "$new_source_hash" "$commit" "$commit_map_path" "$source_marks_path" "$import_marks_path"
                echo "  Got it. Changes are in."
                sync_log "$log_file" "$commit_short" ">>source" "git-am ok (same branch) new=${new_source_hash:0:8}"
            else
                echo "  Well now, that didn't go smooth."
                git -C "$source_dir" am --abort 2>/dev/null || true
                save_failed_patch "$source_dir" "from-intermediary" "$patch" "$branch_name" "$commit_msg" "" "$scope_path"
                sync_log "$log_file" "$commit_short" ">>source" "git-am FAILED rc=$am_rc: $(echo "$am_output" | tail -1)"
            fi
        else
            # User switched branches - apply via temp index
            echo "  You switched branches, applyin' to $branch_name without disturbin' your work..."

            local git_root
            git_root=$(git -C "$source_dir" rev-parse --show-toplevel)
            local tmp_index="$git_root/.git/claude-cage-tmp-index"

            local author_name author_email author_date
            author_name=$(echo "$patch" | grep "^From:" | head -1 | sed 's/^From: //' | sed 's/ <.*//')
            author_email=$(echo "$patch" | grep "^From:" | head -1 | sed 's/.*<\(.*\)>/\1/')
            author_date=$(echo "$patch" | grep "^Date:" | head -1 | sed 's/^Date: //')

            (
                export GIT_INDEX_FILE="$tmp_index"
                cd "$git_root"

                git read-tree "$branch_name"

                local -a apply_args=(--cached)
                [ -n "$scope_path" ] && apply_args+=(--directory="$scope_path")
                local apply_output apply_rc
                apply_output=$(echo "$patch" | git apply "${apply_args[@]}" 2>&1) && apply_rc=0 || apply_rc=$?
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

                    update_marks_after_sync "$new_commit" "$commit" "$commit_map_path" "$source_marks_path" "$import_marks_path"
                    echo "  Got it. Changes are on $branch_name."
                    sync_log "$log_file" "$commit_short" ">>source" "applied via temp-index to $branch_name new_commit=${new_commit:0:8}"
                else
                    echo "  Patch didn't apply clean to $branch_name."
                    save_failed_patch "$source_dir" "from-intermediary" "$patch" "$branch_name" "$commit_msg" "" "$scope_path"
                    sync_log "$log_file" "$commit_short" ">>source" "git-apply FAILED rc=$apply_rc on $branch_name: $(echo "$apply_output" | tail -1)"
                fi
            )

            rm -f "$tmp_index"
        fi
    done

    # Fast-forward source branch if the tip commit is already mapped but
    # the source branch hasn't been advanced (e.g., all commits arrived via
    # another branch and were "already mapped, skip").
    if [ -n "$last_mapped_source_hash" ] && [ "$last_mapped_source_hash" != "0" ]; then
        local _ff_branch_hash
        _ff_branch_hash=$(git -C "$source_dir" rev-parse --verify "$branch_name" 2>/dev/null) || true
        if [ -n "$_ff_branch_hash" ] && [ "$_ff_branch_hash" != "$last_mapped_source_hash" ]; then
            if git -C "$source_dir" merge-base --is-ancestor "$_ff_branch_hash" "$last_mapped_source_hash" 2>/dev/null; then
                local _ff_root
                _ff_root=$(git -C "$source_dir" rev-parse --show-toplevel)
                CLAUDE_CAGE_SYNCING=1 git -C "$_ff_root" update-ref "refs/heads/$branch_name" "$last_mapped_source_hash"
                sync_log "$log_file" "${newrev:0:8}" ">>source" "fast-forward $branch_name to ${last_mapped_source_hash:0:8}"
                echo "  Fast-forwarded $branch_name on source."
                local _ff_current
                _ff_current=$(git -C "$_ff_root" branch --show-current 2>/dev/null) || true
                if [ "$_ff_current" = "$branch_name" ]; then
                    git -C "$_ff_root" reset --hard 2>/dev/null
                fi
            fi
        fi
    fi

    # Restore stashed working tree (syncActiveBranch mode)
    if [ "$did_stash" = true ]; then
        local pop_rc
        git -C "$source_dir" stash pop 2>/dev/null && pop_rc=0 || pop_rc=$?
        if [ "$pop_rc" -eq 0 ]; then
            # Clean pop — unstage everything back to working tree state
            git -C "$source_dir" reset 2>/dev/null || true
            sync_log "$log_file" "--------" ">>source" "stash pop clean, WIP restored"
        else
            # Conflicts — leave them for the user to resolve via normal git tools
            echo -e "${_red}claude-cage:${_reset} Stash pop had conflicts with Claude's sync." >&2
            echo -e "${_red}claude-cage:${_reset} Resolve conflicts, then run: git reset" >&2
            sync_log "$log_file" "--------" ">>source" "stash pop had conflicts, left for user to resolve"
        fi
    fi

    # Propagate to sibling intermediaries at other scope levels
    propagate_to_sibling_intermediaries "$source_dir" "$intermediary_dir"
}

# Propagate source changes to all sibling intermediaries (different scope levels).
# Called after sync_to_source applies cage commits to source, so siblings stay in sync.
# Uses catchup_intermediary_branches which is idempotent (skips already-mapped commits).
# Arguments:
#   $1 - source_dir: The scoped source directory for the originating intermediary
#   $2 - current_intermediary_dir: The originating intermediary (skipped)
propagate_to_sibling_intermediaries() {
    local source_dir="$1"
    local current_intermediary_dir="$2"

    local git_root
    git_root=$(get_git_root "$source_dir")
    local repos_file
    repos_file=$(get_repos_list_path "$source_dir")
    [ -f "$repos_file" ] || return 0

    while IFS= read -r _scope; do
        local sibling_idir
        sibling_idir=$(get_scoped_intermediary_path "$git_root" "$_scope")

        # Skip self
        [ "$sibling_idir" = "$current_intermediary_dir" ] && continue

        # Skip if intermediary doesn't exist
        [ -d "$sibling_idir" ] && [ -f "$sibling_idir/HEAD" ] || continue

        local sibling_source
        if [ -n "$_scope" ]; then
            sibling_source="$git_root/$_scope"
        else
            sibling_source="$git_root"
        fi

        catchup_intermediary_branches "$sibling_source" "$sibling_idir" 2>/dev/null || true
    done < "$repos_file"
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

# Find the last mapped intermediary commit on a branch.
# Walks first-parent chain backwards from branch HEAD until a mapped commit is found.
# Outputs the mapped commit hash, or empty string if none found.
# Arguments:
#   $1 - intermediary_dir
#   $2 - branch name
#   $3 - commit_map_path
_find_last_mapped_on_branch() {
    local intermediary_dir="$1"
    local branch="$2"
    local commit_map_path="$3"

    [ ! -f "$commit_map_path" ] && return 0

    local ancestor
    for ancestor in $(git -C "$intermediary_dir" rev-list --first-parent "$branch" 2>/dev/null); do
        if grep -q "^${ancestor} " "$commit_map_path" 2>/dev/null; then
            echo "$ancestor"
            return 0
        fi
    done
}

# Check if an intermediary branch has unmerged commits.
# Returns 0 (true) if there are unmerged commits, 1 (false) if fully synced.
# Arguments:
#   $1 - intermediary_dir
#   $2 - branch name
#   $3 - commit_map_path
_branch_has_unmerged() {
    local intermediary_dir="$1"
    local branch="$2"
    local commit_map_path="$3"

    local branch_head
    branch_head=$(git -C "$intermediary_dir" rev-parse "$branch" 2>/dev/null) || return 1

    if [ -f "$commit_map_path" ] && grep -q "^${branch_head} " "$commit_map_path" 2>/dev/null; then
        return 1  # fully mapped
    fi
    return 0  # has unmerged commits
}

# Sync a single intermediary branch to source via sync_to_source.
# Arguments:
#   $1 - source_dir
#   $2 - intermediary_dir
#   $3 - branch name
#   $4 - commit_map_path
_sync_branch_to_source() {
    local source_dir="$1"
    local intermediary_dir="$2"
    local branch="$3"
    local commit_map_path="$4"

    local oldrev
    oldrev=$(_find_last_mapped_on_branch "$intermediary_dir" "$branch" "$commit_map_path")
    [ -z "$oldrev" ] && oldrev="0000000000000000000000000000000000000000"

    # Force syncActiveBranch so sync_to_source doesn't skip the active branch.
    # The user explicitly asked for this merge.
    local saved_sync_active="${cfg_syncActiveBranch:-}"
    cfg_syncActiveBranch="true"
    sync_to_source "$source_dir" "$intermediary_dir" "refs/heads/$branch" "$oldrev"
    cfg_syncActiveBranch="$saved_sync_active"
}

# Manual sync from intermediary to source (for git-merge subcommand).
# Arguments:
#   $1 - source_dir: The original source directory
#   $2 - scope_path: (optional) scope path for scoped intermediaries
#   $3 - target_branch: (optional) specific branch to merge, empty for current
#   $4 - all_flag: "true" to sync all branches
manual_git_merge() {
    local source_dir="$1"
    local scope_path="${2:-}"
    local target_branch="${3:-}"
    local all_flag="${4:-false}"

    local intermediary_dir
    intermediary_dir=$(get_scoped_intermediary_path "$source_dir" "$scope_path")

    if [ ! -d "$intermediary_dir" ]; then
        echo "No intermediary found — nothin' to merge."
        echo "Were you on a different branch when you started the cage?"
        exit 1
    fi

    local commit_map_path
    commit_map_path=$(get_commit_map_path "$intermediary_dir")

    if [ "$all_flag" = true ]; then
        # Sync all branches
        local synced_any=false
        local branch
        while IFS= read -r branch; do
            if _branch_has_unmerged "$intermediary_dir" "$branch" "$commit_map_path"; then
                synced_any=true
                _sync_branch_to_source "$source_dir" "$intermediary_dir" "$branch" "$commit_map_path"
            fi
        done < <(git -C "$intermediary_dir" for-each-ref --format='%(refname:short)' refs/heads/)

        if [ "$synced_any" = false ]; then
            echo "Everything's already in sync — nothin' to merge."
        fi
        return 0
    fi

    # Determine target branch
    if [ -z "$target_branch" ]; then
        target_branch=$(git -C "$source_dir" branch --show-current 2>/dev/null) || true
        if [ -z "$target_branch" ]; then
            echo "Can't figure out which branch you're on. Pass a branch name:"
            echo "  claude-cage git-merge <branch>"
            exit 1
        fi
    fi

    # Check branch exists in intermediary
    if ! git -C "$intermediary_dir" rev-parse --verify "$target_branch" >/dev/null 2>&1; then
        echo "Branch '$target_branch' don't exist in the intermediary."
        echo ""
        echo "Available branches:"
        git -C "$intermediary_dir" for-each-ref --format='  %(refname:short)' refs/heads/
        exit 1
    fi

    # Check if there's anything to merge
    if ! _branch_has_unmerged "$intermediary_dir" "$target_branch" "$commit_map_path"; then
        echo "Branch '$target_branch' is already in sync — nothin' to merge."
        return 0
    fi

    # Refuse if merging current branch and tree is dirty
    local current_branch
    current_branch=$(git -C "$source_dir" branch --show-current 2>/dev/null) || true
    if [ "$current_branch" = "$target_branch" ] && source_is_dirty "$source_dir"; then
        echo "Your workin' tree's dirty. Stash or commit your changes first:"
        echo "  git stash"
        echo "  claude-cage git-merge"
        echo "  git stash pop"
        exit 1
    fi

    _sync_branch_to_source "$source_dir" "$intermediary_dir" "$target_branch" "$commit_map_path"
}
