# ============================================================================
# Git hooks and communication pipe
# ============================================================================

# ============================================================================
# Session tracking (prevents cleanup race conditions with multiple sessions)
# ============================================================================

# Get the session directory for a source project
# Sessions are tracked in runtime dir (cleared on reboot), per-project (path hash)
get_session_dir() {
    local source_dir="$1"
    local path_hash
    path_hash=$(path_hash "$source_dir")
    echo "$CLAUDE_CAGE_RUNTIME/sessions/$path_hash"
}

# Register this session (create PID file containing session ID)
register_session() {
    local source_dir="$1"
    local session_dir
    session_dir=$(get_session_dir "$source_dir")

    if [ "$dry_run" = true ]; then
        echo "[dry-run] register session at $session_dir/$$"
    else
        mkdir -p "$session_dir"
        echo "${CLAUDE_CAGE_SESSION:-}" > "$session_dir/$$"
    fi
}

# Unregister this session (remove PID file)
unregister_session() {
    local source_dir="$1"
    local session_dir
    session_dir=$(get_session_dir "$source_dir")

    if [ "$dry_run" = true ]; then
        echo "[dry-run] unregister session at $session_dir/$$"
    else
        rm -f "$session_dir/$$"
        # Clean up empty directories
        rmdir "$session_dir" 2>/dev/null || true
    fi
}

# Check if other sessions exist for this source project
# Returns 0 (true) if other sessions exist, 1 (false) if not
has_other_sessions() {
    local source_dir="$1"
    local session_dir
    session_dir=$(get_session_dir "$source_dir")

    if [ ! -d "$session_dir" ]; then
        return 1  # no sessions at all
    fi

    # Check for other PID files (not ours)
    local count=0
    for pidfile in "$session_dir"/*; do
        [ -f "$pidfile" ] || continue
        local pid
        pid=$(basename "$pidfile")
        if [ "$pid" != "$$" ]; then
            # Check if process is still running
            if kill -0 "$pid" 2>/dev/null; then
                count=$((count + 1))
            else
                # Stale PID file, clean it up
                rm -f "$pidfile"
            fi
        fi
    done

    [ $count -gt 0 ]
}

# Check if ANY sessions exist for a source directory (including our own)
# Returns 0 (true) if any sessions exist, 1 (false) if not
has_any_sessions() {
    local source_dir="$1"
    local session_dir
    session_dir=$(get_session_dir "$source_dir")

    if [ ! -d "$session_dir" ]; then
        return 1
    fi

    for pidfile in "$session_dir"/*; do
        [ -f "$pidfile" ] || continue
        local pid
        pid=$(basename "$pidfile")
        if kill -0 "$pid" 2>/dev/null; then
            return 0
        else
            rm -f "$pidfile"
        fi
    done

    return 1
}

# ============================================================================
# Orphaned hook cleanup
# ============================================================================

# Clean up orphaned hooks (hooks pointing to non-existent cages)
# This handles the case where a crash/SIGKILL prevented normal cleanup
# Arguments: $1 = source directory (git root)
cleanup_orphaned_hooks() {
    local source_dir="$1"
    local git_root
    git_root=$(get_git_root "$source_dir")

    if [ -z "$git_root" ] || [ ! -d "$git_root/.git/hooks" ]; then
        return 0
    fi

    local cleaned=0

    # Check post-commit hooks
    if [ -d "$git_root/.git/hooks/post-commit.d" ]; then
        for hook in "$git_root/.git/hooks/post-commit.d"/claude-cage-*; do
            [ -f "$hook" ] || continue

            # Extract INTERMEDIARY from the hook
            local intermediary_dir
            intermediary_dir=$(grep '^INTERMEDIARY=' "$hook" 2>/dev/null | head -1 | cut -d'"' -f2)

            if [ -n "$intermediary_dir" ] && [ ! -d "$intermediary_dir" ]; then
                verbose_log "Removing orphaned hook: $hook"
                rm -f "$hook"
                cleaned=$((cleaned + 1))
            fi
        done
        maybe_remove_dispatcher "$git_root" "post-commit"
    fi

    # Check post-merge hooks
    if [ -d "$git_root/.git/hooks/post-merge.d" ]; then
        for hook in "$git_root/.git/hooks/post-merge.d"/claude-cage-*; do
            [ -f "$hook" ] || continue

            local intermediary_dir
            intermediary_dir=$(grep '^INTERMEDIARY=' "$hook" 2>/dev/null | head -1 | cut -d'"' -f2)

            if [ -n "$intermediary_dir" ] && [ ! -d "$intermediary_dir" ]; then
                verbose_log "Removing orphaned hook: $hook"
                rm -f "$hook"
                cleaned=$((cleaned + 1))
            fi
        done
        maybe_remove_dispatcher "$git_root" "post-merge"
    fi

    # Also clean up any leftover pre-commit hooks from old architecture
    if [ -d "$git_root/.git/hooks/pre-commit.d" ]; then
        for hook in "$git_root/.git/hooks/pre-commit.d"/claude-cage-*; do
            [ -f "$hook" ] || continue
            verbose_log "Removing legacy pre-commit hook: $hook"
            rm -f "$hook"
            cleaned=$((cleaned + 1))
        done
        maybe_remove_dispatcher "$git_root" "pre-commit"
    fi

    if [ "$cleaned" -gt 0 ]; then
        echo "Cleaned up $cleaned orphaned hook(s) from previous session."
    fi
}

# ============================================================================
# Hook dispatcher (allows multiple hooks to coexist)
# ============================================================================

# Ensure the hook dispatcher exists for a given hook type
# The dispatcher runs all scripts in <hook>.d/
ensure_hook_dispatcher() {
    local source_dir="$1"
    local hook_type="$2"  # e.g., "post-commit"
    local hook_path="$source_dir/.git/hooks/$hook_type"
    local hook_dir="$source_dir/.git/hooks/${hook_type}.d"

    # Create the .d directory
    mkdir -p "$hook_dir"

    # If hook doesn't exist or isn't our dispatcher, set it up
    if [ ! -f "$hook_path" ] || ! grep -q "claude-cage-dispatcher" "$hook_path" 2>/dev/null; then
        # If existing hook, preserve it
        if [ -f "$hook_path" ] && [ ! -L "$hook_path" ]; then
            mv "$hook_path" "$hook_dir/00-original"
            chmod +x "$hook_dir/00-original"
        fi

        # Create dispatcher
        cat > "$hook_path" << 'DISPATCHER'
#!/bin/bash
# claude-cage-dispatcher: runs all hooks in <hook>.d/
HOOK_DIR="$(dirname "$0")/$(basename "$0").d"
if [ -d "$HOOK_DIR" ]; then
    for hook in "$HOOK_DIR"/*; do
        [ -x "$hook" ] && "$hook" "$@"
    done
fi
DISPATCHER
        chmod +x "$hook_path"
    fi
}

# Remove dispatcher if no hooks remain in .d directory
maybe_remove_dispatcher() {
    local source_dir="$1"
    local hook_type="$2"
    local hook_path="$source_dir/.git/hooks/$hook_type"
    local hook_dir="$source_dir/.git/hooks/${hook_type}.d"

    if [ -d "$hook_dir" ]; then
        # Check if only original hook remains or directory is empty
        local remaining
        remaining=$(ls -A "$hook_dir" 2>/dev/null | wc -l)

        if [ "$remaining" -eq 0 ]; then
            # Empty, remove dispatcher
            rm -f "$hook_path"
            rmdir "$hook_dir"
        elif [ "$remaining" -eq 1 ] && [ -f "$hook_dir/00-original" ]; then
            # Only original remains, restore it
            mv "$hook_dir/00-original" "$hook_path"
            rmdir "$hook_dir"
        fi
    fi
}

# ============================================================================
# Named pipe and intermediary hooks
# ============================================================================

# Set up named pipe for cage communication
# Arguments:
#   $1 - pipe_path: The pipe file path
setup_pipe() {
    local pipe_path="$1"

    # Create parent directory for pipe if needed
    local pipe_dir
    pipe_dir=$(dirname "$pipe_path")
    run mkdir -p "$pipe_dir"

    # Create named pipe for communication (always fresh)
    run rm -f "$pipe_path"
    run mkfifo -m 0600 "$pipe_path"

    verbose_log "  Created pipe: $pipe_path"
}

# Set up git hooks on intermediary (called by create_intermediary_clone)
# The intermediary hooks are installed by install_intermediary_hooks in git-clone.sh
# This function sets up the named pipe only
setup_git_hooks() {
    local source_dir="$1"
    local intermediary_dir="$2"
    local pipe_path="$3"

    setup_pipe "$pipe_path"

    # Re-install intermediary hooks (in case pipe path changed)
    if [ "$dry_run" != true ]; then
        install_intermediary_hooks "$intermediary_dir"
    fi

    verbose_log "  Set up hooks on intermediary"
}

# Clean up the named pipe
# Arguments:
#   $1 - pipe_path: The pipe file path
cleanup_pipe() {
    local pipe_path="$1"

    if [ -p "$pipe_path" ]; then
        run rm -f "$pipe_path"
    fi
}

# Clean up source repo hooks
# Only removes hooks if no other sessions are using them
# Arguments:
#   $1 - source_dir: The source project directory
cleanup_source_hooks() {
    local source_dir="$1"

    # Check if other sessions still need the hooks
    if has_other_sessions "$source_dir"; then
        verbose_log "  Other sessions active, keepin' hooks for this project"
        return 0
    fi

    # Use git root for hook paths (supports running from subdirectories)
    local git_root
    git_root=$(get_git_root "$source_dir")

    # No other sessions, safe to remove project-specific hooks
    local path_hash
    path_hash=$(path_hash "$source_dir")
    local post_commit_hook="$git_root/.git/hooks/post-commit.d/claude-cage-$path_hash"
    local post_merge_hook="$git_root/.git/hooks/post-merge.d/claude-cage-$path_hash"

    if [ -f "$post_commit_hook" ]; then
        run rm -f "$post_commit_hook"
        verbose_log "  Removed hook: $post_commit_hook"
        maybe_remove_dispatcher "$git_root" "post-commit"
    fi

    if [ -f "$post_merge_hook" ]; then
        run rm -f "$post_merge_hook"
        verbose_log "  Removed hook: $post_merge_hook"
        maybe_remove_dispatcher "$git_root" "post-merge"
    fi
}

# Set up post-commit hook on source repo to sync commits to intermediary
# Uses fast-export with :(exclude,glob) pathspec for robust handling of mixed commits
# Arguments:
#   $1 - source_dir: The source project directory
#   $2 - exclude_patterns: Pipe-delimited exclude patterns (e.g., ".env|secrets/**")
#   $3 - intermediary_dir: The bare intermediary directory
setup_source_post_commit() {
    local source_dir="$1"
    local exclude_patterns="$2"
    local intermediary_dir="$3"
    local path_hash
    path_hash=$(path_hash "$source_dir")
    # Use git root for hook installation (supports running from subdirectories)
    local git_root
    git_root=$(get_git_root "$source_dir")
    local hook_path="$git_root/.git/hooks/post-commit.d/claude-cage-$path_hash"

    # Ensure dispatcher exists (at git root, not source_dir)
    if [ "$dry_run" != true ]; then
        ensure_hook_dispatcher "$git_root" "post-commit"
    fi

    # Read scope_path from intermediary metadata (empty for unscoped)
    local scope_path=""
    local scope_path_file
    scope_path_file=$(get_scope_path_file "$intermediary_dir")
    if [ -f "$scope_path_file" ]; then
        scope_path=$(cat "$scope_path_file")
    fi

    # Get paths for marks, commit map, and exclude pathspecs metadata inside intermediary
    local source_marks_path
    source_marks_path=$(get_source_marks_path "$intermediary_dir")
    local import_marks_path
    import_marks_path=$(get_import_marks_path "$intermediary_dir")
    local commit_map_path
    commit_map_path=$(get_commit_map_path "$intermediary_dir")
    local exclude_pathspecs_file
    exclude_pathspecs_file=$(get_exclude_pathspecs_file "$intermediary_dir")

    # Create post-commit hook
    if [ "$dry_run" = true ]; then
        echo "[dry-run] create $hook_path"
    else
        cat > "$hook_path" << EOF
#!/bin/bash
# claude-cage: sync commits to intermediary using fast-export + pathspec excludes
INTERMEDIARY="$intermediary_dir"
SOURCE_DIR="$source_dir"
SOURCE_MARKS="$source_marks_path"
IMPORT_MARKS="$import_marks_path"
COMMIT_MAP="$commit_map_path"
SYNC_LOG="\$INTERMEDIARY/sync.log"
SCOPE_PATH="$scope_path"
SCOPE_LABEL=""
[ -n "\$SCOPE_PATH" ] && SCOPE_LABEL=" (\$SCOPE_PATH)"
EXCLUDE_PATHSPECS_FILE="$exclude_pathspecs_file"

_sync_log() {
    printf '[%s] %s %-14s %s\n' "\$(date '+%Y-%m-%d %H:%M:%S')" "\$1" "\$2" "\$3" >> "\$SYNC_LOG"
}

if [ ! -d "\$INTERMEDIARY" ]; then
    exit 0  # cage not set up yet
fi

COMMIT_SHORT=\$(git rev-parse --short=8 HEAD)
COMMIT_HASH=\$(git rev-parse HEAD)

# Create branch in intermediary if it doesn't exist yet (e.g. new branch in source,
# or scoped intermediary where the branch had no unique in-scope commits at creation)
current_branch=\$(git branch --show-current)
if ! git -C "\$INTERMEDIARY" rev-parse --verify "\$current_branch" >/dev/null 2>&1; then
    DEFAULT_BRANCH=\$(git -C "\$INTERMEDIARY" symbolic-ref --short HEAD 2>/dev/null)
    if [ -n "\$DEFAULT_BRANCH" ]; then
        DEFAULT_HEAD=\$(git -C "\$INTERMEDIARY" rev-parse "\$DEFAULT_BRANCH" 2>/dev/null)
        if [ -n "\$DEFAULT_HEAD" ]; then
            git -C "\$INTERMEDIARY" branch "\$current_branch" "\$DEFAULT_HEAD" 2>/dev/null || true
            _sync_log "\$COMMIT_SHORT" ">>intermediary" "created branch \$current_branch from \$DEFAULT_BRANCH"
        else
            _sync_log "\$COMMIT_SHORT" ">>intermediary" "skipped: no default branch HEAD to create \$current_branch"
            exit 0
        fi
    else
        _sync_log "\$COMMIT_SHORT" ">>intermediary" "skipped: can't create branch \$current_branch (no default branch)"
        exit 0
    fi
fi

# Skip during sync_to_source (git-am triggers post-commit; marks handled by sync).
# Any non-empty value means a sync is in progress — all hooks skip.
# Cross-level propagation is handled explicitly by propagate_to_sibling_intermediaries().
[ -n "\${CLAUDE_CAGE_SYNCING:-}" ] && exit 0

# Check commit mapping: already mapped -> skip (loop prevention)
if [ -f "\$COMMIT_MAP" ] && grep -q " \${COMMIT_HASH}\$" "\$COMMIT_MAP"; then
    _sync_log "\$COMMIT_SHORT" ">>intermediary" "already mapped, skipping (loop prevention)"
    exit 0
fi

export INTERMEDIARY SOURCE_MARKS IMPORT_MARKS COMMIT_MAP SYNC_LOG SCOPE_PATH SCOPE_LABEL EXCLUDE_PATHSPECS_FILE
"\$INTERMEDIARY/claude-cage-sync-commit" "\$COMMIT_HASH"
EOF
        chmod +x "$hook_path"
    fi

    verbose_log "  Created source hook: $hook_path"
}

# Set up post-merge hook on source repo to sync merges to intermediary
# git merge does NOT trigger post-commit — it triggers post-merge instead.
# This hook walks ORIG_HEAD..HEAD and syncs each unmapped commit via the
# shared claude-cage-sync-commit helper.
# Arguments:
#   $1 - source_dir: The source project directory
#   $2 - exclude_patterns: Pipe-delimited exclude patterns
#   $3 - intermediary_dir: The bare intermediary directory
setup_source_post_merge() {
    local source_dir="$1"
    local exclude_patterns="$2"
    local intermediary_dir="$3"
    local path_hash
    path_hash=$(path_hash "$source_dir")
    local git_root
    git_root=$(get_git_root "$source_dir")
    local hook_path="$git_root/.git/hooks/post-merge.d/claude-cage-$path_hash"

    if [ "$dry_run" != true ]; then
        ensure_hook_dispatcher "$git_root" "post-merge"
    fi

    # Read scope_path from intermediary metadata (empty for unscoped)
    local scope_path=""
    local scope_path_file
    scope_path_file=$(get_scope_path_file "$intermediary_dir")
    if [ -f "$scope_path_file" ]; then
        scope_path=$(cat "$scope_path_file")
    fi

    # Get paths for marks, commit map, and exclude pathspecs metadata inside intermediary
    local source_marks_path
    source_marks_path=$(get_source_marks_path "$intermediary_dir")
    local import_marks_path
    import_marks_path=$(get_import_marks_path "$intermediary_dir")
    local commit_map_path
    commit_map_path=$(get_commit_map_path "$intermediary_dir")
    local exclude_pathspecs_file
    exclude_pathspecs_file=$(get_exclude_pathspecs_file "$intermediary_dir")

    if [ "$dry_run" = true ]; then
        echo "[dry-run] create $hook_path"
    else
        cat > "$hook_path" << EOF
#!/bin/bash
# claude-cage: sync merge commits to intermediary
INTERMEDIARY="$intermediary_dir"
SOURCE_DIR="$source_dir"
SOURCE_MARKS="$source_marks_path"
IMPORT_MARKS="$import_marks_path"
COMMIT_MAP="$commit_map_path"
SYNC_LOG="\$INTERMEDIARY/sync.log"
SCOPE_PATH="$scope_path"
SCOPE_LABEL=""
[ -n "\$SCOPE_PATH" ] && SCOPE_LABEL=" (\$SCOPE_PATH)"
EXCLUDE_PATHSPECS_FILE="$exclude_pathspecs_file"

_sync_log() {
    printf '[%s] %s %-14s %s\n' "\$(date '+%Y-%m-%d %H:%M:%S')" "\$1" "\$2" "\$3" >> "\$SYNC_LOG"
}

if [ ! -d "\$INTERMEDIARY" ]; then
    exit 0  # cage not set up yet
fi

# Skip squash merges (\$1=1) — post-commit handles the eventual commit
if [ "\${1:-0}" = "1" ]; then
    exit 0
fi

# Skip during sync_to_source (git-am triggers hooks; marks handled by sync).
[ -n "\${CLAUDE_CAGE_SYNCING:-}" ] && exit 0

# Get ORIG_HEAD (set by git merge to the pre-merge HEAD)
ORIG_HEAD=\$(git rev-parse ORIG_HEAD 2>/dev/null) || exit 0

# Walk commits from ORIG_HEAD to HEAD (the merge brought these in)
for COMMIT_HASH in \$(git rev-list --reverse ORIG_HEAD..HEAD); do
    COMMIT_SHORT=\${COMMIT_HASH:0:8}

    # Skip if already in commit mapping (loop prevention)
    if [ -f "\$COMMIT_MAP" ] && grep -q " \${COMMIT_HASH}\$" "\$COMMIT_MAP"; then
        _sync_log "\$COMMIT_SHORT" ">>intermediary" "already mapped, skipping (loop prevention)"
        continue
    fi

    # Create branch in intermediary if it doesn't exist yet
    current_branch=\$(git branch --show-current)
    if ! git -C "\$INTERMEDIARY" rev-parse --verify "\$current_branch" >/dev/null 2>&1; then
        DEFAULT_BRANCH=\$(git -C "\$INTERMEDIARY" symbolic-ref --short HEAD 2>/dev/null)
        if [ -n "\$DEFAULT_BRANCH" ]; then
            DEFAULT_HEAD=\$(git -C "\$INTERMEDIARY" rev-parse "\$DEFAULT_BRANCH" 2>/dev/null)
            if [ -n "\$DEFAULT_HEAD" ]; then
                git -C "\$INTERMEDIARY" branch "\$current_branch" "\$DEFAULT_HEAD" 2>/dev/null || true
                _sync_log "\$COMMIT_SHORT" ">>intermediary" "created branch \$current_branch from \$DEFAULT_BRANCH"
            else
                _sync_log "\$COMMIT_SHORT" ">>intermediary" "skipped: no default branch HEAD to create \$current_branch"
                continue
            fi
        else
            _sync_log "\$COMMIT_SHORT" ">>intermediary" "skipped: can't create branch \$current_branch (no default branch)"
            continue
        fi
    fi

    export INTERMEDIARY SOURCE_MARKS IMPORT_MARKS COMMIT_MAP SYNC_LOG SCOPE_PATH SCOPE_LABEL EXCLUDE_PATHSPECS_FILE
    "\$INTERMEDIARY/claude-cage-sync-commit" "\$COMMIT_HASH"
done
EOF
        chmod +x "$hook_path"
    fi

    verbose_log "  Created source hook: $hook_path"
}

# Set up pre-commit hook on work repo for cage safety checks:
# - Block merge commits in scoped intermediaries (unreliable without full tree)
# - Require merge targets to be pushed first in unscoped intermediaries
# - Block force-added gitignored files (breaks patch-based sync)
# Arguments:
#   $1 - work_dir: The work directory (Claude's workspace)
#   $2 - scope_path: (optional) Scope path for scoped intermediaries
setup_work_pre_commit() {
    local work_dir="$1"
    local scope_path="${2:-}"
    local hook_path="$work_dir/.git/hooks/pre-commit"

    if [ "$dry_run" = true ]; then
        echo "[dry-run] create $hook_path (work pre-commit checks)"
        return
    fi

    cat > "$hook_path" << EOF
#!/bin/bash
# claude-cage: work directory pre-commit checks
EOF

    # Block merge commits in scoped intermediaries
    if [ -n "$scope_path" ]; then
        cat >> "$hook_path" << EOF

# Scoped intermediaries only have files within their scope ($scope_path/).
# Merges can't be reliably performed because out-of-scope commits are dropped,
# making the merge base and conflict detection unreliable.
# Merge from source instead, then let the cage sync pick up the result.
if [ -f .git/MERGE_HEAD ]; then
    echo "Hold on. Merges ain't allowed in a scoped cage ($scope_path)."
    echo "The intermediary only has files from this scope — merges could go sideways."
    echo ""
    echo "Run 'git merge --abort' to undo, then merge on your source repo instead."
    exit 1
fi
EOF
    else
        cat >> "$hook_path" << 'EOF'

# Merge targets must be pushed to remote (intermediary) first.
# sync_to_source needs both parents mapped to create a real merge on source.
merge_head=$(git rev-parse --verify MERGE_HEAD 2>/dev/null) || true
if [ -n "$merge_head" ]; then
    if ! git branch -r --contains "$merge_head" 2>/dev/null | grep -q .; then
        echo "Hold on. That branch ain't been pushed to the remote yet."
        echo "Push it first so the merge can sync back to source properly."
        echo ""
        echo "Run 'git merge --abort' to undo, push your branch, then merge again."
        exit 1
    fi
fi
EOF
    fi

    cat >> "$hook_path" << 'HOOKEOF'

# Block force-added gitignored files (breaks patch-based sync)
# Only catches files newly added to the index (--diff-filter=A) that are ignored,
# i.e. files that required "git add -f". Already-tracked files that happen to match
# a gitignore pattern are fine — they were inherited from the source repo.
# Override: CLAUDE_CAGE_ALLOW_IGNORED=1 git commit
if [ "${CLAUDE_CAGE_ALLOW_IGNORED:-}" != "1" ]; then
    NEWLY_ADDED=$(git diff --cached --name-only --diff-filter=A 2>/dev/null)
    if [ -n "$NEWLY_ADDED" ]; then
        FORCE_ADDED=$(echo "$NEWLY_ADDED" | git check-ignore --stdin 2>/dev/null || true)
    else
        FORCE_ADDED=""
    fi
    if [ -n "$FORCE_ADDED" ]; then
        echo "Hold on there. You've got gitignored files force-added to this commit."
        echo "That's gonna break the sync back to source."
        echo ""
        echo "Files:"
        echo "$FORCE_ADDED" | sed 's/^/  /'
        echo ""
        echo "To unstage 'em:"
        echo "  git reset HEAD <file>"
        echo ""
        echo "If you really know what you're doin':"
        echo "  CLAUDE_CAGE_ALLOW_IGNORED=1 git commit"
        exit 1
    fi
fi

exit 0
HOOKEOF
    chmod +x "$hook_path"

    # Block clean merges via pre-merge-commit hook (pre-commit only fires for
    # conflict-resolved merges where the user runs `git commit` manually)
    local merge_hook_path="$work_dir/.git/hooks/pre-merge-commit"
    if [ -n "$scope_path" ]; then
        cat > "$merge_hook_path" << EOF
#!/bin/bash
# claude-cage: block merge commits in scoped cage ($scope_path)
# Scoped intermediaries only have files within their scope.
# Merges can't be reliably performed because out-of-scope commits are dropped,
# making the merge base and conflict detection unreliable.
echo "Hold on. Merges ain't allowed in a scoped cage ($scope_path)."
echo "The intermediary only has files from this scope — merges could go sideways."
echo ""
echo "Run 'git merge --abort' to undo, then merge on your source repo instead."
exit 1
EOF
        chmod +x "$merge_hook_path"
    else
        cat > "$merge_hook_path" << 'EOF'
#!/bin/bash
# claude-cage: require merge targets to be pushed to remote first
# sync_to_source needs both parents mapped to create a real merge on source.
# Note: MERGE_HEAD doesn't exist yet when pre-merge-commit runs,
# so we extract the merge target from GIT_REFLOG_ACTION instead.
merge_branch="${GIT_REFLOG_ACTION#merge }"
if [ -n "$merge_branch" ] && [ "$merge_branch" != "$GIT_REFLOG_ACTION" ]; then
    merge_head=$(git rev-parse --verify "$merge_branch" 2>/dev/null) || true
    if [ -n "$merge_head" ]; then
        if ! git branch -r --contains "$merge_head" 2>/dev/null | grep -q .; then
            echo "Hold on. That branch ain't been pushed to the remote yet."
            echo "Push it first so the merge can sync back to source properly."
            echo ""
            echo "Run 'git merge --abort' to undo, push your branch, then merge again."
            exit 1
        fi
    fi
fi
exit 0
EOF
        chmod +x "$merge_hook_path"
    fi

    verbose_log "  Created work hook: $hook_path (pre-commit checks)"
}
