# ============================================================================
# Bwrap sandbox (simplified - runs as current user, no sudo)
# ============================================================================

# Check if bwrap is available
check_bwrap() {
    if ! command -v bwrap >/dev/null 2>&1; then
        echo "Hold on now. I need bubblewrap (bwrap) installed for sandboxing."
        echo "Install it: sudo apt install bubblewrap"
        exit 1
    fi
}

# Run a command inside a bwrap sandbox
# Usage: run_in_bwrap <intermediary_root> <session_work_root> <intermediary_dir> <work_dir> <pipe_path> <project_path> [command...]
#
# Arguments:
#   intermediary_root        - Shared intermediary root directory
#   session_work_root         - Root of session work tree (mounted at / in non-isolated mode)
#   intermediary_dir         - The specific project's intermediary bare repo
#   work_dir                 - The specific project's work directory (for isolated mode)
#   pipe_path                - Path to the communication pipe
#   project_path             - Original project path (working directory, isolated mount point)
#   [command...]             - Optional command to run (defaults to interactive shell)
#
# In non-isolated mode: session_work_root is mounted at /, intermediaries are mounted
# at /run<intermediary_path>, making all same-session projects visible at original paths.
#
# In isolated mode: only work_dir and intermediary_dir are mounted at their paths.
run_in_bwrap() {
    local intermediary_root="$1"
    local session_work_root="$2"
    local intermediary_dir="$3"
    local work_dir="$4"
    local pipe_path="$5"
    local project_path="$6"
    shift 6

    # Use real UID/GID if passed from parent (when inside network namespace, we're root)
    local user_uid user_gid username user_home
    user_uid="${BWRAP_REAL_UID:-$(id -u)}"
    user_gid="${BWRAP_REAL_GID:-$(id -g)}"
    username="${BWRAP_REAL_USER:-$(whoami)}"
    user_home="${BWRAP_REAL_HOME:-$HOME}"

    # Hostname for the cage
    local cage_hostname="caged.$(hostname)"

    # Build bwrap arguments as an array
    local -a bwrap_args=()

    # Enumerate projects and build mount specs using shared functions
    enumerate_projects "$session_work_root" "$intermediary_root" "$work_dir" "$intermediary_dir" "$project_path"
    build_mount_specs "$intermediary_dir" "$work_dir" "$project_path" "$pipe_path" "$user_home"

    # System binaries (read-only) - overlays the / mount
    bwrap_args+=(--ro-bind /usr /usr)
    bwrap_args+=(--ro-bind /bin /bin)
    bwrap_args+=(--ro-bind /lib /lib)
    bwrap_args+=(--ro-bind-try /lib64 /lib64)
    bwrap_args+=(--ro-bind-try /sbin /sbin)

    # System config (read-only)
    bwrap_args+=(--ro-bind /etc/passwd /etc/passwd)
    bwrap_args+=(--ro-bind /etc/group /etc/group)

    # For slirp4netns network namespace, use its DNS resolver (10.0.2.3)
    # Otherwise use host's resolv.conf
    if [ "${SLIRP_NETWORK:-}" = "1" ]; then
        local slirp_resolv
        slirp_resolv=$(mktemp)
        echo "nameserver 10.0.2.3" > "$slirp_resolv"
        bwrap_args+=(--ro-bind "$slirp_resolv" /etc/resolv.conf)
    else
        bwrap_args+=(--ro-bind /etc/resolv.conf /etc/resolv.conf)
    fi

    bwrap_args+=(--ro-bind /etc/hosts /etc/hosts)
    bwrap_args+=(--ro-bind /etc/nsswitch.conf /etc/nsswitch.conf)
    bwrap_args+=(--ro-bind-try /etc/localtime /etc/localtime)
    bwrap_args+=(--ro-bind-try /etc/timezone /etc/timezone)
    bwrap_args+=(--ro-bind-try /etc/environment /etc/environment)
    bwrap_args+=(--ro-bind-try /etc/ld.so.cache /etc/ld.so.cache)

    # SSL/TLS certificates (distro-specific locations, public certs only)
    bwrap_args+=(--ro-bind-try /etc/ssl/certs /etc/ssl/certs)            # Debian/Ubuntu/Arch
    bwrap_args+=(--ro-bind-try /etc/ca-certificates /etc/ca-certificates) # Debian/Ubuntu
    bwrap_args+=(--ro-bind-try /etc/pki/ca-trust /etc/pki/ca-trust)      # Fedora/RHEL CA trust
    bwrap_args+=(--ro-bind-try /etc/pki/tls/certs /etc/pki/tls/certs)    # Fedora/RHEL public certs

    # Shell config (read-only, distro-specific)
    bwrap_args+=(--ro-bind-try /etc/inputrc /etc/inputrc)
    bwrap_args+=(--ro-bind-try /etc/bash.bashrc /etc/bash.bashrc)        # Debian/Ubuntu/Arch
    bwrap_args+=(--ro-bind-try /etc/bashrc /etc/bashrc)                  # Fedora/RHEL/CentOS
    bwrap_args+=(--ro-bind-try /etc/profile /etc/profile)
    bwrap_args+=(--ro-bind-try /etc/profile.d /etc/profile.d)
    bwrap_args+=(--ro-bind-try /etc/bash_completion /etc/bash_completion)
    bwrap_args+=(--ro-bind-try /etc/bash_completion.d /etc/bash_completion.d)
    bwrap_args+=(--ro-bind-try /etc/alternatives /etc/alternatives)      # Debian/Ubuntu

    # User home config (read-only)
    bwrap_args+=(--ro-bind-try "$user_home/.gitconfig" "$user_home/.gitconfig")
    bwrap_args+=(--ro-bind-try "$user_home/.config/git" "$user_home/.config/git")

    # Apply mounts from shared CAGE_MOUNTS array
    # This includes: additional config mounts, tmpfs, project mounts, pipe
    for spec in "${CAGE_MOUNTS[@]}"; do
        IFS='|' read -r type source dest mode <<< "$spec"
        case "$type" in
            bind)
                # Additional mounts use -try (may not exist), project mounts are required
                if [ "$mode" = "ro" ]; then
                    bwrap_args+=(--ro-bind-try "$source" "$dest")
                else
                    # Project mounts should exist (or we're in dry-run)
                    if [ -e "$source" ] || [ "$dry_run" = true ]; then
                        bwrap_args+=(--bind "$source" "$dest")
                    else
                        bwrap_args+=(--bind-try "$source" "$dest")
                    fi
                fi
                ;;
            tmpfs)
                bwrap_args+=(--tmpfs "$dest")
                ;;
            pipe)
                bwrap_args+=(--bind "$source" "$dest")
                ;;
        esac
    done

    # Special filesystems
    bwrap_args+=(--proc /proc)
    bwrap_args+=(--dev /dev)
    bwrap_args+=(--dev-bind /dev/pts /dev/pts)
    bwrap_args+=(--dev-bind /dev/ptmx /dev/ptmx)
    bwrap_args+=(--dev-bind-try /dev/tty /dev/tty)

    # Environment variables
    bwrap_args+=(--setenv HOME "$user_home")
    bwrap_args+=(--setenv USER "$username")
    bwrap_args+=(--setenv SHELL /bin/bash)
    bwrap_args+=(--setenv PATH "/usr/local/bin:/usr/bin:/bin:$user_home/.local/bin")
    bwrap_args+=(--setenv TERM "${TERM:-xterm-256color}")
    bwrap_args+=(--setenv LANG "${LANG:-C.UTF-8}")
    [ -n "${LC_ALL}" ] && bwrap_args+=(--setenv LC_ALL "$LC_ALL")

    # User namespace with current user's UID/GID
    bwrap_args+=(--unshare-user)
    bwrap_args+=(--uid "$user_uid")
    bwrap_args+=(--gid "$user_gid")

    # Hostname isolation
    bwrap_args+=(--unshare-uts)
    bwrap_args+=(--hostname "$cage_hostname")

    # Note: We intentionally don't use --unshare-pid for interactive shells
    # PID namespace makes the shell PID 1, which has special signal handling
    # that breaks Ctrl+C. User namespace already prevents accessing host processes.

    # Cleanup on parent exit
    bwrap_args+=(--die-with-parent)

    # Working directory is the project path (where work/ is mounted)
    bwrap_args+=(--chdir "$project_path")

    # Add command or interactive shell
    # Create custom rcfile that silences command_not_found_handle after sourcing configs
    if [ $# -eq 0 ]; then
        bwrap_args+=(/bin/bash -c '
cat > /tmp/.cage-bashrc << "EOF"
[ -f /etc/bash.bashrc ] && . /etc/bash.bashrc
[ -f ~/.bashrc ] && . ~/.bashrc
unset -f command_not_found_handle 2>/dev/null
# Cage prompt - red user@caged with bunny (Con Air style)
PS1="\[\e[1;31m\]\u@caged\[\e[0m\] 🐰 \w\$ "
EOF
exec bash --rcfile /tmp/.cage-bashrc')
    else
        bwrap_args+=(/bin/bash -l -c "unset -f command_not_found_handle 2>/dev/null; $*")
    fi

    # Run bwrap
    if [ "$dry_run" = true ]; then
        echo "[dry-run] bwrap ${bwrap_args[*]}"
        return 0
    fi

    if [ "$verbose" = true ]; then
        echo -e "${_yellow}[run] bwrap ${bwrap_args[*]}${_reset}" >&2
    fi

    bwrap "${bwrap_args[@]}"
}

# Run bwrap with network isolation via slirp4netns
# This wraps run_in_bwrap in a network namespace with iptables filtering
#
# Usage: run_in_bwrap_with_network <intermediary_root> <session_work_root> <intermediary_dir> <work_dir> <pipe_path> <project_path> [command...]
#
# Uses global config variables:
#   cfg_networkMode      - "disabled", "allowlist", or "blocklist"
#   cfg_allow_domains    - pipe-separated allowed domains
#   cfg_allow_ips        - pipe-separated allowed IPs
#   cfg_allow_networks   - pipe-separated allowed networks
#   cfg_block_domains    - pipe-separated blocked domains
#   cfg_block_ips        - pipe-separated blocked IPs
#   cfg_block_networks   - pipe-separated blocked networks
run_in_bwrap_with_network() {
    local intermediary_root="$1"
    local session_work_root="$2"
    local intermediary_dir="$3"
    local work_dir="$4"
    local pipe_path="$5"
    local project_path="$6"
    shift 6

    # If network mode is disabled, just run bwrap directly
    if [ "$cfg_networkMode" = "disabled" ] || [ -z "$cfg_networkMode" ]; then
        run_in_bwrap "$intermediary_root" "$session_work_root" "$intermediary_dir" "$work_dir" "$pipe_path" "$project_path" "$@"
        return $?
    fi

    # Export bwrap-related variables for the inner call
    # run_with_network_namespace sources the main script, so run_in_bwrap will be available
    export BWRAP_INTERMEDIARY_ROOT="$intermediary_root"
    export BWRAP_SESSION_WORK_ROOT="$session_work_root"
    export BWRAP_INTERMEDIARY_DIR="$intermediary_dir"
    export BWRAP_WORK_DIR="$work_dir"
    export BWRAP_PIPE_PATH="$pipe_path"
    export BWRAP_PROJECT_PATH="$project_path"
    export BWRAP_DRY_RUN="$dry_run"
    export BWRAP_VERBOSE="$verbose"

    # Capture real UID/GID before entering namespace (where we become root)
    export BWRAP_REAL_UID="$(id -u)"
    export BWRAP_REAL_GID="$(id -g)"
    export BWRAP_REAL_USER="$(whoami)"
    export BWRAP_REAL_HOME="$HOME"

    # Signal to bwrap that we're in a slirp4netns network namespace
    # This tells it to use 10.0.2.3 as DNS resolver instead of host's resolv.conf
    export SLIRP_NETWORK="1"

    # Export cfg_mounts array as a string (^-separated entries)
    local mounts_str=""
    for mount_entry in "${cfg_mounts[@]}"; do
        mounts_str="${mounts_str}${mounts_str:+^}${mount_entry}"
    done
    export BWRAP_MOUNTS="$mounts_str"

    # Build the command to run inside the network namespace
    # We need to source the main script again because exec creates a new bash process
    local inner_cmd
    if [ $# -eq 0 ]; then
        inner_cmd='
            export CLAUDE_CAGE_SOURCING=1
            source "$CLAUDE_CAGE_SCRIPT"
            dry_run="$BWRAP_DRY_RUN"
            verbose="$BWRAP_VERBOSE"
            # Restore cfg_mounts array
            IFS="^" read -ra cfg_mounts <<< "$BWRAP_MOUNTS"
            run_in_bwrap "$BWRAP_INTERMEDIARY_ROOT" "$BWRAP_SESSION_WORK_ROOT" "$BWRAP_INTERMEDIARY_DIR" "$BWRAP_WORK_DIR" "$BWRAP_PIPE_PATH" "$BWRAP_PROJECT_PATH"
        '
    else
        # Escape command arguments for passing through
        local escaped_args=""
        for arg in "$@"; do
            escaped_args="$escaped_args '${arg//\'/\'\\\'\'}'"
        done
        inner_cmd='
            export CLAUDE_CAGE_SOURCING=1
            source "$CLAUDE_CAGE_SCRIPT"
            dry_run="$BWRAP_DRY_RUN"
            verbose="$BWRAP_VERBOSE"
            # Restore cfg_mounts array
            IFS="^" read -ra cfg_mounts <<< "$BWRAP_MOUNTS"
            run_in_bwrap "$BWRAP_INTERMEDIARY_ROOT" "$BWRAP_SESSION_WORK_ROOT" "$BWRAP_INTERMEDIARY_DIR" "$BWRAP_WORK_DIR" "$BWRAP_PIPE_PATH" "$BWRAP_PROJECT_PATH" '"$escaped_args"'
        '
    fi

    run_with_network_namespace \
        "$cfg_networkMode" \
        "$cfg_allow_domains" \
        "$cfg_allow_ips" \
        "$cfg_allow_networks" \
        "$cfg_block_domains" \
        "$cfg_block_ips" \
        "$cfg_block_networks" \
        -- \
        bash -c "$inner_cmd"
}
