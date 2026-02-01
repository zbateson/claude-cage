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
    cat > "$hook_path" << EOF
#!/bin/bash
while read oldrev newrev refname; do
    echo "\$refname \$newrev" > "$mounted_pipe_path"
done
EOF
    run chmod +x "$hook_path"

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
