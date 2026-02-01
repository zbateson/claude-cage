# ============================================================================
# Git hooks and communication pipe
# ============================================================================

# Set up named pipe and git hooks for cage communication
# Arguments:
#   $1 - caged_dir: The .caged directory on host (e.g., /path/to/project/.caged)
#   $2 - mount_as: The path where .caged is mounted inside sandbox (e.g., /path/to/project)
setup_git_hooks() {
    local caged_dir="$1"
    local mount_as="$2"
    local pipe_path="$caged_dir/.pipe"
    local hook_path="$caged_dir/intermediary/.git/hooks/post-receive"

    # Path to pipe as seen from inside the sandbox
    local mounted_pipe_path="$mount_as/.pipe"

    # Create named pipe for communication
    if [ -p "$pipe_path" ]; then
        run rm -f "$pipe_path"
    fi
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
cleanup_pipe() {
    local caged_dir="$1"
    local pipe_path="$caged_dir/.pipe"

    if [ -p "$pipe_path" ]; then
        run rm -f "$pipe_path"
    fi
}

# Set up pre-commit hook on source repo to prevent mixed commits
# Arguments:
#   $1 - source_dir: The source project directory
setup_source_pre_commit() {
    local source_dir="$1"
    local hook_path="$source_dir/.git/hooks/pre-commit"
    local caged_dir="$source_dir/.caged"

    # Create pre-commit hook
    if [ "$dry_run" = true ]; then
        echo "[dry-run] create $hook_path"
    else
        cat > "$hook_path" << 'EOF'
#!/bin/bash
# claude-cage: prevent mixing excluded and included files in same commit
CAGED_DIR=".caged"
INTERMEDIARY="$CAGED_DIR/intermediary"

if [ ! -d "$INTERMEDIARY" ]; then
    exit 0  # cage not set up yet
fi

# Get staged files
STAGED=$(git diff --cached --name-only)
if [ -z "$STAGED" ]; then
    exit 0  # no staged files
fi

# Check which files would be included by sparse-checkout
INCLUDED=$(echo "$STAGED" | git -C "$INTERMEDIARY" sparse-checkout check-rules --stdin 2>/dev/null | grep -v "^$" || true)
EXCLUDED=$(echo "$STAGED" | grep -vxF "$INCLUDED" 2>/dev/null || true)

if [ -n "$EXCLUDED" ] && [ -n "$INCLUDED" ]; then
    echo "ERROR: Mixed commit - excluded and included files together."
    echo ""
    echo "Excluded files:"
    echo "$EXCLUDED" | sed 's/^/  /'
    echo ""
    echo "Included files:"
    echo "$INCLUDED" | sed 's/^/  /'
    echo ""
    echo "Please commit them separately."
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
setup_source_post_commit() {
    local source_dir="$1"
    local exclude_patterns="$2"
    local hook_path="$source_dir/.git/hooks/post-commit"
    local caged_dir="$source_dir/.caged"

    # Convert exclude patterns to pathspec format (':!pattern')
    local pathspec_excludes=""
    if [ -n "$exclude_patterns" ]; then
        IFS='|' read -ra patterns <<< "$exclude_patterns"
        for pattern in "${patterns[@]}"; do
            pathspec_excludes="$pathspec_excludes ':!$pattern'"
        done
    fi

    # Create post-commit hook
    if [ "$dry_run" = true ]; then
        echo "[dry-run] create $hook_path"
    else
        cat > "$hook_path" << EOF
#!/bin/bash
# claude-cage: sync commits to intermediary (excluding sensitive files)
CAGED_DIR="$caged_dir"
INTERMEDIARY="\$CAGED_DIR/intermediary"
WORK="\$CAGED_DIR/work"

if [ ! -d "\$INTERMEDIARY" ]; then
    exit 0  # cage not set up yet
fi

# Get files changed in this commit
CHANGED=\$(git diff-tree --no-commit-id --name-only -r HEAD)

# Check which files would be included by sparse-checkout
INCLUDED=\$(echo "\$CHANGED" | git -C "\$INTERMEDIARY" sparse-checkout check-rules --stdin 2>/dev/null | grep -v "^\$" || true)

if [ -z "\$INCLUDED" ]; then
    # All files are excluded, skip syncing this commit
    exit 0
fi

# Apply commit to intermediary, excluding sensitive files
git format-patch -1 HEAD --stdout -- .$pathspec_excludes | \\
    (cd "\$INTERMEDIARY" && git am --3way 2>/dev/null) || true

# Notify work dir that new commits are available (just fetch, don't merge)
if [ -d "\$WORK" ]; then
    (cd "\$WORK" && git fetch origin 2>/dev/null) || true
fi
EOF
        chmod +x "$hook_path"
    fi

    if [ "$verbose" = true ]; then
        echo "  Created source hook: $hook_path"
    fi
}
