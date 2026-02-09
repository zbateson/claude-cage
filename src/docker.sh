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

# Emit iptables commands for a set of IP/network specs with optional ports.
# Arguments: $1=pipe-separated items, $2=action (ACCEPT/REJECT), $3=flag (-A/-I)
_generate_iptables_rules_for_items() {
    local items_str="$1" action="$2" flag="$3"
    [ -z "$items_str" ] && return
    local items; IFS='|' read -ra items <<< "$items_str"
    for item in "${items[@]}"; do
        local ip ports
        if [[ "$item" =~ ^(.+):([0-9,]+)$ ]]; then
            ip="${BASH_REMATCH[1]}"; ports="${BASH_REMATCH[2]}"
        else
            ip="$item"; ports=""
        fi
        if [ -z "$ports" ]; then
            echo "iptables $flag OUTPUT -d $ip -j $action"
        elif [[ "$ports" == *","* ]]; then
            echo "iptables $flag OUTPUT -p tcp -d $ip -m multiport --dports $ports -j $action"
            echo "iptables $flag OUTPUT -p udp -d $ip -m multiport --dports $ports -j $action"
        else
            echo "iptables $flag OUTPUT -p tcp -d $ip --dport $ports -j $action"
            echo "iptables $flag OUTPUT -p udp -d $ip --dport $ports -j $action"
        fi
    done
}

# Generate iptables setup script for Docker container
# This runs as root inside container before dropping privileges
# Arguments:
#   $1 - mode: "allowlist" or "blocklist"
#   $2 - resolved_allow_ips: pipe-separated IPs with optional ports
#   $3 - allow_networks: pipe-separated networks
#   $4 - resolved_block_ips: pipe-separated IPs with optional ports
#   $5 - block_networks: pipe-separated networks
generate_docker_iptables_script() {
    local mode="$1"
    local resolved_allow_ips="$2"
    local allow_networks="$3"
    local resolved_block_ips="$4"
    local block_networks="$5"

    cat << 'IPTABLES_HEADER'
# Set up iptables rules (running as root)
debug_echo() { [ "$CAGE_VERBOSE" = "1" ] && echo "$@" >&2 || true; }

# Check if iptables is available, try to install if not
if ! command -v iptables >/dev/null 2>&1; then
    echo "Installing iptables..." >&2
    if command -v apt-get >/dev/null 2>&1; then
        debug_echo "  Running apt-get update && install..."
        if [ "$CAGE_VERBOSE" = "1" ]; then
            apt-get update && apt-get install -y iptables || { echo "iptables installation failed." >&2; exit 1; }
        else
            { apt-get update -qq >/dev/null && apt-get install -qq -y iptables >/dev/null; } &
            _pid=$!; while kill -0 $_pid 2>/dev/null; do printf '.' >&2; sleep 1; done
            wait $_pid || { echo >&2; echo "iptables installation failed." >&2; exit 1; }
            echo >&2
        fi
    elif command -v apk >/dev/null 2>&1; then
        debug_echo "  Running apk add..."
        if [ "$CAGE_VERBOSE" = "1" ]; then
            apk add iptables || { echo "iptables installation failed." >&2; exit 1; }
        else
            apk add --quiet iptables >/dev/null &
            _pid=$!; while kill -0 $_pid 2>/dev/null; do printf '.' >&2; sleep 1; done
            wait $_pid || { echo >&2; echo "iptables installation failed." >&2; exit 1; }
            echo >&2
        fi
    elif command -v yum >/dev/null 2>&1; then
        debug_echo "  Running yum install..."
        if [ "$CAGE_VERBOSE" = "1" ]; then
            yum install -y iptables || { echo "iptables installation failed." >&2; exit 1; }
        else
            yum install -q -y iptables >/dev/null &
            _pid=$!; while kill -0 $_pid 2>/dev/null; do printf '.' >&2; sleep 1; done
            wait $_pid || { echo >&2; echo "iptables installation failed." >&2; exit 1; }
            echo >&2
        fi
    fi

    if ! command -v iptables >/dev/null 2>&1; then
        echo "Network filtering requires iptables, but it ain't in this image and I couldn't install it." >&2
        echo "Either set networkMode = \"disabled\" or use an image with iptables installed." >&2
        exit 1
    fi
    debug_echo "  iptables installed successfully"
fi

debug_echo "Configuring iptables rules..."

# Default policy: DROP everything
if ! iptables -P INPUT DROP 2>&1; then
    echo "ERROR: iptables failed - container may lack NET_ADMIN capability" >&2
    exit 1
fi
iptables -P OUTPUT DROP
iptables -P FORWARD DROP

set -e

# Allow loopback
debug_echo "  Allowing loopback..."
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Allow established/related connections
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Allow DNS to any destination
# Docker's DNS setup varies by network type: 127.0.0.11 on user-defined networks,
# host nameservers (router IP, etc.) on default bridge. Allow all outbound port 53
# rather than guessing - same approach as bwrap's slirp4netns resolver allowance.
debug_echo "  Allowing DNS..."
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT

debug_echo "  Adding network rules..."
IPTABLES_HEADER

    if [ "$mode" = "allowlist" ]; then
        # Allowlist: add ACCEPT rules for allowed destinations
        _generate_iptables_rules_for_items "$resolved_allow_ips" "ACCEPT" "-A"
        _generate_iptables_rules_for_items "$allow_networks" "ACCEPT" "-A"
        # Default DROP policy handles everything else

    elif [ "$mode" = "blocklist" ]; then
        # Blocklist: add REJECT rules for blocked destinations, then allow all
        _generate_iptables_rules_for_items "$resolved_block_ips" "REJECT" "-A"
        _generate_iptables_rules_for_items "$block_networks" "REJECT" "-A"

        # Allow rules (inserted at beginning to take precedence)
        _generate_iptables_rules_for_items "$resolved_allow_ips" "ACCEPT" "-I"
        _generate_iptables_rules_for_items "$allow_networks" "ACCEPT" "-I"

        # Final catch-all: allow everything else
        echo "iptables -A OUTPUT -j ACCEPT"
    fi
}

# Resolve domains to IPs for Docker network filtering
# Must be done on host before container starts (DNS works on host)
# Arguments:
#   $1 - domains: pipe-separated domain specs (domain:port or just domain)
# Returns: pipe-separated IP specs
resolve_domains_for_docker() {
    local domains="$1"
    local resolved=""

    [ -z "$domains" ] && return

    IFS='|' read -ra items <<< "$domains"
    for item in "${items[@]}"; do
        local domain ports
        if [[ "$item" =~ ^(.+):([0-9,]+)$ ]]; then
            domain="${BASH_REMATCH[1]}"
            ports="${BASH_REMATCH[2]}"
        else
            domain="$item"
            ports=""
        fi

        local ips
        ips=$(resolve_domain "$domain")

        if [ -z "$ips" ]; then
            echo "Warning: Could not resolve domain '$domain', skipping..." >&2
            continue
        fi

        while IFS= read -r ip; do
            [ -z "$ip" ] && continue
            if [ -n "$ports" ]; then
                resolved="${resolved}${resolved:+|}${ip}:${ports}"
            else
                resolved="${resolved}${resolved:+|}${ip}"
            fi
        done <<< "$ips"
    done

    echo "$resolved"
}

# Generate script to install packages in Docker container
# Installs configured packages if not already present
# This runs as root inside the container before dropping privileges
# Arguments:
#   $1 - pipe-separated list of packages to install (e.g., "curl|iputils-ping")
generate_docker_tool_install_script() {
    local packages="$1"

    # Always define debug_echo (used by later setup steps too)
    cat << 'TOOLS_HEADER'
# Helper for verbose output
debug_echo() { [ "$CAGE_VERBOSE" = "1" ] && echo "$@" >&2 || true; }

# Install apt-utils first to suppress debconf warnings during package installs
if command -v apt-get >/dev/null 2>&1 && ! dpkg -s apt-utils >/dev/null 2>&1; then
    debug_echo "Installing apt-utils..."
    { apt-get update -qq && apt-get install -qq -y apt-utils; } >/dev/null 2>&1 || true
fi
TOOLS_HEADER

    # No packages to install
    [ -z "$packages" ] && return

    # Convert pipe-separated list to space-separated for package managers
    local pkg_list="${packages//|/ }"

    # Pick the first package to use as presence check
    local check_pkg="${packages%%|*}"

    cat << TOOLS_EOF
# Install packages if missing
if ! dpkg -s $check_pkg >/dev/null 2>&1 && ! command -v $check_pkg >/dev/null 2>&1; then
    debug_echo "Installing packages: $pkg_list"
    if command -v apt-get >/dev/null 2>&1; then
        if [ "\$CAGE_VERBOSE" = "1" ]; then
            apt-get update && apt-get install -y $pkg_list || { echo "Package installation failed." >&2; exit 1; }
        else
            { apt-get update -qq >/dev/null && apt-get install -qq -y $pkg_list >/dev/null; } &
            _pid=\$!; while kill -0 \$_pid 2>/dev/null; do printf '.' >&2; sleep 1; done
            wait \$_pid || { echo >&2; echo "Package installation failed." >&2; exit 1; }
            echo >&2
        fi
    elif command -v apk >/dev/null 2>&1; then
        if [ "\$CAGE_VERBOSE" = "1" ]; then
            apk add $pkg_list || { echo "Package installation failed." >&2; exit 1; }
        else
            apk add --quiet $pkg_list >/dev/null &
            _pid=\$!; while kill -0 \$_pid 2>/dev/null; do printf '.' >&2; sleep 1; done
            wait \$_pid || { echo >&2; echo "Package installation failed." >&2; exit 1; }
            echo >&2
        fi
    elif command -v yum >/dev/null 2>&1; then
        if [ "\$CAGE_VERBOSE" = "1" ]; then
            yum install -y $pkg_list || { echo "Package installation failed." >&2; exit 1; }
        else
            yum install -q -y $pkg_list >/dev/null &
            _pid=\$!; while kill -0 \$_pid 2>/dev/null; do printf '.' >&2; sleep 1; done
            wait \$_pid || { echo >&2; echo "Package installation failed." >&2; exit 1; }
            echo >&2
        fi
    fi
fi
TOOLS_EOF
}

# Generate info messages to display after installs, right before launching
# Uses container-side env vars: CAGE_DIRECT_MOUNT, CAGE_AUTO_SYNC, CAGE_SOURCE_BRANCH
generate_docker_info_script() {
    cat << 'INFO_EOF'
# Info messages (after installs, before launch)
_ci='\033[36m'; _cw='\033[97m'; _cr='\033[0m'
if [ "$CAGE_DIRECT_MOUNT" = "true" ]; then
    echo -e "\n${_ci}⚠️  Direct mount: Changes are made directly to source files.${_cr}" >&2
elif [ "$CAGE_AUTO_SYNC" != "true" ]; then
    echo -e "\n${_ci}⚠️  Auto-sync is OFF for this cage (branch: $CAGE_SOURCE_BRANCH).${_cr}" >&2
    echo -e "${_ci}   To bring changes back to source, run: ${_cw}claude-cage git-merge${_cr}" >&2
    echo -e "${_ci}   (Must be run from branch '$CAGE_SOURCE_BRANCH')${_cr}" >&2
fi
echo -e "\n${_ci}⚠️  Inside the sandbox, use host.docker.internal to reach host services${_cr}" >&2
INFO_EOF
}

# Run a command inside a Docker container
# Usage: run_in_docker <intermediary_root> <session_work_root> <intermediary_dir> <work_dir> <pipe_path> <project_path> [command...]
#
# Arguments:
#   intermediary_root - Root of intermediary tree (for mounting at /run)
#   session_work_root         - Root of session work tree (for mounting all same-session projects)
#   intermediary_dir         - The specific project's intermediary (for isolated mode)
#   work_dir                 - The specific project's work directory (for isolated mode)
#   pipe_path                - Path to the communication pipe
#   project_path             - Original project path (working directory, isolated mount point)
#   [command...]             - Optional command to run (defaults to interactive shell)
#
# In non-isolated mode: mounts session_work_root dirs at /, intermediary_root at /run,
# making all same-session projects and intermediaries visible at original paths.
#
# In isolated mode: only work_dir and intermediary_dir are mounted.
#
# Network filtering (when networkMode is "allowlist" or "blocklist"):
#   - Container starts as root with NET_ADMIN capability
#   - iptables rules are configured
#   - Drops to unprivileged user before running shell
run_in_docker() {
    local intermediary_root="$1"
    local session_work_root="$2"
    local intermediary_dir="$3"
    local work_dir="$4"
    local pipe_path="$5"
    local project_path="$6"
    shift 6

    local user_uid user_gid user_home
    user_uid=$(id -u)
    user_gid=$(id -g)
    user_home="$HOME"

    # Container settings
    local image="${cfg_docker_image:-node:lts-slim}"
    local container_name="claude-cage-$$"
    local hostname="caged.docker"

    # Check if network filtering is enabled
    local network_enabled=false
    if [ "$cfg_networkMode" = "allowlist" ] || [ "$cfg_networkMode" = "blocklist" ]; then
        network_enabled=true
        [ "$verbose" = true ] && echo "Docker network filtering: $cfg_networkMode" >&2
    fi

    # Resolve domains before container starts (DNS works on host)
    local resolved_allow_ips=""
    local resolved_block_ips=""

    if [ "$network_enabled" = true ]; then
        # Use pre-resolved values from main.sh if available
        if [ "${domains_pre_resolved:-}" = true ]; then
            resolved_allow_ips="${pre_resolved_allow_ips:-}"
            resolved_block_ips="${pre_resolved_block_ips:-}"
        else
            if [ -n "$cfg_allow_domains" ]; then
                [ "$verbose" = true ] && echo "Resolving allowed domains..." >&2
                resolved_allow_ips=$(resolve_domains_for_docker "$cfg_allow_domains")
            fi
            if [ -n "$cfg_block_domains" ]; then
                [ "$verbose" = true ] && echo "Resolving blocked domains..." >&2
                resolved_block_ips=$(resolve_domains_for_docker "$cfg_block_domains")
            fi
        fi

        # Add configured IPs to resolved list
        if [ -n "$cfg_allow_ips" ]; then
            resolved_allow_ips="${resolved_allow_ips}${resolved_allow_ips:+|}${cfg_allow_ips}"
        fi
        if [ -n "$cfg_block_ips" ]; then
            resolved_block_ips="${resolved_block_ips}${resolved_block_ips:+|}${cfg_block_ips}"
        fi
    fi

    # Build docker arguments as an array
    local -a docker_args=()

    docker_args+=(run --rm -it)
    docker_args+=(--name "$container_name")
    docker_args+=(--hostname "$hostname")
    docker_args+=(--add-host=host.docker.internal:host-gateway)

    if [ "$network_enabled" = true ]; then
        # Network filtering: add NET_ADMIN capability for iptables
        docker_args+=(--cap-add=NET_ADMIN)
    fi
    # Always start as root to install packages, then drop privileges

    # Enumerate projects and build mount specs using shared functions
    enumerate_projects "$session_work_root" "$intermediary_root" "$work_dir" "$intermediary_dir" "$project_path"
    build_mount_specs "$intermediary_dir" "$work_dir" "$project_path" "$pipe_path" "$user_home"

    # Apply mounts from shared CAGE_MOUNTS array
    # Docker skips tmpfs (uses container's own filesystem)
    for spec in "${CAGE_MOUNTS[@]}"; do
        IFS='|' read -r type source dest mode <<< "$spec"
        case "$type" in
            bind|pipe)
                # Docker needs the source to exist (except in dry-run)
                if [ -e "$source" ] || [ -p "$source" ] || [ "$dry_run" = true ]; then
                    if [ "$mode" = "ro" ]; then
                        docker_args+=(-v "$source:$dest:ro")
                    else
                        docker_args+=(-v "$source:$dest")
                    fi
                fi
                ;;
            tmpfs)
                # Docker handles /tmp and /run internally via its container image
                ;;
        esac
    done

    # Working directory is the project path
    docker_args+=(-w "$project_path")

    # Environment
    docker_args+=(-e "HOME=$user_home")
    docker_args+=(-e "TERM=${TERM:-xterm-256color}")
    docker_args+=(-e "LANG=C.UTF-8")
    docker_args+=(-e "DEBIAN_FRONTEND=noninteractive")
    docker_args+=(-e "CAGE_DIRECT_MOUNT=${direct_mount_mode:-false}")
    docker_args+=(-e "CAGE_AUTO_SYNC=${cfg_autoSync:-false}")
    docker_args+=(-e "CAGE_SOURCE_BRANCH=${source_branch:-}")
    [ "$verbose" = true ] && docker_args+=(-e "CAGE_VERBOSE=1")
    [ "$debug" = true ] && docker_args+=(-e "CAGE_DEBUG=1")

    # Image
    docker_args+=("$image")

    # Generate setup scripts
    local tool_install_script
    tool_install_script=$(generate_docker_tool_install_script "$cfg_docker_packages")

    local iptables_script=""
    if [ "$network_enabled" = true ]; then
        iptables_script=$(generate_docker_iptables_script "$cfg_networkMode" \
            "$resolved_allow_ips" "$cfg_allow_networks" \
            "$resolved_block_ips" "$cfg_block_networks")
    fi

    local info_script
    info_script=$(generate_docker_info_script)

    # Add command or interactive shell
    if [ $# -eq 0 ]; then
        # Interactive shell
        docker_args+=(/bin/bash -c "
$tool_install_script

$iptables_script

$info_script

# Create user with matching UID for privilege drop
debug_echo \"Creating sandbox user (uid=${user_uid}, gid=${user_gid})...\"
groupadd -g ${user_gid} -o cage 2>/dev/null || true
useradd -u ${user_uid} -g ${user_gid} -o -m -d \"${user_home}\" -s /bin/bash cage 2>/dev/null || true

# Create bashrc with cage prompt
cat > /tmp/.cage-bashrc << 'RCEOF'
[ -f /etc/bash.bashrc ] && . /etc/bash.bashrc
[ -f ~/.bashrc ] 2>/dev/null && . ~/.bashrc
export PATH=\"\$HOME/.local/bin:\$PATH\"
# Cage prompt - red user@caged with bunny (Con Air style)
PS1=\"\[\e[1;31m\]\u@caged\[\e[0m\] 🐰 \w\\\$ \"
RCEOF

# Drop privileges and run shell
debug_echo \"Launching shell...\"
exec script -q -c \"su -s /bin/bash cage -c 'exec bash --rcfile /tmp/.cage-bashrc'\" /dev/null 2>/dev/null || \\
exec su -s /bin/bash cage -c 'exec bash --rcfile /tmp/.cage-bashrc'
")
    else
        # Command
        docker_args+=(/bin/bash -c "
$tool_install_script

$iptables_script

$info_script

# Create user with matching UID for privilege drop
debug_echo \"Creating sandbox user (uid=${user_uid}, gid=${user_gid})...\"
groupadd -g ${user_gid} -o cage 2>/dev/null || true
useradd -u ${user_uid} -g ${user_gid} -o -m -d \"${user_home}\" -s /bin/bash cage 2>/dev/null || true

# Drop privileges and run command
debug_echo \"Running: $*\"
exec su -s /bin/bash -c 'export PATH=\"\$HOME/.local/bin:\$PATH\"; $*' cage
")
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
