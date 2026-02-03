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
set -e

# Default policy: DROP everything
iptables -P INPUT DROP
iptables -P OUTPUT DROP
iptables -P FORWARD DROP

# Allow loopback
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Allow established/related connections
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Allow Docker's internal DNS (127.0.0.11)
iptables -A OUTPUT -d 127.0.0.11 -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -d 127.0.0.11 -p tcp --dport 53 -j ACCEPT

IPTABLES_HEADER

    if [ "$mode" = "allowlist" ]; then
        # Allowlist: add ACCEPT rules for allowed destinations
        if [ -n "$resolved_allow_ips" ]; then
            IFS='|' read -ra items <<< "$resolved_allow_ips"
            for item in "${items[@]}"; do
                local ip ports
                if [[ "$item" =~ ^(.+):([0-9,]+)$ ]]; then
                    ip="${BASH_REMATCH[1]}"
                    ports="${BASH_REMATCH[2]}"
                else
                    ip="$item"
                    ports=""
                fi

                if [ -z "$ports" ]; then
                    echo "iptables -A OUTPUT -d $ip -j ACCEPT"
                elif [[ "$ports" == *","* ]]; then
                    echo "iptables -A OUTPUT -p tcp -d $ip -m multiport --dports $ports -j ACCEPT"
                    echo "iptables -A OUTPUT -p udp -d $ip -m multiport --dports $ports -j ACCEPT"
                else
                    echo "iptables -A OUTPUT -p tcp -d $ip --dport $ports -j ACCEPT"
                    echo "iptables -A OUTPUT -p udp -d $ip --dport $ports -j ACCEPT"
                fi
            done
        fi

        if [ -n "$allow_networks" ]; then
            IFS='|' read -ra items <<< "$allow_networks"
            for item in "${items[@]}"; do
                local network ports
                if [[ "$item" =~ ^(.+):([0-9,]+)$ ]]; then
                    network="${BASH_REMATCH[1]}"
                    ports="${BASH_REMATCH[2]}"
                else
                    network="$item"
                    ports=""
                fi

                if [ -z "$ports" ]; then
                    echo "iptables -A OUTPUT -d $network -j ACCEPT"
                elif [[ "$ports" == *","* ]]; then
                    echo "iptables -A OUTPUT -p tcp -d $network -m multiport --dports $ports -j ACCEPT"
                    echo "iptables -A OUTPUT -p udp -d $network -m multiport --dports $ports -j ACCEPT"
                else
                    echo "iptables -A OUTPUT -p tcp -d $network --dport $ports -j ACCEPT"
                    echo "iptables -A OUTPUT -p udp -d $network --dport $ports -j ACCEPT"
                fi
            done
        fi
        # Default DROP policy handles everything else

    elif [ "$mode" = "blocklist" ]; then
        # Blocklist: add REJECT rules for blocked destinations, then allow all

        if [ -n "$resolved_block_ips" ]; then
            IFS='|' read -ra items <<< "$resolved_block_ips"
            for item in "${items[@]}"; do
                local ip ports
                if [[ "$item" =~ ^(.+):([0-9,]+)$ ]]; then
                    ip="${BASH_REMATCH[1]}"
                    ports="${BASH_REMATCH[2]}"
                else
                    ip="$item"
                    ports=""
                fi

                if [ -z "$ports" ]; then
                    echo "iptables -A OUTPUT -d $ip -j REJECT"
                elif [[ "$ports" == *","* ]]; then
                    echo "iptables -A OUTPUT -p tcp -d $ip -m multiport --dports $ports -j REJECT"
                    echo "iptables -A OUTPUT -p udp -d $ip -m multiport --dports $ports -j REJECT"
                else
                    echo "iptables -A OUTPUT -p tcp -d $ip --dport $ports -j REJECT"
                    echo "iptables -A OUTPUT -p udp -d $ip --dport $ports -j REJECT"
                fi
            done
        fi

        if [ -n "$block_networks" ]; then
            IFS='|' read -ra items <<< "$block_networks"
            for item in "${items[@]}"; do
                local network ports
                if [[ "$item" =~ ^(.+):([0-9,]+)$ ]]; then
                    network="${BASH_REMATCH[1]}"
                    ports="${BASH_REMATCH[2]}"
                else
                    network="$item"
                    ports=""
                fi

                if [ -z "$ports" ]; then
                    echo "iptables -A OUTPUT -d $network -j REJECT"
                elif [[ "$ports" == *","* ]]; then
                    echo "iptables -A OUTPUT -p tcp -d $network -m multiport --dports $ports -j REJECT"
                    echo "iptables -A OUTPUT -p udp -d $network -m multiport --dports $ports -j REJECT"
                else
                    echo "iptables -A OUTPUT -p tcp -d $network --dport $ports -j REJECT"
                    echo "iptables -A OUTPUT -p udp -d $network --dport $ports -j REJECT"
                fi
            done
        fi

        # Allow rules (inserted at beginning to take precedence)
        if [ -n "$resolved_allow_ips" ]; then
            IFS='|' read -ra items <<< "$resolved_allow_ips"
            for item in "${items[@]}"; do
                local ip ports
                if [[ "$item" =~ ^(.+):([0-9,]+)$ ]]; then
                    ip="${BASH_REMATCH[1]}"
                    ports="${BASH_REMATCH[2]}"
                else
                    ip="$item"
                    ports=""
                fi

                if [ -z "$ports" ]; then
                    echo "iptables -I OUTPUT -d $ip -j ACCEPT"
                elif [[ "$ports" == *","* ]]; then
                    echo "iptables -I OUTPUT -p tcp -d $ip -m multiport --dports $ports -j ACCEPT"
                    echo "iptables -I OUTPUT -p udp -d $ip -m multiport --dports $ports -j ACCEPT"
                else
                    echo "iptables -I OUTPUT -p tcp -d $ip --dport $ports -j ACCEPT"
                    echo "iptables -I OUTPUT -p udp -d $ip --dport $ports -j ACCEPT"
                fi
            done
        fi

        if [ -n "$allow_networks" ]; then
            IFS='|' read -ra items <<< "$allow_networks"
            for item in "${items[@]}"; do
                local network ports
                if [[ "$item" =~ ^(.+):([0-9,]+)$ ]]; then
                    network="${BASH_REMATCH[1]}"
                    ports="${BASH_REMATCH[2]}"
                else
                    network="$item"
                    ports=""
                fi

                if [ -z "$ports" ]; then
                    echo "iptables -I OUTPUT -d $network -j ACCEPT"
                elif [[ "$ports" == *","* ]]; then
                    echo "iptables -I OUTPUT -p tcp -d $network -m multiport --dports $ports -j ACCEPT"
                    echo "iptables -I OUTPUT -p udp -d $network -m multiport --dports $ports -j ACCEPT"
                else
                    echo "iptables -I OUTPUT -p tcp -d $network --dport $ports -j ACCEPT"
                    echo "iptables -I OUTPUT -p udp -d $network --dport $ports -j ACCEPT"
                fi
            done
        fi

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
        ips=$(getent ahosts "$domain" 2>/dev/null | awk '{print $1}' | sort -u)

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

# Run a command inside a Docker container
# Usage: run_in_docker <branch_intermediary_root> <branch_work_root> <intermediary_dir> <work_dir> <pipe_path> <project_path> [command...]
#
# Arguments:
#   branch_intermediary_root - Root of branch intermediary tree (for mounting at /run)
#   branch_work_root         - Root of branch work tree (for mounting all same-branch projects)
#   intermediary_dir         - The specific project's intermediary (for isolated mode)
#   work_dir                 - The specific project's work directory (for isolated mode)
#   pipe_path                - Path to the communication pipe
#   project_path             - Original project path (working directory, isolated mount point)
#   [command...]             - Optional command to run (defaults to interactive shell)
#
# In non-isolated mode: mounts branch_work_root dirs at /, branch_intermediary_root at /run,
# making all same-branch projects and intermediaries visible at original paths.
#
# In isolated mode: only work_dir and intermediary_dir are mounted.
#
# Network filtering (when networkMode is "allowlist" or "blocklist"):
#   - Container starts as root with NET_ADMIN capability
#   - iptables rules are configured
#   - Drops to unprivileged user before running shell
run_in_docker() {
    local branch_intermediary_root="$1"
    local branch_work_root="$2"
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
        if [ -n "$cfg_allow_domains" ]; then
            [ "$verbose" = true ] && echo "Resolving allowed domains..." >&2
            resolved_allow_ips=$(resolve_domains_for_docker "$cfg_allow_domains")
        fi
        # Add configured IPs to resolved list
        if [ -n "$cfg_allow_ips" ]; then
            resolved_allow_ips="${resolved_allow_ips}${resolved_allow_ips:+|}${cfg_allow_ips}"
        fi

        if [ -n "$cfg_block_domains" ]; then
            [ "$verbose" = true ] && echo "Resolving blocked domains..." >&2
            resolved_block_ips=$(resolve_domains_for_docker "$cfg_block_domains")
        fi
        # Add configured IPs to resolved list
        if [ -n "$cfg_block_ips" ]; then
            resolved_block_ips="${resolved_block_ips}${resolved_block_ips:+|}${cfg_block_ips}"
        fi
    fi

    # Build docker arguments as an array
    local -a docker_args=()

    docker_args+=(run --rm -it)
    docker_args+=(--name "$container_name")
    docker_args+=(--hostname "$hostname")

    if [ "$network_enabled" = true ]; then
        # Network filtering: start as root, add NET_ADMIN capability
        docker_args+=(--cap-add=NET_ADMIN)
        # Don't set --user here; we'll drop privileges after iptables setup
    else
        # No network filtering: run as current user directly
        docker_args+=(--user "${user_uid}:${user_gid}")
    fi

    # Enumerate projects and build mount specs using shared functions
    enumerate_projects "$branch_work_root" "$branch_intermediary_root" "$work_dir" "$intermediary_dir" "$project_path"
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
    docker_args+=(-e "LANG=${LANG:-C.UTF-8}")

    # Image
    docker_args+=("$image")

    # Add command or interactive shell
    if [ "$network_enabled" = true ]; then
        # Network filtering enabled: generate iptables script and drop privileges
        local iptables_script
        iptables_script=$(generate_docker_iptables_script "$cfg_networkMode" \
            "$resolved_allow_ips" "$cfg_allow_networks" \
            "$resolved_block_ips" "$cfg_block_networks")

        if [ $# -eq 0 ]; then
            # Interactive shell with network filtering
            # Use heredoc to embed the iptables script
            docker_args+=(/bin/bash -c "
$iptables_script

# Create bashrc with cage prompt
cat > /tmp/.cage-bashrc << 'RCEOF'
[ -f /etc/bash.bashrc ] && . /etc/bash.bashrc
[ -f ~/.bashrc ] 2>/dev/null && . ~/.bashrc
# Cage prompt - red user@caged with bunny (Con Air style)
PS1=\"\[\e[1;31m\]\u@caged\[\e[0m\] 🐰 \w\\\$ \"
RCEOF

# Drop privileges and run shell
# Use su with preserved environment
exec su -s /bin/bash -c 'exec bash --rcfile /tmp/.cage-bashrc' - \"#${user_uid}\" 2>/dev/null || \\
exec su -s /bin/bash -c 'exec bash --rcfile /tmp/.cage-bashrc' nobody
")
        else
            # Command with network filtering
            docker_args+=(/bin/bash -c "
$iptables_script

# Drop privileges and run command
exec su -s /bin/bash -c '$*' - \"#${user_uid}\" 2>/dev/null || \\
exec su -s /bin/bash -c '$*' nobody
")
        fi
    else
        # No network filtering: run as user directly
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
