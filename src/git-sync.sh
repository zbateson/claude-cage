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
# Refresh the stat cache first so stale mtime/size doesn't fake a dirty result
# (same hardening as is_work_dirty in git-clone.sh).
# Arguments: $1=source_dir
source_is_dirty() {
    local source_dir="$1"
    git -C "$source_dir" update-index --refresh -q --unmerged >/dev/null 2>&1 || true
    [ -n "$(git -C "$source_dir" status --porcelain 2>/dev/null)" ]
}

# Stricter version of source_is_dirty: returns 0 only when source has dirty
# changes that would *actually* be carried into the cage — i.e. changes that
# survive exclude patterns and (for scoped runs) the scope filter. The startup
# bringDirty hint and the carry trigger use this so we don't nag when every
# dirty file is excluded or out of scope. Uses enumerate_source_dirty_pairs as
# the single source of truth for "carryable" — exactly the same set
# copy_dirty_files_to_work would touch.
# Arguments: $1=source_dir, $2=scope_path (empty for unscoped), $3=cfg_exclude
source_has_carryable_dirty() {
    local source_dir="$1"
    local scope_path="$2"
    local cfg_exclude="$3"
    [ -n "$(enumerate_source_dirty_pairs "$source_dir" "$scope_path" "$cfg_exclude" 2>/dev/null | head -c 1)" ]
}

# Emit NUL-separated (src_path, dest_path) pairs for each dirty file in source.
# Renames/copies expand to two records: (old_path -> dest_old) treated as a
# deletion, and (new_path -> dest_new) treated as a create/modify. Paths
# outside the scope are dropped. Existence of `source_dir/src_path` on disk
# distinguishes create/modify from delete — consumers branch on that.
# Arguments:
#   $1 - source_dir: The source project directory
#   $2 - scope_path: Scope path (empty for unscoped)
#   $3 - cfg_exclude: Pipe-delimited exclude patterns
enumerate_source_dirty_pairs() {
    local source_dir="$1"
    local scope_path="$2"
    local cfg_exclude="$3"

    git -C "$source_dir" update-index --refresh -q --unmerged >/dev/null 2>&1 || true

    local -a exclude_args=()
    if [ -n "$cfg_exclude" ]; then
        while IFS= read -r _ea; do
            exclude_args+=("$_ea")
        done < <(build_exclude_pathspecs "$cfg_exclude")
    fi

    while IFS= read -r -d '' entry; do
        [ -z "$entry" ] && continue

        local xy="${entry:0:2}"
        local filepath="${entry:3}"

        if [[ "$xy" == R* ]] || [[ "$xy" == C* ]]; then
            local oldpath=""
            IFS= read -r -d '' oldpath || true

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

            [ -n "$dest_old" ] && printf '%s\0%s\0' "$oldpath" "$dest_old"
            [ -n "$dest_new" ] && printf '%s\0%s\0' "$filepath" "$dest_new"
            continue
        fi

        local dest="$filepath"
        if [ -n "$scope_path" ]; then
            case "$filepath" in
                "$scope_path/"*) dest="${filepath#"$scope_path/"}" ;;
                *) continue ;;
            esac
        fi
        printf '%s\0%s\0' "$filepath" "$dest"
    done < <(git -C "$source_dir" status --porcelain -z -- . ${exclude_args:+"${exclude_args[@]}"} 2>/dev/null)
}

# Copy dirty files (modified, deleted, untracked) from source to work dir.
# Used at startup when bringDirty so Claude sees the user's in-progress edits.
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

    local copied=0 deleted=0
    local src_path dest_path
    while IFS= read -r -d '' src_path && IFS= read -r -d '' dest_path; do
        if [ ! -e "$source_dir/$src_path" ]; then
            if [ -e "$work_dir/$dest_path" ]; then
                rm -f "$work_dir/$dest_path"
                deleted=$((deleted + 1))
            fi
        else
            mkdir -p "$work_dir/$(dirname "$dest_path")"
            [ -f "$work_dir/$dest_path" ] && chmod u+w "$work_dir/$dest_path" 2>/dev/null || true
            cp -a "$source_dir/$src_path" "$work_dir/$dest_path"
            copied=$((copied + 1))
        fi
    done < <(enumerate_source_dirty_pairs "$source_dir" "$scope_path" "$cfg_exclude")

    local total=$((copied + deleted))
    if [ "$total" -gt 0 ]; then
        echo "Carried over $copied file(s) from your workin' tree${deleted:+, removed $deleted}."
    fi
}

# Decide if a dirty cage's working tree mirrors the source's dirty state
# exactly, file-for-file. When true, the cage can be cleaned at exit without
# loss — source already holds every change. Drives match-clean cleanup.
# Returns 0 if every source-dirty path matches work content (and work has no
# extra dirty paths); 1 otherwise.
# Arguments:
#   $1 - source_dir, $2 - work_dir, $3 - scope_path, $4 - cfg_exclude
work_matches_source_dirty() {
    local source_dir="$1"
    local work_dir="$2"
    local scope_path="$3"
    local cfg_exclude="$4"

    [ -d "$work_dir/.git" ] || return 1

    local pairs_file
    pairs_file=$(mktemp)
    enumerate_source_dirty_pairs "$source_dir" "$scope_path" "$cfg_exclude" > "$pairs_file"

    declare -A source_dests=()
    local src_path dest_path
    while IFS= read -r -d '' src_path && IFS= read -r -d '' dest_path; do
        source_dests["$dest_path"]=1
    done < "$pairs_file"

    local entry xy wpath oldpath
    while IFS= read -r -d '' entry; do
        [ -z "$entry" ] && continue
        xy="${entry:0:2}"
        wpath="${entry:3}"

        if [[ "$xy" == R* ]] || [[ "$xy" == C* ]]; then
            oldpath=""
            IFS= read -r -d '' oldpath || true
            if [ -z "${source_dests[$wpath]+_}" ]; then
                rm -f "$pairs_file"
                return 1
            fi
            if [ -n "$oldpath" ] && [ -z "${source_dests[$oldpath]+_}" ]; then
                rm -f "$pairs_file"
                return 1
            fi
            continue
        fi

        if [ -z "${source_dests[$wpath]+_}" ]; then
            rm -f "$pairs_file"
            return 1
        fi
    done < <(git -C "$work_dir" status --porcelain -z 2>/dev/null)

    while IFS= read -r -d '' src_path && IFS= read -r -d '' dest_path; do
        if [ ! -e "$source_dir/$src_path" ]; then
            if [ -e "$work_dir/$dest_path" ]; then
                rm -f "$pairs_file"
                return 1
            fi
        else
            if [ ! -e "$work_dir/$dest_path" ] || ! cmp -s "$source_dir/$src_path" "$work_dir/$dest_path"; then
                rm -f "$pairs_file"
                return 1
            fi
        fi
    done < "$pairs_file"

    rm -f "$pairs_file"
    return 0
}

# Path to the per-work-dir snapshot manifest used by copy_carry_files for the
# divergence check on to_source. One line per carry entry: <sha>\t<src_path>.
# Lives inside .git so it gets removed when the work dir is torn down.
# Arguments: $1 = work_dir
_carry_manifest_path() {
    echo "$1/.git/claude-cage-carry-hashes"
}

# sha256 of a regular file's contents. Returns empty (and non-zero) for
# missing files, directories, or symlinks — symlinks aren't tracked by the
# carry snapshot (carry semantics don't promise symlink fidelity).
# Arguments: $1 = path
_carry_hash_file() {
    local p="$1"
    [ -f "$p" ] && [ ! -L "$p" ] || return 1
    sha256sum < "$p" 2>/dev/null | awk '{print $1}'
}

# Emit per-file manifest fragments for a carry directory: one line per
# regular file beneath it, "<sha>\t<src_path>/<relpath>". Symlinks and
# special files are skipped. Empty dirs emit nothing. Used at startup so
# from_cage can tell whether the dir's contents changed.
# Arguments: $1 = dir (absolute), $2 = src_path (logical key prefix)
_carry_hash_dir() {
    local dir="$1" src_path="$2"
    [ -d "$dir" ] || return 0
    local f rel h
    while IFS= read -r -d '' f; do
        rel="${f#"$dir/"}"
        h=$(sha256sum < "$f" 2>/dev/null | awk '{print $1}') || continue
        [ -n "$h" ] && printf '%s\t%s/%s\n' "$h" "$src_path" "$rel"
    done < <(find "$dir" -type f ! -type l -print0 2>/dev/null)
}

# Returns 0 when the cage's current contents of $cage_path match the per-file
# snapshot recorded under $src_path/* in the manifest — meaning the cage
# didn't touch the carry dir. Returns 1 on any mismatch: a file's hash
# differs, the cage has a file the manifest doesn't mention, or the
# manifest expected a file that's gone. Symlinks and special files are
# ignored on both sides for consistency with _carry_hash_dir.
# Arguments: $1 = manifest, $2 = cage_path (absolute), $3 = src_path
_carry_dir_matches_manifest() {
    local manifest="$1" cage_path="$2" src_path="$3"
    [ -f "$manifest" ] || return 1
    [ -d "$cage_path" ] || return 1

    local -A expected=()
    local h k
    while IFS=$'\t' read -r h k; do
        case "$k" in
            "$src_path"/*) expected["$k"]="$h" ;;
        esac
    done < "$manifest"

    local expected_count=${#expected[@]}
    local seen=0
    local f rel current
    while IFS= read -r -d '' f; do
        rel="${f#"$cage_path/"}"
        local key="$src_path/$rel"
        [ -n "${expected[$key]+_}" ] || return 1
        current=$(sha256sum < "$f" 2>/dev/null | awk '{print $1}') || return 1
        [ "$current" = "${expected[$key]}" ] || return 1
        seen=$((seen + 1))
    done < <(find "$cage_path" -type f ! -type l -print0 2>/dev/null)

    [ "$seen" -eq "$expected_count" ]
}

# Look up the startup snapshot hash for src_path from the manifest.
# Echoes empty when the manifest is missing or the path isn't in it.
# Arguments: $1 = manifest_path, $2 = src_path
_carry_lookup_snapshot() {
    local manifest="$1" key="$2"
    [ -f "$manifest" ] || return 0
    awk -v key="$key" -F'\t' '$2 == key { print $1; exit }' "$manifest"
}

# Copy carry files between source and work dir (outside git).
# Carry files are gitignored files that should persist across sessions
# (e.g., CLAUDE.md). Git-tracked files are skipped — git handles those.
# Entries with explicit dest (source != dest) bypass scope filtering and
# git-tracked checks, since the user explicitly mapped the path.
#
# Direction "to_work" (startup):
#   Copy source → work, then snapshot the cage's initial hash for each file
#   into <work>/.git/claude-cage-carry-hashes so the exit pass can tell what
#   the cage actually edited.
#
# Direction "from_cage" (exit):
#   Never touches source. For each carry entry:
#     - Hash matches snapshot → file wasn't touched in the cage. Announce
#       the skip so the user isn't left wondering.
#     - Hash differs (or snapshot missing) → cage edited it. If the project
#       has a .caged/ dir, deposit the cage's version at
#       .caged/carry/<display-session>/<src_path>. If .caged/ isn't there
#       (createCagedDir is off), say so out loud — those edits are lost.
#   Directories skip the hash check (carry dirs can mix tracked/untracked
#   entries with no reliable file-level hash) and always deposit when a
#   .caged dir exists.
#
# Arguments:
#   $1 - direction: "to_work" or "from_cage"
#   $2 - source_dir: The source project directory
#   $3 - work_dir: The cage work directory
#   $4 - scope_path: Scope path (empty for unscoped)
#   $5 - cfg_carry: ^-separated carry entries, each entry is source|dest
copy_carry_files() {
    local direction="$1"
    local source_dir="$2"
    local work_dir="$3"
    local scope_path="$4"
    local carry_str="$5"

    [ -z "$carry_str" ] && return 0

    local -a entries carried_names=() unchanged_names=() lost_names=()
    IFS='^' read -ra entries <<< "$carry_str"

    local manifest
    manifest=$(_carry_manifest_path "$work_dir")
    if [ "$direction" = "to_work" ]; then
        # Fresh manifest for this snapshot. Parent .git always exists at this
        # point (work dir created by clone before carry runs).
        : > "$manifest" 2>/dev/null || manifest=""
    fi

    # Compute the .caged deposit base for exit-time carries. Per-display-name
    # subdir keeps multiple sessions from clobbering each other and keeps
    # deposits OUT of .caged/sessions/<display>/ so they aren't torn down
    # when an alternate's session sidecar is removed on clean exit.
    local caged_carry_base="" display_label=""
    if [ "$direction" = "from_cage" ]; then
        local git_root
        git_root=$(get_git_root "$source_dir" 2>/dev/null) || git_root=""
        if [ -n "$git_root" ] && [ -d "$git_root/.caged" ]; then
            display_label=$(display_session_name "${CLAUDE_CAGE_SESSION:-default}")
            caged_carry_base="$git_root/.caged/carry/$display_label"
        fi
    fi

    for entry in "${entries[@]}"; do
        [ -z "$entry" ] && continue
        local src_path dest_path
        IFS='|' read -r src_path dest_path <<< "$entry"
        [ -z "$dest_path" ] && dest_path="$src_path"

        local has_explicit_dest=false
        [ "$src_path" != "$dest_path" ] && has_explicit_dest=true

        if [ "$has_explicit_dest" = false ]; then
            # Skip git-tracked files — git handles those through the normal pipeline.
            # Directories may contain a mix of tracked/untracked files, so always
            # carry them (tracked files are identical in both repos anyway).
            if [ ! -d "$source_dir/$src_path" ] && \
               git -C "$source_dir" ls-files --error-unmatch "$src_path" >/dev/null 2>&1; then
                continue
            fi

            # Scope filtering: skip files outside scope, strip prefix for work
            if [ -n "$scope_path" ]; then
                case "$src_path" in
                    "$scope_path/"*) dest_path="${src_path#"$scope_path/"}" ;;
                    *) continue ;;  # Outside scope, skip
                esac
            fi
        fi

        local cage_path="$work_dir/$dest_path"
        local source_path="$source_dir/$src_path"

        if [ "$direction" = "to_work" ]; then
            [ -e "$source_path" ] || continue

            if [ -d "$source_path" ]; then
                mkdir -p "$cage_path"
                [ -d "$cage_path" ] && chmod -R u+w "$cage_path" 2>/dev/null || true
                cp -a "$source_path/." "$cage_path/"
                # Snapshot per-file hashes so from_cage can tell if anything
                # inside the dir was touched.
                [ -n "$manifest" ] && _carry_hash_dir "$cage_path" "$src_path" >> "$manifest"
            else
                mkdir -p "$(dirname "$cage_path")"
                [ -f "$cage_path" ] && chmod u+w "$cage_path" 2>/dev/null || true
                cp -a "$source_path" "$cage_path"
                if [ -n "$manifest" ]; then
                    local _h
                    _h=$(_carry_hash_file "$source_path") || _h=""
                    [ -n "$_h" ] && printf '%s\t%s\n' "$_h" "$src_path" >> "$manifest"
                fi
            fi

            if [ "$has_explicit_dest" = true ]; then
                carried_names+=("$src_path -> $dest_path")
            else
                carried_names+=("$src_path")
            fi
            continue
        fi

        # direction = from_cage
        [ -e "$cage_path" ] || continue

        # Skip when nothing inside the cage's copy changed since startup.
        # Files compare against a single hash; dirs compare against the
        # per-file fragments _carry_hash_dir wrote.
        if [ -f "$cage_path" ] && [ ! -L "$cage_path" ]; then
            local snap current
            snap=$(_carry_lookup_snapshot "$manifest" "$src_path")
            current=$(_carry_hash_file "$cage_path") || current=""
            if [ -n "$snap" ] && [ -n "$current" ] && [ "$snap" = "$current" ]; then
                unchanged_names+=("$src_path")
                continue
            fi
        elif [ -d "$cage_path" ]; then
            if _carry_dir_matches_manifest "$manifest" "$cage_path" "$src_path"; then
                unchanged_names+=("$src_path")
                continue
            fi
        fi

        # Cage modified the file/dir (or no snapshot to compare against).
        if [ -z "$caged_carry_base" ]; then
            lost_names+=("$src_path")
            continue
        fi

        local deposit_path="$caged_carry_base/$src_path"
        mkdir -p "$(dirname "$deposit_path")"
        if [ -d "$cage_path" ]; then
            mkdir -p "$deposit_path"
            [ -d "$deposit_path" ] && chmod -R u+w "$deposit_path" 2>/dev/null || true
            cp -a "$cage_path/." "$deposit_path/"
        else
            [ -f "$deposit_path" ] && chmod u+w "$deposit_path" 2>/dev/null || true
            cp -a "$cage_path" "$deposit_path"
        fi
        carried_names+=("$src_path → .caged/carry/$display_label/$src_path")
    done

    if [ "$direction" = "to_work" ] && [ ${#carried_names[@]} -gt 0 ]; then
        local names_str
        names_str=$(IFS=', '; echo "${carried_names[*]}")
        echo "Carried $names_str into the cage."
        return 0
    fi

    # from_cage: report each category so the user knows where things ended up.
    local _n
    if [ ${#carried_names[@]} -gt 0 ]; then
        echo "Carried out of the cage:"
        for _n in "${carried_names[@]}"; do
            echo "  $_n"
        done
    fi
    if [ ${#unchanged_names[@]} -gt 0 ]; then
        for _n in "${unchanged_names[@]}"; do
            echo "Skippin' $_n — wasn't touched in this cage."
        done
    fi
    if [ ${#lost_names[@]} -gt 0 ]; then
        echo "Cage edited these carry files but .caged/ ain't set up — edits ain't bein' saved:"
        for _n in "${lost_names[@]}"; do
            echo "  $_n"
        done
        echo "  Set createCagedDir = true if you want 'em preserved."
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
    # Self-heal: if either marks file is missing (e.g., intermediary was
    # bootstrapped from an empty source repo so fast-export never wrote them),
    # create empty ones so subsequent appends and downstream fast-export
    # --import-marks calls don't fatal.
    touch "$source_marks_path" "$import_marks_path"
    local _max_mark _new_mark
    _max_mark=$(awk '{ gsub(/^:/,"",$1); id=$1+0; if(id>m) m=id } END { print m+0 }' \
        "$source_marks_path" "$import_marks_path" 2>/dev/null)
    _new_mark=$((_max_mark + 1))
    echo ":$_new_mark $source_hash" >> "$source_marks_path"
    echo ":$_new_mark $intermediary_hash" >> "$import_marks_path"
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
        # New branch - walk first-parents back to the most recent ancestor
        # that's already on source (either a sync_to_source mapping, or a
        # commit that was originally fast-imported from source). Sync
        # everything after that. For a brand-new repo with no such ancestor,
        # this includes the root commit.
        local _base=""
        local _walker="$newrev"
        while [ -n "$_walker" ]; do
            if [ -f "$commit_map_path" ] && grep -q "^${_walker} " "$commit_map_path" 2>/dev/null; then
                _base="$_walker"
                break
            fi
            if [ -f "$import_marks_path" ] && grep -q " ${_walker}$" "$import_marks_path" 2>/dev/null; then
                _base="$_walker"
                break
            fi
            _walker=$(git -C "$intermediary_dir" rev-parse --verify "${_walker}^" 2>/dev/null) || _walker=""
        done
        if [ -n "$_base" ]; then
            commits=$(git -C "$intermediary_dir" rev-list --first-parent --topo-order --reverse "${_base}..${newrev}" 2>/dev/null)
        else
            commits=$(git -C "$intermediary_dir" rev-list --first-parent --topo-order --reverse "$newrev" 2>/dev/null)
        fi
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

    # Divergence guard: if source's branch HEAD doesn't match where the cage
    # last left it (commit_map[oldrev]), source has moved independently —
    # either commits a hook failed to sync, or the user rewrote history.
    # Applying the cage's patches via git am --3way here would silently splice
    # the cage's commits onto a parent it never built on. Bail loudly instead
    # and let the user pick a recovery path.
    #
    # Exception: source commits already mapped to "0" in commit_map are
    # excluded-only — the cage was told about them and chose to ignore them.
    # If the entire gap between expected and actual is excluded-only commits,
    # there's no real divergence; let the apply proceed.
    if [ "${cfg_forceMerge:-}" != "true" ] \
       && [ "$oldrev" != "0000000000000000000000000000000000000000" ] \
       && [ -n "$oldrev" ]; then
        local _expected_source=""
        if [ -f "$commit_map_path" ]; then
            _expected_source=$(awk -v ih="$oldrev" '$1 == ih { print $2; exit }' "$commit_map_path")
        fi
        if [ -n "$_expected_source" ] && [ "$_expected_source" != "0" ]; then
            local _source_branch_hash=""
            _source_branch_hash=$(git -C "$source_dir" rev-parse --verify "refs/heads/$branch_name" 2>/dev/null) || true
            if [ -n "$_source_branch_hash" ] && [ "$_source_branch_hash" != "$_expected_source" ]; then
                local _gap_desc="moved off the cage's map"
                local _real_divergence=true
                if git -C "$source_dir" merge-base --is-ancestor "$_expected_source" "$_source_branch_hash" 2>/dev/null; then
                    # Source is strictly ahead. Are the intermediate commits all excluded-only?
                    local _gap_total=0 _gap_excluded=0
                    local _ic
                    while IFS= read -r _ic; do
                        [ -z "$_ic" ] && continue
                        _gap_total=$((_gap_total + 1))
                        if grep -q "^0 ${_ic}$" "$commit_map_path" 2>/dev/null; then
                            _gap_excluded=$((_gap_excluded + 1))
                        fi
                    done < <(git -C "$source_dir" rev-list --reverse "${_expected_source}..${_source_branch_hash}" 2>/dev/null)
                    if [ "$_gap_total" -gt 0 ] && [ "$_gap_excluded" = "$_gap_total" ]; then
                        _real_divergence=false
                        sync_log "$log_file" "$newrev_short" ">>source" "source advanced by $_gap_total excluded-only commit(s), ok"
                    else
                        _gap_desc="ahead by $_gap_total commit(s) ($_gap_excluded excluded-only)"
                    fi
                elif git -C "$source_dir" merge-base --is-ancestor "$_source_branch_hash" "$_expected_source" 2>/dev/null; then
                    # Source is strictly behind expected — an earlier sync
                    # was missed (failed hook, manual reset) and the cage
                    # is now N commits ahead of where source actually is.
                    # If source's HEAD has a mapping on this branch, we
                    # can recover by recomputing oldrev from it: the new
                    # range covers every commit source needs to catch up,
                    # not just the ones since the push's stale oldrev.
                    local _recovered=""
                    _recovered=$(_find_intermediary_for_source_head "$intermediary_dir" "$refname" "$commit_map_path" "$_source_branch_hash")
                    if [ -n "$_recovered" ]; then
                        local _gap_count
                        _gap_count=$(git -C "$intermediary_dir" rev-list --first-parent --count "${_recovered}..${newrev}" 2>/dev/null)
                        echo "Source was behind by ${_gap_count} commit(s) — catchin' up."
                        sync_log "$log_file" "$newrev_short" ">>source" "source behind, recovered oldrev=${_recovered:0:8} (gap=${_gap_count})"
                        oldrev="$_recovered"
                        commits=$(git -C "$intermediary_dir" rev-list --first-parent --topo-order --reverse "${oldrev}..${newrev}" 2>/dev/null)
                        _real_divergence=false
                    else
                        _gap_desc="behind the cage (no map for source HEAD ${_source_branch_hash:0:8})"
                    fi
                else
                    _gap_desc="on unrelated history"
                fi

                if [ "$_real_divergence" = true ]; then
                    echo -e "${_red}claude-cage:${_reset} Hold on. Source's $branch_name has diverged from the cage." >&2
                    echo "  Cage expected:   ${_expected_source:0:8}" >&2
                    echo "  Source actually: ${_source_branch_hash:0:8} ($_gap_desc)" >&2
                    echo "  Pick your poison:" >&2
                    echo "    claude-cage git-merge --force      apply the cage's commits anyway via 3-way merge" >&2
                    echo "    claude-cage clean --all            start over with the source as it stands" >&2
                    sync_log "$log_file" "$newrev_short" ">>source" "DIVERGED: source=${_source_branch_hash:0:8} expected=${_expected_source:0:8} ($_gap_desc)"
                    return 0
                fi
            fi
        fi
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

        echo "  ${commit_short}: ${commit_msg:0:50}"

        # First parent on intermediary (empty = root commit from the cage)
        local cage_first_parent=""
        cage_first_parent=$(git -C "$intermediary_dir" rev-parse --verify "${commit}^" 2>/dev/null) || true

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
                break
            fi

            local source_first_parent
            source_first_parent=$(git -C "$source_dir" rev-parse "$branch_name" 2>/dev/null)

            if [ -z "$source_first_parent" ]; then
                echo "  Can't sync merge — branch $branch_name don't exist on source."
                save_failed_patch "$source_dir" "from-intermediary" "$patch" "$branch_name" "$commit_msg" "" "$scope_path"
                sync_log "$log_file" "$commit_short" ">>source" "merge FAILED: branch $branch_name missing on source"
                break
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
                    exit 1
                fi
            )
            local _merge_rc=$?
            rm -f "$tmp_index"
            [ "$_merge_rc" -ne 0 ] && break
            continue
        fi

        # Root commit from the cage (no parent on intermediary). Apply with no
        # parent via commit-tree so a brand-new source repo gets its history.
        if [ -z "$cage_first_parent" ]; then
            local source_branch_hash=""
            source_branch_hash=$(git -C "$source_dir" rev-parse --verify "refs/heads/$branch_name" 2>/dev/null) || true

            if [ -n "$source_branch_hash" ]; then
                echo "  Cage has a root commit but source already has history on $branch_name."
                save_failed_patch "$source_dir" "from-intermediary" "$patch" "$branch_name" "$commit_msg" "" "$scope_path"
                sync_log "$log_file" "$commit_short" ">>source" "root commit FAILED: $branch_name has history on source"
                break
            fi

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
                git read-tree --empty

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

                    new_commit=$(git commit-tree "$tree" -m "$commit_full_msg")

                    unset GIT_INDEX_FILE
                    CLAUDE_CAGE_SYNCING="$_sync_hash" git update-ref "refs/heads/$branch_name" "$new_commit"

                    local _current
                    _current=$(git branch --show-current 2>/dev/null)
                    if [ "$_current" = "$branch_name" ]; then
                        git reset --hard 2>/dev/null
                    fi

                    update_marks_after_sync "$new_commit" "$commit" "$commit_map_path" "$source_marks_path" "$import_marks_path"
                    echo "  Got it. First commit's in on $branch_name."
                    sync_log "$log_file" "$commit_short" ">>source" "root commit ok on $branch_name new=${new_commit:0:8}"
                else
                    echo "  Root commit didn't apply clean to $branch_name."
                    save_failed_patch "$source_dir" "from-intermediary" "$patch" "$branch_name" "$commit_msg" "" "$scope_path"
                    sync_log "$log_file" "$commit_short" ">>source" "root commit FAILED on $branch_name: $(echo "$apply_output" | tail -1)"
                    exit 1
                fi
            )
            local _root_rc=$?
            rm -f "$tmp_index"
            [ "$_root_rc" -ne 0 ] && break
            continue
        fi

        # Check if source has this branch
        local source_has_branch=true
        if ! git -C "$source_dir" rev-parse --verify "$branch_name" >/dev/null 2>&1; then
            source_has_branch=false
            # New branch - find parent in mapping
            local parent_hash
            parent_hash="$cage_first_parent"
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
                break
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
                    exit 1
                fi
            )
            local _apply_rc=$?
            rm -f "$tmp_index"
            [ "$_apply_rc" -ne 0 ] && break
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
        # Clean files dirtied by build watchers/dev servers after git am
        # (e.g., auto-generated type declarations like components.d.ts).
        # The stash pop restores the user's actual dirty files.
        git -C "$source_dir" checkout -- . 2>/dev/null || true
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

# Find the intermediary commit on a branch's first-parent chain whose
# commit_map entry equals the given source hash. This is the "real base"
# when source's branch HEAD has drifted from where commit_map says it
# should be — e.g., an earlier sync was missed (failed hook) or source
# was manually reset. Using this as oldrev produces a range that covers
# every commit source actually needs to catch up.
# Arguments:
#   $1 - intermediary_dir
#   $2 - branch ref or name
#   $3 - commit_map_path
#   $4 - source_hash to look up
# Outputs: intermediary hash, or empty if no match.
_find_intermediary_for_source_head() {
    local intermediary_dir="$1"
    local branch="$2"
    local commit_map_path="$3"
    local source_hash="$4"

    [ ! -f "$commit_map_path" ] && return 0
    [ -z "$source_hash" ] && return 0

    local ancestor
    for ancestor in $(git -C "$intermediary_dir" rev-list --first-parent "$branch" 2>/dev/null); do
        local mapped
        mapped=$(awk -v ih="$ancestor" '$1 == ih { print $2; exit }' "$commit_map_path")
        if [ "$mapped" = "$source_hash" ]; then
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

    # Prefer the intermediary commit that maps to source's actual branch
    # HEAD — that's the real base. _find_last_mapped_on_branch returns
    # the latest commit with ANY mapping, which silently drops commits
    # when source has drifted (failed hook, manual reset on source).
    # Fall back to the latest-mapped commit when source HEAD isn't in
    # commit_map (e.g., user committed directly on source without hooks
    # firing — the "ahead with real commits" case, which --force still
    # handles via 3-way merge onto source's current HEAD).
    local oldrev=""
    local source_head
    source_head=$(git -C "$source_dir" rev-parse --verify "refs/heads/$branch" 2>/dev/null) || true
    if [ -n "$source_head" ]; then
        oldrev=$(_find_intermediary_for_source_head "$intermediary_dir" "$branch" "$commit_map_path" "$source_head")
    fi
    if [ -z "$oldrev" ]; then
        oldrev=$(_find_last_mapped_on_branch "$intermediary_dir" "$branch" "$commit_map_path")
    fi
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
#   $5 - force_flag: "true" to bypass the divergence guard (applies via 3-way merge)
manual_git_merge() {
    local source_dir="$1"
    local scope_path="${2:-}"
    local target_branch="${3:-}"
    local all_flag="${4:-false}"
    local force_flag="${5:-false}"

    # Plumb force through to sync_to_source via cfg_forceMerge. main.sh exits
    # right after manual_git_merge returns, so no need to restore.
    if [ "$force_flag" = true ]; then
        cfg_forceMerge="true"
    fi

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
