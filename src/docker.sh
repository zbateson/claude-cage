# ============================================================================
# Docker sandbox (alternative to bwrap)
# ============================================================================

# Check if docker is available
check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        echo "Gonna need docker for this one, and I ain't seein' it."
        echo "Install it: https://docs.docker.com/get-docker/"
        exit 1
    fi
}

# Run a command inside a Docker container
# Usage: run_in_docker <intermediary_dir> <branch_work_root> <work_dir> <pipe_path> <project_path> [command...]
#
# Arguments:
#   intermediary_dir   - The intermediary git repo directory
#   branch_work_root   - Root of branch work tree (for mounting all same-branch projects)
#   work_dir           - The specific project's work directory (for isolated mode)
#   pipe_path          - Path to the communication pipe
#   project_path       - Original project path (working directory, isolated mount point)
#   [command...]       - Optional command to run (defaults to interactive shell)
#
# In non-isolated mode: mounts top-level dirs from branch_work_root,
# making all same-branch projects visible at their original paths.
#
# In isolated mode: only work_dir is mounted at project_path.
run_in_docker() {
    local intermediary_dir="$1"
    local branch_work_root="$2"
    local work_dir="$3"
    local pipe_path="$4"
    local project_path="$5"
    shift 5

    local user_uid user_gid user_home
    user_uid=$(id -u)
    user_gid=$(id -g)
    user_home="$HOME"

    # Container settings
    local image="${cfg_docker_image:-node:lts-slim}"
    local container_name="${cfg_docker_container:-claude-cage-$$}"
    local hostname="caged.docker"

    # Build docker arguments as an array
    local -a docker_args=()

    docker_args+=(run --rm -it)
    docker_args+=(--name "$container_name")
    docker_args+=(--hostname "$hostname")

    # Run as current user
    docker_args+=(--user "${user_uid}:${user_gid}")

    # Additional mounts from config (before work dir so work can overlay)
    for mount_entry in "${cfg_mounts[@]}"; do
        IFS='|' read -r mount_source mount_dest <<< "$mount_entry"
        # Expand tilde to user home
        mount_source="${mount_source/#\~/$user_home}"
        mount_dest="${mount_dest/#\~/$user_home}"
        if [ -e "$mount_source" ]; then
            docker_args+=(-v "$mount_source:$mount_dest:ro")
        fi
    done

    # In non-isolated mode: mount top-level dirs from branch_work_root
    # This makes all same-branch projects visible at their original paths
    if [ "$cfg_isolated" != "true" ]; then
        for dir in "$branch_work_root"/*; do
            if [ -d "$dir" ]; then
                local dirname
                dirname=$(basename "$dir")
                docker_args+=(-v "$dir:/$dirname")
            fi
        done
    else
        # Isolated mode: mount only the specific work dir
        docker_args+=(-v "$work_dir:$project_path")
    fi

    # Mount intermediary at /run/claude-cage/intermediary
    docker_args+=(-v "$intermediary_dir:/run/claude-cage/intermediary")

    # Mount pipe for git hook communication (if it exists)
    if [ -p "$pipe_path" ]; then
        docker_args+=(-v "$pipe_path:/run/claude-cage/pipe")
    fi

    # Working directory is the project path
    docker_args+=(-w "$project_path")

    # Environment
    docker_args+=(-e "HOME=$user_home")
    docker_args+=(-e "TERM=${TERM:-xterm-256color}")
    docker_args+=(-e "LANG=${LANG:-C.UTF-8}")

    # Image
    docker_args+=("$image")

    # Add command or interactive shell
    if [ $# -eq 0 ]; then
        # Custom rcfile with cage prompt indicator
        docker_args+=(/bin/bash -c '
cat > /tmp/.cage-bashrc << "EOF"
[ -f /etc/bash.bashrc ] && . /etc/bash.bashrc
[ -f ~/.bashrc ] && . ~/.bashrc
# Cage prompt - red user@caged with bunny (Con Air style)
PS1="\[\e[1;31m\]\u@caged\[\e[0m\] 🐰 \w\$ "
EOF
exec bash --rcfile /tmp/.cage-bashrc')
    else
        docker_args+=(/bin/bash -c "$*")
    fi

    # Run docker
    if [ "$dry_run" = true ]; then
        echo "[dry-run] docker ${docker_args[*]}"
        return 0
    fi

    if [ "$verbose" = true ]; then
        echo -e "${_yellow}[run] docker ${docker_args[*]}${_reset}" >&2
    fi

    docker "${docker_args[@]}"
}
