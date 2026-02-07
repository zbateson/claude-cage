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
    path_hash=$(echo -n "$source_dir" | md5sum | cut -c1-12)
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
                if [ "$verbose" = true ]; then
                    echo "Removing orphaned hook: $hook"
                fi
                rm -f "$hook"
                cleaned=$((cleaned + 1))
            fi
        done
        maybe_remove_dispatcher "$git_root" "post-commit"
    fi

    # Also clean up any leftover pre-commit hooks from old architecture
    if [ -d "$git_root/.git/hooks/pre-commit.d" ]; then
        for hook in "$git_root/.git/hooks/pre-commit.d"/claude-cage-*; do
            [ -f "$hook" ] || continue
            if [ "$verbose" = true ]; then
                echo "Removing legacy pre-commit hook: $hook"
            fi
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

    if [ "$verbose" = true ]; then
        echo "  Created pipe: $pipe_path"
    fi
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

    if [ "$verbose" = true ]; then
        echo "  Set up hooks on intermediary"
    fi
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
        if [ "$verbose" = true ]; then
            echo "  Other sessions active, keepin' hooks for this project"
        fi
        return 0
    fi

    # Use git root for hook paths (supports running from subdirectories)
    local git_root
    git_root=$(get_git_root "$source_dir")

    # No other sessions, safe to remove project-specific hooks
    local path_hash
    path_hash=$(echo -n "$source_dir" | md5sum | cut -c1-12)
    local post_commit_hook="$git_root/.git/hooks/post-commit.d/claude-cage-$path_hash"

    if [ -f "$post_commit_hook" ]; then
        run rm -f "$post_commit_hook"
        if [ "$verbose" = true ]; then
            echo "  Removed hook: $post_commit_hook"
        fi
        maybe_remove_dispatcher "$git_root" "post-commit"
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
    path_hash=$(echo -n "$source_dir" | md5sum | cut -c1-12)
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
# Value is the path_hash of the source_dir whose intermediary is being synced,
# so only THIS hook skips — other hooks (different intermediaries) still process.
[ "\${CLAUDE_CAGE_SYNCING:-}" = "$path_hash" ] && exit 0

# Check commit mapping: already mapped -> skip (loop prevention)
if [ -f "\$COMMIT_MAP" ] && grep -q " \${COMMIT_HASH}\$" "\$COMMIT_MAP"; then
    _sync_log "\$COMMIT_SHORT" ">>intermediary" "already mapped, skipping (loop prevention)"
    exit 0
fi

SUBJECT=\$(git log -1 --format=%s | head -c 50)
_sync_log "\$COMMIT_SHORT" ">>intermediary" "applying: \$SUBJECT"

# Build combined pathspec: scope include + exclude (read from metadata file at runtime)
PATHSPEC_ARGS=()
[ -n "\$SCOPE_PATH" ] && PATHSPEC_ARGS+=("\$SCOPE_PATH/")
if [ -f "\$EXCLUDE_PATHSPECS_FILE" ]; then
    while IFS= read -r _ps; do
        [ -n "\$_ps" ] && PATHSPEC_ARGS+=("\$_ps")
    done < "\$EXCLUDE_PATHSPECS_FILE"
fi

EXPORT_ERR=\$(mktemp 2>/dev/null || echo "/tmp/claude-cage-export-err.\$\$")
EXPORT_OUT=\$(mktemp 2>/dev/null || echo "/tmp/claude-cage-export-out.\$\$")

# Export to temp file first so we can detect excluded-only commits before fast-import.
# git fast-export --export-marks only writes commit marks (blobs are ignored per docs).
# This means incremental exports lose blob marks from source-marks. For excluded-only
# commits, fast-export can't reference parent blobs → emits an orphan root commit
# instead of a proper child. Piping that to fast-import would fail with
# "new tip does not contain old tip". Detecting and skipping avoids this.
git fast-export --import-marks="\$SOURCE_MARKS" --export-marks="\$SOURCE_MARKS" -1 HEAD \\
    \${PATHSPEC_ARGS:+-- "\${PATHSPEC_ARGS[@]}"} \\
    >"\$EXPORT_OUT" 2>"\$EXPORT_ERR"
EXPORT_RC=\$?

if [ "\$EXPORT_RC" -ne 0 ]; then
    _sync_log "\$COMMIT_SHORT" ">>intermediary" "fast-export FAILED rc=\$EXPORT_RC"
    [ -s "\$EXPORT_ERR" ] && _sync_log "\$COMMIT_SHORT" ">>intermediary" "export stderr: \$(cat "\$EXPORT_ERR")"
    echo -e "\033[1;31mclaude-cage:\033[0m Sync failed for commit \$COMMIT_SHORT (export=\$EXPORT_RC)"
    rm -f "\$EXPORT_ERR" "\$EXPORT_OUT"
    exit 0
fi

# Strip scope prefix from fast-export paths (scoped intermediaries only).
# Uses the shared strip-prefix script installed in the intermediary.
if [ -n "\$SCOPE_PATH" ]; then
    "\$INTERMEDIARY/claude-cage-strip-prefix" "\${SCOPE_PATH}/" "\$EXPORT_OUT"
fi

# Excluded-only detection: no commit line means fast-export dropped it entirely (small repos).
if ! grep -q '^commit ' "\$EXPORT_OUT"; then
    echo "0 \$COMMIT_HASH" >> "\$COMMIT_MAP"
    _sync_log "\$COMMIT_SHORT" ">>intermediary" "excluded-only commit (no commit line), mapped to 0"
    echo -e "\033[1;31mclaude-cage:\033[0m Nothin' changed in intermediary — commit only has excluded files"
    rm -f "\$EXPORT_ERR" "\$EXPORT_OUT"
    exit 0
fi

# No from line: either excluded-only (parent in marks, all changes filtered out)
# or marks gap (parent not in marks, e.g. from sync_to_source/git-am or prior
# excluded-only commit). Check parent to distinguish.
if ! grep -q '^from ' "\$EXPORT_OUT"; then
    _PARENT=\$(git rev-parse HEAD^ 2>/dev/null) || true
    _PARENT_MARKED=false
    if [ -n "\$_PARENT" ] && [ -f "\$SOURCE_MARKS" ] && grep -q " \${_PARENT}\$" "\$SOURCE_MARKS" 2>/dev/null; then
        _PARENT_MARKED=true
    fi
    if [ "\$_PARENT_MARKED" = true ] || [ -z "\$_PARENT" ]; then
        # Parent IS in marks (or root commit) but no from line → truly excluded-only
        echo "0 \$COMMIT_HASH" >> "\$COMMIT_MAP"
        _sync_log "\$COMMIT_SHORT" ">>intermediary" "excluded-only commit, mapped to 0"
        echo -e "\033[1;31mclaude-cage:\033[0m Nothin' changed in intermediary — commit only has excluded files"
        rm -f "\$EXPORT_ERR" "\$EXPORT_OUT"
        exit 0
    fi
    # Parent NOT in marks — marks gap. Inject intermediary branch HEAD as parent.
    # The deleteall + full-tree reconstruction produces the correct tree state.
    _INT_HEAD=\$(git -C "\$INTERMEDIARY" rev-parse "\$current_branch" 2>/dev/null)
    if [ -n "\$_INT_HEAD" ]; then
        _sync_log "\$COMMIT_SHORT" ">>intermediary" "marks gap: injecting parent \${_INT_HEAD:0:8}"
        awk -v parent="\$_INT_HEAD" '/^deleteall\$/ && !done { print "from " parent; done=1 } { print }' \\
            "\$EXPORT_OUT" > "\$EXPORT_OUT.fix" && mv "\$EXPORT_OUT.fix" "\$EXPORT_OUT"
    else
        echo "0 \$COMMIT_HASH" >> "\$COMMIT_MAP"
        _sync_log "\$COMMIT_SHORT" ">>intermediary" "excluded-only (no intermediary HEAD for \$current_branch)"
        echo -e "\033[1;31mclaude-cage:\033[0m Nothin' changed in intermediary — commit only has excluded files"
        rm -f "\$EXPORT_ERR" "\$EXPORT_OUT"
        exit 0
    fi
fi

echo -e "\033[1;31mclaude-cage:\033[0m Updating intermediary, run 'git pull' from claude-cage"

IMPORT_ERR=\$(mktemp 2>/dev/null || echo "/tmp/claude-cage-import-err.\$\$")
git -C "\$INTERMEDIARY" fast-import --import-marks="\$IMPORT_MARKS" --export-marks="\$IMPORT_MARKS" --quiet \\
    <"\$EXPORT_OUT" 2>"\$IMPORT_ERR"
IMPORT_RC=\$?

if [ "\$IMPORT_RC" -ne 0 ]; then
    _sync_log "\$COMMIT_SHORT" ">>intermediary" "fast-import FAILED rc=\$IMPORT_RC"
    [ -s "\$IMPORT_ERR" ] && _sync_log "\$COMMIT_SHORT" ">>intermediary" "import stderr: \$(cat "\$IMPORT_ERR")"
    echo -e "\033[1;31mclaude-cage:\033[0m Sync failed for commit \$COMMIT_SHORT (import=\$IMPORT_RC)"
    rm -f "\$EXPORT_ERR" "\$IMPORT_ERR" "\$EXPORT_OUT"
    exit 0
fi
rm -f "\$EXPORT_ERR" "\$IMPORT_ERR" "\$EXPORT_OUT"

# Update commit mapping from marks
if [ -f "\$SOURCE_MARKS" ] && [ -f "\$IMPORT_MARKS" ]; then
    awk 'NR==FNR { source[\$1]=\$2; next } { if (\$1 in source) print \$2, source[\$1] }' \\
        "\$SOURCE_MARKS" "\$IMPORT_MARKS" >> "\$COMMIT_MAP"
fi

# If commit still not in mapping after marks join, record as excluded-only
if ! grep -q " \${COMMIT_HASH}\$" "\$COMMIT_MAP" 2>/dev/null; then
    echo "0 \$COMMIT_HASH" >> "\$COMMIT_MAP"
    _sync_log "\$COMMIT_SHORT" ">>intermediary" "excluded-only commit, mapped to 0"
else
    _sync_log "\$COMMIT_SHORT" ">>intermediary" "fast-import ok"
fi
EOF
        chmod +x "$hook_path"
    fi

    if [ "$verbose" = true ]; then
        echo "  Created source hook: $hook_path"
    fi
}

# Set up pre-commit hook on work repo to block force-added gitignored files
# Force-added ignored files break patch-based sync between cage and source.
# Override with CLAUDE_CAGE_ALLOW_IGNORED=1 git commit
# Arguments:
#   $1 - work_dir: The work directory (Claude's workspace)
setup_work_pre_commit() {
    local work_dir="$1"
    local hook_path="$work_dir/.git/hooks/pre-commit"

    if [ "$dry_run" = true ]; then
        echo "[dry-run] create $hook_path (block force-added ignored files)"
        return
    fi

    cat > "$hook_path" << 'HOOKEOF'
#!/bin/bash
# claude-cage: block commits containing force-added gitignored files
# Force-added ignored files break patch-based sync between cage and source.
# Override: CLAUDE_CAGE_ALLOW_IGNORED=1 git commit

if [ "${CLAUDE_CAGE_ALLOW_IGNORED:-}" = "1" ]; then
    exit 0
fi

# Detect force-added ignored files staged for commit
IGNORED=$(git ls-files -ic --exclude-standard 2>/dev/null)
if [ -n "$IGNORED" ]; then
    echo "Hold on there. You've got gitignored files force-added to this commit."
    echo "That's gonna break the sync back to source."
    echo ""
    echo "Files:"
    echo "$IGNORED" | sed 's/^/  /'
    echo ""
    echo "To unstage 'em:"
    echo "  git reset HEAD <file>"
    echo ""
    echo "If you really know what you're doin':"
    echo "  CLAUDE_CAGE_ALLOW_IGNORED=1 git commit"
    exit 1
fi

exit 0
HOOKEOF
    chmod +x "$hook_path"

    if [ "$verbose" = true ]; then
        echo "  Created work hook: $hook_path (block force-added ignored files)"
    fi
}
