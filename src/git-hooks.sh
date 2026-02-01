# ============================================================================
# Git hooks and communication pipe
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
    local mounted_pipe_path="/run/claude-cage/pipe"

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
while read oldrev newrev refname; do
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
cleanup_source_hooks() {
    local source_dir="$1"
    local pre_commit="$source_dir/.git/hooks/pre-commit"
    local post_commit="$source_dir/.git/hooks/post-commit"

    if [ -f "$pre_commit" ]; then
        run rm -f "$pre_commit"
        if [ "$verbose" = true ]; then
            echo "  Removed hook: $pre_commit"
        fi
    fi

    if [ -f "$post_commit" ]; then
        run rm -f "$post_commit"
        if [ "$verbose" = true ]; then
            echo "  Removed hook: $post_commit"
        fi
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
    local hook_path="$source_dir/.git/hooks/pre-commit"
    local work_dir
    work_dir=$(get_cage_path "$source_dir" "work")

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
setup_source_post_commit() {
    local source_dir="$1"
    local exclude_patterns="$2"
    local intermediary_dir="$3"
    local target_branch="$4"
    local state_path="$5"
    local hook_path="$source_dir/.git/hooks/post-commit"

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
# claude-cage: sync commits to intermediary's claude branch (excluding sensitive files)
INTERMEDIARY="$intermediary_dir"
TARGET_BRANCH="$target_branch"
STATE_FILE="$state_path"

if [ ! -d "\$INTERMEDIARY" ]; then
    exit 0  # cage not set up yet
fi

# Only sync commits from the branch that was active when cage started
current_branch=\$(git branch --show-current)
if [ "\$current_branch" != "\$TARGET_BRANCH" ]; then
    exit 0  # different branch, no sync needed
fi

# Apply commit to intermediary's claude branch, excluding sensitive files
# format-patch with pathspec excludes ensures sensitive files aren't included
# Note: Using HEAD~1..HEAD instead of -1 HEAD because the latter has weird behavior
# when pathspec excludes all files (it outputs the parent commit instead of empty)
# Note: Don't use "-- ." before excludes - it breaks pathspec exclude matching
PATCH=\$(git format-patch HEAD~1..HEAD --stdout --$pathspec_excludes)

# Check if patch has any actual changes (not just empty)
if echo "\$PATCH" | grep -q "^diff --git"; then
    # Ensure we're on claude branch and apply
    if (cd "\$INTERMEDIARY" && git checkout claude 2>/dev/null && echo "\$PATCH" | git am --3way); then
        : # success
    else
        echo "claude-cage: Patch didn't apply cleanly to intermediary. You may need to sync manually."
    fi
else
    echo "claude-cage: Only excluded files in this commit, nothin' to sync."
fi

# Update state file with current commit (even if only excluded files)
# This tracks that we've processed this commit
git rev-parse HEAD > "\$STATE_FILE"
EOF
        chmod +x "$hook_path"
    fi

    if [ "$verbose" = true ]; then
        echo "  Created source hook: $hook_path"
    fi
}
