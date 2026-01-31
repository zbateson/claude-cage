# Network Security

claude-cage can add kernel-level network restrictions (iptables/pf) on top of Claude Code's process sandbox. This provides defense in depth - if one layer fails, the other still protects you.

## Network Modes

### Disabled (Default)

```lua
networkMode = "disabled"
```

No additional network restrictions. Relies on Claude Code's built-in network isolation (namespace removed, traffic routed through proxy, prompts for new domains).

### Allowlist Mode

Only allow specific IPs/domains, deny everything else. Provides maximum security but requires explicit configuration for any service Claude needs to access.

```lua
claude_cage {
    networkMode = "allowlist",

    allow = {
        domains = {
            "github.com:443",              -- Only HTTPS
            "registry.npmjs.org:443",      -- Only HTTPS
            "pypi.org"                     -- All ports
        },
        ips = {
            "1.2.3.4:80,443",              -- Only HTTP and HTTPS
            "127.0.0.1:5432",              -- Localhost PostgreSQL only
            "5.6.7.8"                      -- All ports
        },
        networks = {
            "10.0.0.0/24:443",             -- Internal network, HTTPS only
            "192.168.1.0/24"               -- All ports
        }
    }
}
```

**Note:** Allowlist mode will break WebFetch, package managers, and git unless you explicitly allow those domains.

### Blocklist Mode

Block specific IPs/domains, allow everything else. More practical for most use cases - Claude can still access the internet while protecting specific internal resources.

```lua
claude_cage {
    networkMode = "blocklist",

    block = {
        networks = {
            "192.168.1.0/24",              -- Entire home network
            "10.0.0.0/8:22,3389"           -- Corporate network, SSH/RDP only
        },
        ips = {
            "169.254.169.254",             -- AWS metadata service
            "192.168.1.100:5432",          -- Production database
            "127.0.0.1"                    -- All localhost
        },
        domains = {
            "internal.company.com",        -- All ports
            "vault.company.com:443",       -- HTTPS only
            "admin.local:80,443"           -- HTTP and HTTPS
        }
    }
}
```

## Blocklist Exceptions

In blocklist mode, you can use `allow.domains`, `allow.ips`, and `allow.networks` to create exceptions. This is useful when you want to block a broad range but allow specific services.

**Example: Block localhost except PostgreSQL**

```lua
claude_cage {
    networkMode = "blocklist",
    block = { ips = { "127.0.0.1" } },
    allow = { ips = { "127.0.0.1:5432" } }  -- Exception
}
```

**Example: Block private network except development servers**

```lua
claude_cage {
    networkMode = "blocklist",
    block = { networks = { "192.168.0.0/16" } },
    allow = {
        ips = {
            "192.168.1.50:3000",           -- Dev server 1
            "192.168.1.51:8080"            -- Dev server 2
        }
    }
}
```

Exceptions are processed first (as ACCEPT rules), then block rules are applied. This follows iptables rule ordering.

## Port Specification

You can optionally specify ports for fine-grained control:

- **No port**: `"1.2.3.4"` - All ports (TCP and UDP)
- **Single port**: `"1.2.3.4:443"` - Only port 443
- **Multiple ports**: `"1.2.3.4:80,443,8080"` - Only ports 80, 443, and 8080

Port restrictions apply to both TCP and UDP protocols.

### Common Port Numbers

- `80` - HTTP
- `443` - HTTPS
- `22` - SSH
- `3389` - RDP (Remote Desktop)
- `5432` - PostgreSQL
- `3306` - MySQL
- `27017` - MongoDB
- `6379` - Redis
- `3000-9000` - Common development server ports

## Network Rules in bwrap Mode

When running multiple projects in bwrap mode, network rules are cumulative:

**How it works:**
- All network rules from all running projects are combined into one shared chain
- Example:
  - Project 1 starts with allowlist: `["github.com"]`
  - Project 2 starts with allowlist: `["npmjs.org"]`
  - Result: Both projects can access `github.com` AND `npmjs.org`
- In allowlist mode: Each project adds to the allowed connections
- In blocklist mode: Each project adds to the blocked connections

**Important:**
- The first project sets the `networkMode` (allowlist or blocklist)
- Subsequent projects should use the same mode
- Rules persist until the last instance exits
- When all instances shut down, rules are cleaned up

## Network Rules in Docker Mode

In Docker mode, network isolation is simpler:
- `networkMode = "disabled"` or `"allowlist"`: Container runs with `--network=none` (no network access)
- `networkMode = "blocklist"`: Container runs with `--network=bridge` (full network access)

Docker doesn't support granular destination filtering without host iptables. If you need fine-grained network control, use bwrap mode instead.

## When to Use Each Mode

**Disabled:**
- You trust Claude Code's sandbox completely
- You don't need additional network isolation
- Simplest configuration

**Allowlist:**
- Maximum security required
- Working with highly sensitive data
- You know exactly what services Claude needs
- Willing to debug connection issues

**Blocklist:**
- Practical security for most use cases
- Want to protect specific internal resources
- Claude can still access documentation, packages, APIs
- Recommended for most users

## Defense in Depth

Network restrictions provide an additional layer of security:

```
Layer 1: OS User Isolation (claude-cage)
    └─> Layer 2: OS Network Restrictions (iptables/pf)
        └─> Layer 3: Process Sandbox (Claude Code /sandbox)
            └─> Layer 4: Claude AI Safety Training
```

**Benefits:**
- Defense in depth: iptables rules are independent of sandbox namespace/proxy
- Kernel-level enforcement that can't be bypassed from userspace
- Independent of application bugs or vulnerabilities
- Applies to all processes for the user, not just sandboxed ones
- You control the security policy at the OS level

## Implementation Details

- Uses iptables with the `owner` module to restrict connections from the configured user
- Domains are resolved to IPs at runtime using `getent`
- Rules are automatically cleaned up when the script exits
- Restrictions apply to all processes running as the configured user
- IPv4 only (IPv6 support not currently implemented)

## Testing Network Restrictions

Use test mode to verify your network configuration:

```bash
sudo claude-cage --test
```

Then inside the test shell:

```bash
# Test blocked connections
curl -I http://127.0.0.1:80 --connect-timeout 2

# Test allowed connections
curl -I https://github.com --connect-timeout 2

# Test specific ports
curl -I http://192.168.1.100:5432 --connect-timeout 2
```

Expected results:
- Blocked: `curl: (7) Failed to connect` or `Operation not permitted`
- Allowed: HTTP response headers
