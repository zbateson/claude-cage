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
# Usage: run_in_bwrap <caged_dir> <mount_as> [command...]
#
# Arguments:
#   caged_dir    - The .caged directory (contains intermediary/ and work/)
#   mount_as     - Path to mount it as (typically the project path)
#   [command...] - Optional command to run (defaults to interactive shell)
#
# Inside the sandbox:
#   $mount_as/intermediary/  - git origin remote
#   $mount_as/work/          - working directory (chdir here)
run_in_bwrap() {
    local caged_dir="$1"
    local mount_as="$2"
    shift 2

    local user_uid user_gid username user_home
    user_uid=$(id -u)
    user_gid=$(id -g)
    username=$(whoami)
    user_home="$HOME"

    # Hostname for the cage
    local cage_hostname="caged.$(hostname)"

    # Build bwrap arguments as an array
    local -a bwrap_args=()

    # System binaries (read-only)
    bwrap_args+=(--ro-bind /usr /usr)
    bwrap_args+=(--ro-bind /bin /bin)
    bwrap_args+=(--ro-bind /lib /lib)
    bwrap_args+=(--ro-bind-try /lib64 /lib64)
    bwrap_args+=(--ro-bind-try /sbin /sbin)

    # System config (read-only)
    bwrap_args+=(--ro-bind /etc/passwd /etc/passwd)
    bwrap_args+=(--ro-bind /etc/group /etc/group)
    bwrap_args+=(--ro-bind /etc/resolv.conf /etc/resolv.conf)
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

    # Mount .caged at the project path (read-write)
    # This makes intermediary/ and work/ visible at $mount_as/
    bwrap_args+=(--bind "$caged_dir" "$mount_as")

    # User home config (read-only)
    bwrap_args+=(--ro-bind-try "$user_home/.gitconfig" "$user_home/.gitconfig")
    bwrap_args+=(--ro-bind-try "$user_home/.config/git" "$user_home/.config/git")

    # Temp/runtime filesystems
    bwrap_args+=(--tmpfs /tmp)
    bwrap_args+=(--tmpfs /run)

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

    # Process isolation
    bwrap_args+=(--unshare-pid)

    # Hostname isolation
    bwrap_args+=(--unshare-uts)
    bwrap_args+=(--hostname "$cage_hostname")

    # Cleanup on parent exit
    bwrap_args+=(--die-with-parent)

    # Working directory is the work subdir
    bwrap_args+=(--chdir "$mount_as/work")

    # Add command or interactive shell
    # Create custom rcfile that silences command_not_found_handle after sourcing configs
    if [ $# -eq 0 ]; then
        bwrap_args+=(/bin/bash -c '
cat > /tmp/.cage-bashrc << "EOF"
[ -f /etc/bash.bashrc ] && . /etc/bash.bashrc
[ -f ~/.bashrc ] && . ~/.bashrc
unset -f command_not_found_handle 2>/dev/null
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
