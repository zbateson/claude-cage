# CLAUDE.md

Documentation for `claude-cage` - a lightweight sandboxed git workflow for Claude Code.

## Overview

`claude-cage` creates an isolated sandbox for Claude Code using git-based file isolation. It creates a sanitized copy of your project (excluding sensitive files) and uses git to sync changes back.

**Key features:**
- No sudo required - runs as current user
- Git-based sync - uses git archive + fresh init
- File exclusion at archive time (no history of excluded files)
- Network filtering via slirp4netns (optional)

## Architecture

```
Source Project                    ~/.cache/.../intermediary        ~/.cache/.../work
(your actual repo)                (sanitized, fresh git)           (Claude's workspace)
       │                                   │                              │
       │  git ls-files + tar               │     git clone                │
       │  (excludes applied)               │                              │
       └──────────────────────────────────>│──────────────────────────────>
                                           │                              │
                                           │<────── git push ─────────────┤
                                           │     (Claude commits)         │
                                           │                              │
       │<──── format-patch/git-am ─────────┤                              │
       │     (via named pipe)              │                              │
```

### Three-Repository Model

1. **Source** - Your actual project with full git history
2. **Intermediary** (`~/.cache/claude-cage/<branch>/intermediary/<project-path>/`) - Fresh git repo on `claude` branch, excluded files removed, no history of sensitive data
3. **Work** (`~/.cache/claude-cage/<branch>/work/<project-path>/`) - Clone of intermediary on `claude` branch where Claude works

Each source branch gets its own isolated cache directories, allowing concurrent sessions on different branches.

Both intermediary and work use a single `claude` branch. Intermediary has `receive.denyCurrentBranch=updateInstead` to allow pushing to the checked-out branch.

### Why Intermediary?

The intermediary repo serves as a buffer:
- Claude's git remote points here, not your source
- Post-receive hook triggers sync to source
- Prevents accidental direct access to source history
- Clean slate - no git history containing excluded files
- Located in `~/.cache/` - no `.gitignore` entry needed in your project

## Source Files

| File | Purpose |
|------|---------|
| `src/helpers.sh` | `run`, `run_quiet`, color codes, dry-run support |
| `src/banner.sh` | ASCII art banner (print_banner) |
| `src/config.sh` | Lua-based config parsing, finds claude-cage.config |
| `src/git-clone.sh` | `create_intermediary_clone()` - archives source with excludes |
| `src/git-hooks.sh` | Git hooks for communication pipe and commit sync |
| `src/git-sync.sh` | `sync_to_source()`, pipe listener, manual merge |
| `src/bwrap.sh` | `run_in_bwrap()` - bubblewrap sandbox |
| `src/docker.sh` | `run_in_docker()` - Docker container sandbox |
| `src/main.sh` | Entry point - wires everything together |

### Build Output

`dist/claude-cage` is the concatenated script (all src files in order).

```bash
make        # Build dist/claude-cage
make clean  # Remove built file
```

## Sync Mechanism

### Outbound (Claude -> Source)

When `autoMerge = true`:

1. Claude makes commits in the work directory
2. Claude runs `git push origin`
3. Intermediary's `post-receive` hook fires
4. Hook writes `<refname> <newrev>` to named pipe (`$XDG_RUNTIME_DIR/claude-cage/pipes/<project-path>`)
5. Pipe listener on host reads the message
6. `sync_to_source()` runs:
   - Skips initial commit (just a copy)
   - Uses `git format-patch` on intermediary
   - Applies to source with `git am --3way`

### Inbound (Source -> Intermediary)

When you commit to source:

1. `post-commit` hook on source fires
2. Creates patch excluding sensitive files using pathspec excludes
3. Applies patch to intermediary's `claude` branch with `git am`
4. Claude runs `git pull` when ready to get changes

If commit only contains excluded files, shows: "Only excluded files in this commit, nothin' to sync."

### Commit Separation

`pre-commit` hook on source prevents mixing excluded and included files in the same commit. This ensures patches can be cleanly created without sensitive data.

## Configuration

Uses same `claude-cage.config` format as main project:

```lua
claude_cage {
    exclude = { ".env", "secrets/**", ".git/config" },
    mode = "bwrap",  -- or "docker"
    autoMerge = true,  -- enable real-time sync
    showBanner = true,

    -- Network filtering (bwrap mode only)
    networkMode = "allowlist",  -- "disabled", "allowlist", or "blocklist"
    allow = {
        domains = { "github.com:443", "api.anthropic.com:443" },
        ips = { "8.8.8.8:53" },
        networks = { "10.0.0.0/8" }
    },
    block = {
        domains = { "internal.company.com" },
        ips = { "169.254.169.254" }  -- AWS metadata
    }
}
```

**Note:** The git version uses a flat exclude array, not nested `name`/`path` tables.

### Key Options

| Option | Default | Description |
|--------|---------|-------------|
| `exclude` | `{}` | Patterns to exclude from archive |
| `mode` | `"bwrap"` | Sandbox mode: `"bwrap"` or `"docker"` |
| `autoMerge` | `false` | Enable real-time sync via named pipe |
| `showBanner` | `true` | Show ASCII banner |
| `additionalMounts` | `{}` | Extra read-only mounts for sandbox |
| `networkMode` | `"disabled"` | Network filtering: `"disabled"`, `"allowlist"`, `"blocklist"` |
| `allow` | `{}` | Allowed destinations (domains, ips, networks with optional ports) |
| `block` | `{}` | Blocked destinations (domains, ips, networks with optional ports) |

## CLI Usage

```bash
# Basic usage - creates intermediary + work, shows sandbox info
./claude-cage

# Drop into sandbox shell for testing
./claude-cage --test

# Manual merge (fetch refs from intermediary)
./claude-cage git-merge

# Dry run (show commands without executing)
./claude-cage --dry-run

# Verbose output
./claude-cage --verbose
./claude-cage -v
```

## Current State

### Implemented

- [x] Config parsing (Lua-based, same as main claude-cage)
- [x] `create_intermediary_clone()` - git ls-files + tar with excludes
- [x] Fresh git init (no history of excluded files)
- [x] Work directory clone with `claude` branch
- [x] `run_in_bwrap()` - full bwrap sandbox
- [x] `run_in_docker()` - Docker container sandbox
- [x] Named pipe communication (`$XDG_RUNTIME_DIR/claude-cage/pipes/`)
- [x] `post-receive` hook on intermediary
- [x] `sync_to_source()` using format-patch/git-am
- [x] Pipe listener background process
- [x] `pre-commit` hook (prevents mixed commits)
- [x] `post-commit` hook (syncs source -> intermediary)
- [x] `manual_git_merge()` for manual sync
- [x] Cleanup on exit
- [x] `receive.denyCurrentBranch=updateInstead` for push to checked-out branch
- [x] Network isolation via slirp4netns (bwrap mode, no sudo required)
- [x] Comprehensive test suite (111 tests across 9 files)
- [x] Cache-based directory structure (`~/.cache/claude-cage/`) - no .gitignore needed

### Known Issues / TODO

- [ ] **No Claude Code launch yet** - only `--test` mode works (drops into shell)
- [x] Build script (`make`) - concatenates src/ to dist/
- [ ] Header/shebang handling in dist needs verification
- [ ] Testing on actual Claude Code workflow
- [ ] Conflict resolution when git-am fails
- [ ] Instance tracking (multiple concurrent runs)
- [ ] Network filtering for Docker mode (requires different approach)

## Network Isolation (bwrap mode)

Network filtering uses slirp4netns to create an isolated network namespace, then configures iptables inside that namespace. No root/sudo required.

### Requirements

- `slirp4netns` - Install: `sudo apt install slirp4netns`
- `iptables` - Usually pre-installed
- **Unprivileged user namespaces** - Must be enabled in kernel

To check/enable user namespaces:
```bash
# Check current setting (1 = enabled)
cat /proc/sys/kernel/unprivileged_userns_clone

# Enable temporarily
sudo sysctl -w kernel.unprivileged_userns_clone=1

# Enable permanently
echo 'kernel.unprivileged_userns_clone=1' | sudo tee /etc/sysctl.d/userns.conf
sudo sysctl --system
```

### How It Works

1. Creates user+network namespace via `unshare --user --map-root-user --net`
2. Attaches slirp4netns to provide network connectivity
3. Configures iptables rules (we have CAP_NET_ADMIN inside the namespace)
4. Drops into bwrap sandbox (which drops all capabilities)

### slirp4netns Address Mapping

| Address | Maps to |
|---------|---------|
| 10.0.2.2 | Host loopback (127.0.0.1) |
| 10.0.2.3 | DNS resolver |
| 10.0.2.15 | Sandbox's own IP |

### Network Modes

| Mode | Behavior |
|------|----------|
| `disabled` | No network filtering (default) |
| `allowlist` | Block everything except specified destinations |
| `blocklist` | Allow everything except specified destinations |

### Port Syntax

Destinations can include optional ports:
- `github.com:443` - Single port
- `192.168.1.0/24:80,443` - Multiple ports
- `10.0.0.1` - All ports

## File Locations

```
~/.cache/claude-cage/
└── <branch>/                           # Sanitized branch name (e.g., "main", "feature--foo")
    ├── intermediary/<project-path>/    # Sanitized repo (git origin for work)
    │   └── .git/hooks/post-receive     # Triggers sync
    └── work/<project-path>/            # Claude's working directory

$XDG_RUNTIME_DIR/claude-cage/           # Runtime files (typically /run/user/$UID/)
└── pipes/<branch>/<project-path>       # Named pipe for communication

project/
├── claude-cage.config                  # Config file (required)
└── .git/hooks/
    ├── pre-commit                      # Prevents mixed commits (autoMerge)
    └── post-commit                     # Syncs to intermediary (autoMerge)
```

Branch names are sanitized for filesystem paths: `/` becomes `--`, other special chars become `-`.

Environment variables for customization:
- `CLAUDE_CAGE_CACHE` - Override cache directory (default: `~/.cache/claude-cage`)
- `CLAUDE_CAGE_RUNTIME` - Override runtime directory (default: `$XDG_RUNTIME_DIR/claude-cage`)
- `CLAUDE_CAGE_BRANCH` - Override branch name for path construction (auto-detected from source)

## Debugging

```bash
# Verbose mode shows all commands
./claude-cage --verbose --test

# Debug mode shows command output (not just commands)
./claude-cage --debug --test

# Check what would run without executing
./claude-cage --dry-run
```

## Testing

Run the test suite:
```bash
bash tests/run-all.sh
```

| Test File | Component | Tests |
|-----------|-----------|-------|
| test-helpers.sh | helpers.sh | 7 |
| test-config.sh | config.sh | 13 |
| test-banner.sh | banner.sh | 6 |
| test-git-clone.sh | git-clone.sh | 13 |
| test-git-hooks.sh | git-hooks.sh | 12 |
| test-git-sync.sh | git-sync.sh | 14 |
| test-network.sh | network.sh | 31 |
| test-bwrap.sh | bwrap.sh | 13 |
| test-docker.sh | docker.sh | 11 |

**Total: 120 tests**

Note: bwrap execution tests are skipped if user namespaces are unavailable.

## Next Steps

1. Add Claude Code launch (not just `--test` mode)
2. Add `--cleanup` flag for removing cache dirs and hooks
3. Test full workflow with actual Claude Code session
4. Handle git-am conflicts gracefully
5. Add shared mode (mount entire `~/.cache/claude-cage` for multiple projects)

## Gotchas / Technical Notes

### Git Pathspec Excludes

When using git pathspec to exclude files (e.g., in `git format-patch`), be aware:

- **`:!pattern` vs `:(exclude,glob)pattern`**: The short form `:!**/foo` does NOT match `foo` at the repository root. The `**` only matches one or more directories, not zero. Use `:(exclude,glob)**/foo` for proper glob behavior where `**` matches zero or more directories.

- **Don't use `.` before excludes**: `git format-patch -- . :!pattern` breaks exclude matching. Use `git format-patch -- :!pattern` instead.

- **`-1 HEAD` vs `HEAD~1..HEAD`**: When pathspec excludes all files from a commit, `git format-patch -1 HEAD -- :!pattern` outputs the parent commit instead of empty. Use `HEAD~1..HEAD` for correct behavior.

### Branch-Switching Sync

When syncing commits from intermediary to source, if the user has switched branches:
- We use a temp index (`.git/claude-cage-tmp-index`) to apply changes without checkout
- Commits are applied to the original branch the user started on
- User's current checkout remains untouched

## Voice/Style

All user-facing text uses Nic Cage's voice from Con Air. This applies to:

- **Commit messages** - The subject line only, not the body/details below
- **README.md** - Prose text only (not example code, config, or comments within code blocks)
- **Tool output in source code** - Echo statements, error messages, banners

Example commit: `Cleanin' house - this is the main show now`

Example output: `Hold on now. I need bubblewrap (bwrap) installed for sandboxing.`

This does NOT apply to:
- Code comments
- Other documentation files (just README.md)
- Config examples
- Technical error messages from git/system commands
