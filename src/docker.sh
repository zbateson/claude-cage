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
# Usage: run_in_docker <caged_dir> <mount_as> [command...]
#
# Arguments:
#   caged_dir    - The .caged directory (contains intermediary/ and work/)
#   mount_as     - Path to mount it as inside container
#   [command...] - Optional command to run (defaults to interactive shell)
#
# Inside the container:
#   $mount_as/intermediary/  - git origin remote
#   $mount_as/work/          - working directory (chdir here)
run_in_docker() {
    local caged_dir="$1"
    local mount_as="$2"
    shift 2

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

    # Mount .caged at the project path
    docker_args+=(-v "$caged_dir:$mount_as")

    # Additional mounts from config
    for mount_entry in "${cfg_mounts[@]}"; do
        IFS='|' read -r mount_source mount_dest <<< "$mount_entry"
        # Expand tilde to user home
        mount_source="${mount_source/#\~/$user_home}"
        mount_dest="${mount_dest/#\~/$user_home}"
        if [ -e "$mount_source" ]; then
            docker_args+=(-v "$mount_source:$mount_dest:ro")
        fi
    done

    # Working directory
    docker_args+=(-w "$mount_as/work")

    # Environment
    docker_args+=(-e "HOME=$user_home")
    docker_args+=(-e "TERM=${TERM:-xterm-256color}")
    docker_args+=(-e "LANG=${LANG:-C.UTF-8}")

    # Image
    docker_args+=("$image")

    # Add command or interactive shell
    if [ $# -eq 0 ]; then
        docker_args+=(/bin/bash)
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
