# ============================================================================
# Git hooks and communication pipe
# ============================================================================

# ============================================================================
# Session tracking (prevents cleanup race conditions with multiple sessions)
# ============================================================================

# Get the session directory for a source/branch combo
# Sessions are tracked in runtime dir (cleared on reboot)
get_session_dir() {
    local source_dir="$1"
    local branch="$2"
    local sanitized_branch
    sanitized_branch=$(sanitize_branch_name "$branch")
    local path_hash
    path_hash=$(echo -n "$source_dir" | md5sum | cut -c1-12)
    echo "$CLAUDE_CAGE_RUNTIME/sessions/$sanitized_branch/$path_hash"
}

# Register this session (create PID file)
register_session() {
    local source_dir="$1"
    local branch="$2"
    local session_dir
    session_dir=$(get_session_dir "$source_dir" "$branch")

    if [ "$dry_run" = true ]; then
        echo "[dry-run] register session at $session_dir/$$"
    else
        mkdir -p "$session_dir"
        echo $$ > "$session_dir/$$"
    fi
}

# Unregister this session (remove PID file)
unregister_session() {
    local source_dir="$1"
    local branch="$2"
    local session_dir
    session_dir=$(get_session_dir "$source_dir" "$branch")

    if [ "$dry_run" = true ]; then
        echo "[dry-run] unregister session at $session_dir/$$"
    else
        rm -f "$session_dir/$$"
        # Clean up empty directories
        rmdir "$session_dir" 2>/dev/null || true
        rmdir "$(dirname "$session_dir")" 2>/dev/null || true
    fi
}

# Check if other sessions exist for this source/branch
# Returns 0 (true) if other sessions exist, 1 (false) if not
has_other_sessions() {
    local source_dir="$1"
    local branch="$2"
    local session_dir
    session_dir=$(get_session_dir "$source_dir" "$branch")

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

    # Check pre-commit hooks
    if [ -d "$git_root/.git/hooks/pre-commit.d" ]; then
        for hook in "$git_root/.git/hooks/pre-commit.d"/claude-cage-*; do
            [ -f "$hook" ] || continue

            # Extract WORK_DIR from the hook
            local work_dir
            work_dir=$(grep '^WORK_DIR=' "$hook" 2>/dev/null | head -1 | cut -d'"' -f2)

            if [ -n "$work_dir" ] && [ ! -d "$work_dir" ]; then
                if [ "$verbose" = true ]; then
                    echo "Removing orphaned hook: $hook"
                fi
                rm -f "$hook"
                cleaned=$((cleaned + 1))
            fi
        done
        maybe_remove_dispatcher "$git_root" "pre-commit"
    fi

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
    local hook_type="$2"  # e.g., "post-commit" or "pre-commit"
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

# Set up named pipe and git hooks for cage communication
# Arguments:
#   $1 - source_dir: The original source directory
#   $2 - intermediary_dir: The intermediary directory
#   $3 - pipe_path: The pipe file path
setup_git_hooks() {
    local source_dir="$1"
    local intermediary_dir="$2"
    local pipe_path="$3"
    local hook_path="$intermediary_dir/.git/hooks/post-receive"

    # Path to pipe as seen from inside the sandbox
    # Override with CLAUDE_CAGE_MOUNTED_PIPE for test isolation (tests run outside
    # a real sandbox and need their own pipe path to avoid leaking into a live session)
    local mounted_pipe_path="${CLAUDE_CAGE_MOUNTED_PIPE:-/tmp/claude-cage/pipe}"

    # Create parent directory for pipe if needed
    local pipe_dir
    pipe_dir=$(dirname "$pipe_path")
    run mkdir -p "$pipe_dir"

    # Create named pipe for communication (always fresh)
    run rm -f "$pipe_path"
    run mkfifo "$pipe_path"

    # Create post-receive hook on intermediary
    # This runs inside the sandbox when work/ pushes to intermediary/
    if [ "$dry_run" = true ]; then
        echo "[dry-run] create $hook_path"
    else
        cat > "$hook_path" << EOF
#!/bin/bash
SYNC_LOG="\$(git rev-parse --git-dir 2>/dev/null)/sync.log"
while read oldrev newrev refname; do
    printf '[%s] %s %-14s %s\n' "\$(date '+%Y-%m-%d %H:%M:%S')" "\${newrev:0:8}" "post-recv" "refname=\$refname oldrev=\${oldrev:0:8} newrev=\${newrev:0:8}" >> "\$SYNC_LOG"
    if [ "\${CAGE_DEBUG:-}" = "1" ]; then
        echo "claude-cage post-receive: \$refname \$oldrev -> \$newrev" >&2
    fi
    echo "\$refname \$newrev" > "$mounted_pipe_path"
done
EOF
        chmod +x "$hook_path"
    fi

    if [ "$verbose" = true ]; then
        echo "  Created pipe: $pipe_path"
        echo "  Created hook: $hook_path"
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
#   $2 - target_branch: The branch that was active when cage started
cleanup_source_hooks() {
    local source_dir="$1"
    local target_branch="$2"
    local sanitized_branch
    sanitized_branch=$(sanitize_branch_name "$target_branch")

    # Check if other sessions still need the hooks
    if has_other_sessions "$source_dir" "$target_branch"; then
        if [ "$verbose" = true ]; then
            echo "  Other sessions active, keepin' hooks for branch: $target_branch"
        fi
        return 0
    fi

    # Use git root for hook paths (supports running from subdirectories)
    local git_root
    git_root=$(get_git_root "$source_dir")

    # No other sessions, safe to remove our branch-specific hooks
    local pre_commit_hook="$git_root/.git/hooks/pre-commit.d/claude-cage-$sanitized_branch"
    local post_commit_hook="$git_root/.git/hooks/post-commit.d/claude-cage-$sanitized_branch"

    if [ -f "$pre_commit_hook" ]; then
        run rm -f "$pre_commit_hook"
        if [ "$verbose" = true ]; then
            echo "  Removed hook: $pre_commit_hook"
        fi
        maybe_remove_dispatcher "$git_root" "pre-commit"
    fi

    if [ -f "$post_commit_hook" ]; then
        run rm -f "$post_commit_hook"
        if [ "$verbose" = true ]; then
            echo "  Removed hook: $post_commit_hook"
        fi
        maybe_remove_dispatcher "$git_root" "post-commit"
    fi
}

# Set up pre-commit hook on source repo to prevent mixed commits
# Arguments:
#   $1 - source_dir: The source project directory
#   $2 - exclude_patterns: Pipe-delimited exclude patterns
#   $3 - target_branch: The branch that was active when cage started
setup_source_pre_commit() {
    local source_dir="$1"
    local exclude_patterns="$2"
    local target_branch="$3"
    local sanitized_branch
    sanitized_branch=$(sanitize_branch_name "$target_branch")
    # Use git root for hook installation (supports running from subdirectories)
    local git_root
    git_root=$(get_git_root "$source_dir")
    local hook_path="$git_root/.git/hooks/pre-commit.d/claude-cage-$sanitized_branch"
    local work_dir
    work_dir=$(get_cage_path "$source_dir" "work")

    # Ensure dispatcher exists (at git root, not source_dir)
    if [ "$dry_run" != true ]; then
        ensure_hook_dispatcher "$git_root" "pre-commit"
    fi

    # Create pre-commit hook
    # We need to pass exclude patterns into the hook
    if [ "$dry_run" = true ]; then
        echo "[dry-run] create $hook_path"
    else
        cat > "$hook_path" << EOF
#!/bin/bash
# claude-cage: prevent mixing excluded and included files in same commit
WORK_DIR="$work_dir"
TARGET_BRANCH="$target_branch"

if [ ! -d "\$WORK_DIR" ]; then
    exit 0  # cage not set up yet
fi

# Only enforce on the branch that was active when cage started
current_branch=\$(git branch --show-current)
if [ "\$current_branch" != "\$TARGET_BRANCH" ]; then
    exit 0  # different branch, no restrictions
fi

# Exclude patterns (set at hook creation time)
EXCLUDE_PATTERNS="$exclude_patterns"

# Get staged files
STAGED=\$(git diff --cached --name-only)
if [ -z "\$STAGED" ]; then
    exit 0  # no staged files
fi

# Check each staged file against exclude patterns
EXCLUDED=""
INCLUDED=""

while IFS= read -r file; do
    is_excluded=false
    IFS='|' read -ra patterns <<< "\$EXCLUDE_PATTERNS"
    for pattern in "\${patterns[@]}"; do
        # Convert gitignore pattern to bash glob matching
        # Remove leading **/ for matching
        match_pattern="\${pattern#\*\*/}"
        if [[ "\$file" == \$match_pattern ]] || [[ "\$file" == */\$match_pattern ]] || [[ "\$file" == \$pattern ]]; then
            is_excluded=true
            break
        fi
    done
    if [ "\$is_excluded" = true ]; then
        EXCLUDED="\$EXCLUDED\$file\n"
    else
        INCLUDED="\$INCLUDED\$file\n"
    fi
done <<< "\$STAGED"

if [ -n "\$EXCLUDED" ] && [ -n "\$INCLUDED" ]; then
    echo "Whoa there. You're mixin' secret files with regular ones."
    echo ""
    echo "Excluded files:"
    echo -e "\$EXCLUDED" | sed '/^\$/d' | sed 's/^/  /'
    echo ""
    echo "Included files:"
    echo -e "\$INCLUDED" | sed '/^\$/d' | sed 's/^/  /'
    echo ""
    echo "Gotta keep 'em separate, friend."
    exit 1
fi

exit 0
EOF
        chmod +x "$hook_path"
    fi

    if [ "$verbose" = true ]; then
        echo "  Created source hook: $hook_path"
    fi
}

# Set up post-commit hook on source repo to sync commits to intermediary
# Arguments:
#   $1 - source_dir: The source project directory
#   $2 - exclude_patterns: Pipe-delimited exclude patterns (e.g., ".env|secrets/**")
#   $3 - intermediary_dir: The intermediary directory
#   $4 - target_branch: The branch that was active when cage started
#   $5 - state_path: Path to the state file for tracking last processed commit
#   $6 - work_dir: The work directory (for saving failed patches)
setup_source_post_commit() {
    local source_dir="$1"
    local exclude_patterns="$2"
    local intermediary_dir="$3"
    local target_branch="$4"
    local state_path="$5"
    local work_dir="$6"
    local sanitized_branch
    sanitized_branch=$(sanitize_branch_name "$target_branch")
    # Use git root for hook installation (supports running from subdirectories)
    local git_root
    git_root=$(get_git_root "$source_dir")
    local hook_path="$git_root/.git/hooks/post-commit.d/claude-cage-$sanitized_branch"

    # Ensure dispatcher exists (at git root, not source_dir)
    if [ "$dry_run" != true ]; then
        ensure_hook_dispatcher "$git_root" "post-commit"
    fi

    # Convert exclude patterns to pathspec format
    # Use :(exclude,glob) for proper ** matching (** means zero or more dirs with glob)
    local pathspec_excludes=""
    if [ -n "$exclude_patterns" ]; then
        IFS='|' read -ra patterns <<< "$exclude_patterns"
        for pattern in "${patterns[@]}"; do
            pathspec_excludes="$pathspec_excludes ':(exclude,glob)$pattern'"
        done
    fi

    # Create post-commit hook
    if [ "$dry_run" = true ]; then
        echo "[dry-run] create $hook_path"
    else
        cat > "$hook_path" << EOF
#!/bin/bash
# claude-cage: sync commits to intermediary (excluding sensitive files)
INTERMEDIARY="$intermediary_dir"
TARGET_BRANCH="$target_branch"
STATE_FILE="$state_path"
SOURCE_DIR="$source_dir"
WORK_DIR="$work_dir"
SYNC_LOG="\$INTERMEDIARY/.git/sync.log"

_sync_log() {
    printf '[%s] %s %-14s %s\n' "\$(date '+%Y-%m-%d %H:%M:%S')" "\$1" "\$2" "\$3" >> "\$SYNC_LOG"
}

if [ ! -d "\$INTERMEDIARY" ]; then
    exit 0  # cage not set up yet
fi

COMMIT_SHORT=\$(git rev-parse --short=8 HEAD)

# Only sync commits from the branch that was active when cage started
current_branch=\$(git branch --show-current)
if [ "\$current_branch" != "\$TARGET_BRANCH" ]; then
    _sync_log "\$COMMIT_SHORT" ">>intermediary" "skipped: on branch \$current_branch, target is \$TARGET_BRANCH"
    exit 0  # different branch, no sync needed
fi

# Apply commit to intermediary's claude branch, excluding sensitive files
# format-patch with pathspec excludes ensures sensitive files aren't included
# Note: Using HEAD~1..HEAD instead of -1 HEAD because the latter has weird behavior
# when pathspec excludes all files (it outputs the parent commit instead of empty)
# Note: Don't use "-- ." before excludes - it breaks pathspec exclude matching
PATCH=\$(git format-patch HEAD~1..HEAD --stdout --$pathspec_excludes)
SUBJECT=\$(git log -1 --format=%s | head -c 50)

# Check if patch has any actual changes (not just empty)
if echo "\$PATCH" | grep -q "^diff --git"; then
    _sync_log "\$COMMIT_SHORT" ">>intermediary" "applying: \$SUBJECT"
    # Ensure we're on target branch and apply
    echo -e "\033[1;31mclaude-cage:\033[0m Updating intermediary, run 'git pull' from claude-cage"
    AM_OUTPUT=\$(cd "\$INTERMEDIARY" && git checkout "\$TARGET_BRANCH" 2>/dev/null && echo "\$PATCH" | git am --3way 2>&1) && AM_RC=0 || AM_RC=\$?
    if [ "\$AM_RC" -eq 0 ]; then
        _sync_log "\$COMMIT_SHORT" ">>intermediary" "git-am ok"
    else
        git -C "\$INTERMEDIARY" am --abort 2>/dev/null || true
        echo -e "\033[1;31mclaude-cage:\033[0m Patch didn't apply cleanly."
        _sync_log "\$COMMIT_SHORT" ">>intermediary" "git-am FAILED rc=\$AM_RC: \$(echo "\$AM_OUTPUT" | tail -1)"

        # Save patch for manual recovery
        SANITIZED_BRANCH=\$(echo "\$TARGET_BRANCH" | sed 's|/|--|g; s|[^a-zA-Z0-9._-]|-|g')
        TIMESTAMP=\$(date +%Y%m%d-%H%M%S)
        SAFE_SUBJECT=\$(git log -1 --format=%s | sed 's/[^a-zA-Z0-9_-]/_/g' | cut -c1-50)
        REL_PATH="claude-cage-failed-patches/to-intermediary/\$SANITIZED_BRANCH"
        PATCH_FILE="\${TIMESTAMP}_\${SAFE_SUBJECT}.patch"

        # Save to source directory
        mkdir -p "\$SOURCE_DIR/\$REL_PATH"
        echo "\$PATCH" > "\$SOURCE_DIR/\$REL_PATH/\$PATCH_FILE"
        echo -e "\033[1;31mclaude-cage:\033[0m Saved patch to: \$REL_PATH/\$PATCH_FILE"

        # Also save to work directory if it exists (so Claude can see it inside cage)
        if [ -d "\$WORK_DIR" ]; then
            mkdir -p "\$WORK_DIR/\$REL_PATH"
            echo "\$PATCH" > "\$WORK_DIR/\$REL_PATH/\$PATCH_FILE"
            echo -e "\033[1;31mclaude-cage:\033[0m Also available inside cage at same path"
        fi
    fi
else
    echo -e "\033[1;31mclaude-cage:\033[0m Only excluded files in this commit, nothin' to sync."
    _sync_log "\$COMMIT_SHORT" ">>intermediary" "empty patch (excluded-only), skipped"
fi

# Update state file with current commit (even if only excluded files)
# This tracks that we've processed this commit
git rev-parse HEAD > "\$STATE_FILE"
_sync_log "\$COMMIT_SHORT" ">>intermediary" "state updated to \$COMMIT_SHORT"
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
