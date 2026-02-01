# ============================================================================
# Network isolation via slirp4netns
# ============================================================================
#
# Provides unprivileged network filtering using:
# - slirp4netns for userspace networking in network namespaces
# - iptables rules configured inside the namespace (CAP_NET_ADMIN)
#
# slirp4netns network layout:
#   10.0.2.2  - Host loopback (maps to 127.0.0.1 on host)
#   10.0.2.3  - DNS resolver
#   10.0.2.15 - Sandbox's own IP (default)

# Check if slirp4netns is available
check_slirp4netns() {
    if ! command -v slirp4netns >/dev/null 2>&1; then
        echo "We got a problem. I need slirp4netns for network filtering."
        echo "Install it: sudo apt install slirp4netns"
        exit 1
    fi
}

# Check if unprivileged user namespaces are available
# Tests the exact unshare flags we'll use for network isolation
check_userns() {
    # Skip check in dry-run mode
    if [ "$dry_run" = true ]; then
        echo "[dry-run] check_userns (unshare --user --map-root-user --net)"
        return 0
    fi

    local error_output
    error_output=$(unshare --user --map-root-user --net true 2>&1)
    local exit_code=$?

    if [ $exit_code -ne 0 ]; then
        echo "Well this ain't gonna work. Unprivileged user namespaces are not available."
        echo ""
        echo "Error: $error_output"
        echo ""
        echo "Network filtering requires user namespace support. To enable it:"
        echo ""

        # Check for AppArmor restriction (Ubuntu 23.10+)
        local apparmor_restrict
        apparmor_restrict=$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null)
        if [ "$apparmor_restrict" = "1" ]; then
            echo "  AppArmor is blocking unprivileged user namespaces."
            echo ""
            echo "  # Temporary (until reboot):"
            echo "  sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0"
            echo ""
            echo "  # Permanent:"
            echo "  echo 'kernel.apparmor_restrict_unprivileged_userns=0' | sudo tee /etc/sysctl.d/userns.conf"
            echo "  sudo sysctl --system"
        elif [ -f /proc/sys/kernel/unprivileged_userns_clone ]; then
            local userns_clone
            userns_clone=$(cat /proc/sys/kernel/unprivileged_userns_clone 2>/dev/null)
            if [ "$userns_clone" = "0" ]; then
                echo "  User namespaces are DISABLED (kernel.unprivileged_userns_clone=0)."
                echo ""
                echo "  # Temporary (until reboot):"
                echo "  sudo sysctl -w kernel.unprivileged_userns_clone=1"
                echo ""
                echo "  # Permanent:"
                echo "  echo 'kernel.unprivileged_userns_clone=1' | sudo tee /etc/sysctl.d/userns.conf"
                echo "  sudo sysctl --system"
            else
                echo "  User namespaces appear enabled but still blocked."
                echo "  This may be an AppArmor/SELinux policy issue."
            fi
        else
            echo "  Your kernel may not support unprivileged user namespaces."
        fi
        echo ""
        echo "Alternatively, use networkMode = \"disabled\" to skip network filtering."
        exit 1
    fi
}

# Check if iptables is available
check_iptables() {
    # Skip check in dry-run mode
    if [ "$dry_run" = true ]; then
        echo "[dry-run] check_iptables"
        return 0
    fi

    if ! command -v iptables >/dev/null 2>&1; then
        echo "Gonna need iptables for the network stuff."
        echo "Install it: sudo apt install iptables"
        exit 1
    fi
}

# Resolve domain to IPs
# Extracted from main claude-cage script
resolve_domain() {
    local domain="$1"
    # Use getent to resolve domain (supports /etc/hosts and DNS)
    getent ahosts "$domain" 2>/dev/null | awk '{print $1}' | sort -u
}

# Parse IP/domain:port specification
# Returns: ip|ports (pipe-separated)
# Extracted from main claude-cage script
parse_ip_port() {
    local spec="$1"
    local ip=""
    local ports=""

    if [[ "$spec" =~ ^(.+):([0-9,]+)$ ]]; then
        ip="${BASH_REMATCH[1]}"
        ports="${BASH_REMATCH[2]}"
    else
        ip="$spec"
        ports=""
    fi

    echo "$ip|$ports"
}

# Add iptables rule (simplified, Linux-only version)
# Usage: add_iptables_rule <action> <ip_or_network> [ports] [insert_mode]
# action: ACCEPT, DROP, or REJECT
# ports: comma-separated list or single port (optional)
# insert_mode: "insert" to add at beginning of chain (optional)
add_iptables_rule() {
    local action="$1"
    local ip_or_network="$2"
    local ports="$3"
    local insert_mode="$4"

    # Translate 127.0.0.1 to 10.0.2.2 (slirp4netns host loopback)
    # Inside the sandbox, 127.0.0.1 is the sandbox's own loopback
    # 10.0.2.2 maps to the host's 127.0.0.1
    if [[ "$ip_or_network" == "127.0.0.1"* ]]; then
        ip_or_network="${ip_or_network/127.0.0.1/10.0.2.2}"
    fi

    local iptables_flag="-A"
    if [ "$insert_mode" = "insert" ]; then
        iptables_flag="-I"
    fi

    if [ "$dry_run" = true ]; then
        if [ -z "$ports" ]; then
            echo "[dry-run] iptables $iptables_flag OUTPUT -d $ip_or_network -j $action"
        elif [[ "$ports" == *","* ]]; then
            echo "[dry-run] iptables $iptables_flag OUTPUT -p tcp -d $ip_or_network -m multiport --dports $ports -j $action"
            echo "[dry-run] iptables $iptables_flag OUTPUT -p udp -d $ip_or_network -m multiport --dports $ports -j $action"
        else
            echo "[dry-run] iptables $iptables_flag OUTPUT -p tcp -d $ip_or_network --dport $ports -j $action"
            echo "[dry-run] iptables $iptables_flag OUTPUT -p udp -d $ip_or_network --dport $ports -j $action"
        fi
        return 0
    fi

    if [ -z "$ports" ]; then
        # No port restriction - allow/block all ports
        iptables $iptables_flag OUTPUT -d "$ip_or_network" -j "$action"
    else
        # Port restriction - apply to TCP and UDP
        if [[ "$ports" == *","* ]]; then
            # Multiple ports - use multiport
            iptables $iptables_flag OUTPUT -p tcp -d "$ip_or_network" -m multiport --dports "$ports" -j "$action"
            iptables $iptables_flag OUTPUT -p udp -d "$ip_or_network" -m multiport --dports "$ports" -j "$action"
        else
            # Single port
            iptables $iptables_flag OUTPUT -p tcp -d "$ip_or_network" --dport "$ports" -j "$action"
            iptables $iptables_flag OUTPUT -p udp -d "$ip_or_network" --dport "$ports" -j "$action"
        fi
    fi
}

# Add iptables rules for a batch of domains/IPs/networks
# Usage: add_iptables_rules_batch <action> <type> <config_var> [insert_mode]
# type: "domains", "ips", or "networks"
# config_var: pipe-separated list of addresses (e.g., "domain1:443|domain2")
add_iptables_rules_batch() {
    local action="$1"
    local type="$2"
    local config_var="$3"
    local insert_mode="$4"

    [ -z "$config_var" ] && return 0

    IFS='|' read -ra items <<< "$config_var"
    for item_spec in "${items[@]}"; do
        local parsed
        parsed=$(parse_ip_port "$item_spec")
        local item="${parsed%%|*}"
        local ports="${parsed#*|}"

        if [ "$type" = "domains" ]; then
            # Resolve domain to IPs
            local resolved_ips
            resolved_ips=$(resolve_domain "$item")
            if [ -z "$resolved_ips" ]; then
                echo "Warning: Could not resolve domain '$item', skipping..." >&2
                continue
            fi
            while IFS= read -r ip; do
                [ -n "$ip" ] && add_iptables_rule "$action" "$ip" "$ports" "$insert_mode"
            done <<< "$resolved_ips"
        else
            # IPs or networks - add directly
            add_iptables_rule "$action" "$item" "$ports" "$insert_mode"
        fi
    done
}

# Setup base iptables rules inside namespace
# These are the foundation rules applied before allow/block lists
setup_base_iptables() {
    if [ "$dry_run" = true ]; then
        echo "[dry-run] iptables -P INPUT DROP"
        echo "[dry-run] iptables -P OUTPUT DROP"
        echo "[dry-run] iptables -P FORWARD DROP"
        echo "[dry-run] iptables -A INPUT -i lo -j ACCEPT"
        echo "[dry-run] iptables -A OUTPUT -o lo -j ACCEPT"
        echo "[dry-run] iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"
        return 0
    fi

    # Default policy: DROP everything
    iptables -P INPUT DROP
    iptables -P OUTPUT DROP
    iptables -P FORWARD DROP

    # Allow loopback
    iptables -A INPUT -i lo -j ACCEPT
    iptables -A OUTPUT -o lo -j ACCEPT

    # Allow established/related connections (so replies come back)
    iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
}

# Setup DNS rules for slirp4netns resolver
# Must be called before other OUTPUT rules in allowlist mode
setup_dns_rules() {
    local slirp_dns="10.0.2.3"

    if [ "$dry_run" = true ]; then
        echo "[dry-run] iptables -A OUTPUT -d $slirp_dns -p udp --dport 53 -j ACCEPT"
        echo "[dry-run] iptables -A OUTPUT -d $slirp_dns -p tcp --dport 53 -j ACCEPT"
        return 0
    fi

    # Allow DNS to slirp4netns resolver
    iptables -A OUTPUT -d "$slirp_dns" -p udp --dport 53 -j ACCEPT
    iptables -A OUTPUT -d "$slirp_dns" -p tcp --dport 53 -j ACCEPT
}

# Setup iptables rules inside namespace based on network mode
# Called from inside the user+net namespace where we have CAP_NET_ADMIN
# Usage: setup_namespace_iptables <mode> <allow_domains> <allow_ips> <allow_networks> <block_domains> <block_ips> <block_networks>
setup_namespace_iptables() {
    local mode="$1"
    local allow_domains="$2"
    local allow_ips="$3"
    local allow_networks="$4"
    local block_domains="$5"
    local block_ips="$6"
    local block_networks="$7"

    if [ "$mode" = "disabled" ]; then
        [ "$verbose" = true ] && echo "Network restrictions: disabled" >&2
        return 0
    fi

    [ "$verbose" = true ] && echo "Setting up network restrictions (mode: $mode)..." >&2

    # Setup base rules (default DROP, allow loopback, allow established)
    setup_base_iptables

    # Always allow DNS to slirp resolver
    setup_dns_rules

    if [ "$mode" = "allowlist" ]; then
        # Allowlist mode: only allow specified destinations
        # Default policy is already DROP, so we just add ACCEPT rules

        add_iptables_rules_batch "ACCEPT" "domains" "$allow_domains"
        add_iptables_rules_batch "ACCEPT" "ips" "$allow_ips"
        add_iptables_rules_batch "ACCEPT" "networks" "$allow_networks"

        # No catch-all needed - default DROP policy handles it

    elif [ "$mode" = "blocklist" ]; then
        # Blocklist mode: block specified, allow everything else
        # Use REJECT instead of DROP so connections fail fast instead of hanging
        # REJECT sends ICMP unreachable / TCP RST back to sender

        # Add block rules first
        add_iptables_rules_batch "REJECT" "domains" "$block_domains"
        add_iptables_rules_batch "REJECT" "ips" "$block_ips"
        add_iptables_rules_batch "REJECT" "networks" "$block_networks"

        # Allow rules take precedence (inserted at beginning)
        add_iptables_rules_batch "ACCEPT" "domains" "$allow_domains" "insert"
        add_iptables_rules_batch "ACCEPT" "ips" "$allow_ips" "insert"
        add_iptables_rules_batch "ACCEPT" "networks" "$allow_networks" "insert"

        # Final catch-all: allow everything else
        if [ "$dry_run" = true ]; then
            echo "[dry-run] iptables -A OUTPUT -j ACCEPT"
        else
            iptables -A OUTPUT -j ACCEPT
        fi
    fi
}

# Run command in network-isolated namespace with slirp4netns
# This wraps the command in a user+net namespace, attaches slirp4netns,
# configures iptables, then runs the command
#
# Usage: run_with_network_namespace <mode> <allow_domains> <allow_ips> <allow_networks> <block_domains> <block_ips> <block_networks> -- <command...>
run_with_network_namespace() {
    local mode="$1"
    local allow_domains="$2"
    local allow_ips="$3"
    local allow_networks="$4"
    local block_domains="$5"
    local block_ips="$6"
    local block_networks="$7"
    shift 7

    # Skip the -- separator if present
    [ "$1" = "--" ] && shift

    # If network mode is disabled, just run the command directly
    if [ "$mode" = "disabled" ]; then
        "$@"
        return $?
    fi

    # Create synchronization primitives
    local ready_pipe
    ready_pipe=$(mktemp -u)
    mkfifo "$ready_pipe"

    local sandbox_pid_file
    sandbox_pid_file=$(mktemp)

    # Resolve domains BEFORE entering namespace (DNS works on host)
    # We'll pass the resolved IPs to the inner process
    local resolved_allow_domains=""
    local resolved_block_domains=""

    if [ -n "$allow_domains" ]; then
        [ "$verbose" = true ] && echo "Resolving allowed domains..." >&2
        IFS='|' read -ra domains <<< "$allow_domains"
        for domain_spec in "${domains[@]}"; do
            local parsed
            parsed=$(parse_ip_port "$domain_spec")
            local domain="${parsed%%|*}"
            local ports="${parsed#*|}"
            local ips
            ips=$(resolve_domain "$domain")
            if [ -n "$ips" ]; then
                while IFS= read -r ip; do
                    if [ -n "$ports" ]; then
                        resolved_allow_domains="${resolved_allow_domains}${resolved_allow_domains:+|}${ip}:${ports}"
                    else
                        resolved_allow_domains="${resolved_allow_domains}${resolved_allow_domains:+|}${ip}"
                    fi
                done <<< "$ips"
            else
                echo "Warning: Could not resolve domain '$domain', skipping..." >&2
            fi
        done
    fi

    if [ -n "$block_domains" ]; then
        [ "$verbose" = true ] && echo "Resolving blocked domains..." >&2
        IFS='|' read -ra domains <<< "$block_domains"
        for domain_spec in "${domains[@]}"; do
            local parsed
            parsed=$(parse_ip_port "$domain_spec")
            local domain="${parsed%%|*}"
            local ports="${parsed#*|}"
            local ips
            ips=$(resolve_domain "$domain")
            if [ -n "$ips" ]; then
                while IFS= read -r ip; do
                    if [ -n "$ports" ]; then
                        resolved_block_domains="${resolved_block_domains}${resolved_block_domains:+|}${ip}:${ports}"
                    else
                        resolved_block_domains="${resolved_block_domains}${resolved_block_domains:+|}${ip}"
                    fi
                done <<< "$ips"
            else
                echo "Warning: Could not resolve domain '$domain', skipping..." >&2
            fi
        done
    fi

    if [ "$dry_run" = true ]; then
        echo "[dry-run] mkfifo $ready_pipe"
        echo "[dry-run] unshare --user --map-root-user --net -- bash -c '...'"
        echo "[dry-run]   # Inside namespace:"
        echo "[dry-run]   echo \$\$ > $sandbox_pid_file"
        echo "[dry-run]   read < $ready_pipe  # wait for slirp4netns"
        setup_namespace_iptables "$mode" "$resolved_allow_domains" "$allow_ips" "$allow_networks" \
                                 "$resolved_block_domains" "$block_ips" "$block_networks"
        echo "[dry-run]   exec $*"
        echo "[dry-run] # Outside namespace:"
        echo "[dry-run] slirp4netns --ready-fd 3 --configure \$SANDBOX_PID tap0"
        echo "[dry-run] echo go > $ready_pipe"
        rm -f "$ready_pipe" "$sandbox_pid_file"
        return 0
    fi

    # Export variables for the inner script
    export NETWORK_MODE="$mode"
    export NETWORK_ALLOW_IPS="$allow_ips"
    export NETWORK_ALLOW_NETWORKS="$allow_networks"
    export NETWORK_BLOCK_IPS="$block_ips"
    export NETWORK_BLOCK_NETWORKS="$block_networks"
    export NETWORK_RESOLVED_ALLOW="$resolved_allow_domains"
    export NETWORK_RESOLVED_BLOCK="$resolved_block_domains"
    export READY_PIPE="$ready_pipe"
    export SANDBOX_PID_FILE="$sandbox_pid_file"
    export NETWORK_VERBOSE="$verbose"
    export NETWORK_DRY_RUN="$dry_run"

    # Get the path to the main script for re-sourcing in subprocess
    # This works whether running from src/ or from dist/
    export CLAUDE_CAGE_SCRIPT
    CLAUDE_CAGE_SCRIPT="$(realpath "$0")"

    # Start slirp4netns handler in background
    # This subshell waits for the namespace, starts slirp, signals ready, then waits
    (
        # Wait for the inner process to write its PID
        local wait_count=0
        while [ ! -s "$sandbox_pid_file" ] && [ $wait_count -lt 100 ]; do
            sleep 0.05
            wait_count=$((wait_count + 1))
        done

        if [ ! -s "$sandbox_pid_file" ]; then
            echo "Error: Timed out waiting for sandbox PID" >&2
            exit 1
        fi

        local sandbox_pid
        sandbox_pid=$(cat "$sandbox_pid_file")

        # Start slirp4netns
        slirp4netns --configure "$sandbox_pid" tap0 &
        local slirp_pid=$!

        # Give slirp4netns a moment to set up the interface
        sleep 0.3

        # Check if slirp4netns is still running
        if ! kill -0 $slirp_pid 2>/dev/null; then
            echo "Error: slirp4netns failed to start" >&2
            exit 1
        fi

        # Signal the inner process that networking is ready
        echo "go" > "$ready_pipe"

        # Wait for slirp4netns to finish (keeps it running)
        wait $slirp_pid
    ) &
    local slirp_handler_pid=$!

    # Clean up handler and temp files on exit
    trap 'kill $slirp_handler_pid 2>/dev/null; rm -f "$ready_pipe" "$sandbox_pid_file"' EXIT

    # Run unshare in foreground - this makes it receive terminal signals directly
    unshare --user --map-root-user --net -- bash -c '
        # Write our PID for the slirp handler
        echo $$ > "$SANDBOX_PID_FILE"

        # Wait for slirp4netns to be ready
        read < "$READY_PIPE"

        # Source the main script to get all function definitions
        export CLAUDE_CAGE_SOURCING=1
        source "$CLAUDE_CAGE_SCRIPT"

        # Set up variables for iptables functions
        verbose="$NETWORK_VERBOSE"
        dry_run="$NETWORK_DRY_RUN"

        # Configure iptables (we have CAP_NET_ADMIN here)
        setup_namespace_iptables "$NETWORK_MODE" \
            "$NETWORK_RESOLVED_ALLOW" "$NETWORK_ALLOW_IPS" "$NETWORK_ALLOW_NETWORKS" \
            "$NETWORK_RESOLVED_BLOCK" "$NETWORK_BLOCK_IPS" "$NETWORK_BLOCK_NETWORKS"

        # Execute the command
        exec "$@"
    ' -- "$@"

    local exit_code=$?

    # Cleanup (trap will handle killing slirp_handler)
    trap - EXIT
    kill $slirp_handler_pid 2>/dev/null
    wait $slirp_handler_pid 2>/dev/null
    rm -f "$ready_pipe" "$sandbox_pid_file"

    return $exit_code
}
