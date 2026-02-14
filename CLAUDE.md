# CLAUDE.md

Lightweight sandboxed git workflow for Claude Code. Creates an isolated copy of your project (excluding sensitive files) via git fast-export/fast-import, syncs changes back via format-patch/git-am. No sudo required. Supports bwrap (Linux/WSL2) and Docker (all platforms) sandbox modes. Network filtering via iptables (optional).

## Architecture

```
Source Project                    ~/.cache/.../intermediary        ~/.cache/.../work
(your actual repo)                (bare repo, shared)              (Claude's workspace)
       │                                   │                              │
       │  fast-export + pathspec excludes   │     git clone                │
       │  (excludes stripped, N commits)   │                              │
       └──────────────────────────────────>│──────────────────────────────>
                                           │                              │
                                           │<────── git push ─────────────┤
                                           │     (Claude commits)         │
                                           │                              │
       │<──── format-patch/git-am ─────────┤                              │
       │     (via named pipe)              │                              │
```

### Three-Repository Model

1. **Source** — Your actual project with full git history
2. **Intermediary** (`~/.cache/claude-cage/intermediary/<project-path>/`) — Persistent bare repo with real commit history (configurable depth). Excluded file content is filtered via `:(exclude,glob)` pathspec during fast-export. Acts as a buffer: Claude's git remote points here, not your source. Post-receive hook triggers sync to source via named pipe. Persistent across sessions, only rebuilt when exclude patterns change.
3. **Work** (`~/.cache/claude-cage/sessions/<timestamp>/work/<project-path>/`) — Clone of intermediary where Claude works. Per-session (timestamp-identified), allowing concurrent sessions.

The intermediary is created by `create_intermediary_clone()` using `git fast-export` with `:(exclude,glob)` pathspec piped into `git fast-import`. Key properties:
- **1:1 commit mapping**: Every source commit maps to exactly one intermediary commit (or `0` for excluded-only commits)
- **Incremental updates**: Existing intermediaries updated via `--import-marks`/`--export-marks`
- **Exclude hash tracking**: Intermediary rebuilt automatically if exclude patterns change

Inside the sandbox, work directories are mounted at their original paths, intermediaries at `/run<intermediary-path>`.

## Source Files

| File | Purpose |
|------|---------|
| `src/header.sh` | Shebang and script header |
| `src/helpers.sh` | `run`, `run_quiet`, color codes, dry-run support |
| `src/banner.sh` | ASCII art banner (print_banner) |
| `src/config-builder.sh` | Interactive config generator when no config exists |
| `src/config.sh` | Lua-based config parsing (system, user, includeIf, local) |
| `src/git-clone.sh` | `create_intermediary_clone()`, `build_exclude_pathspecs()` — bare repo via fast-export/fast-import with pathspec excludes |
| `src/git-hooks.sh` | Git hooks for communication pipe and commit sync |
| `src/git-patches.sh` | Failed patch recovery: save, list, interactive apply |
| `src/git-sync.sh` | `sync_to_source()`, `copy_carry_files()`, pipe listener, manual merge |
| `src/network.sh` | Network isolation via slirp4netns/iptables |
| `src/mounts.sh` | Shared mount logic for bwrap and docker |
| `src/bwrap.sh` | `run_in_bwrap()` — bubblewrap sandbox |
| `src/docker.sh` | `run_in_docker()` — Docker container sandbox |
| `src/main.sh` | Entry point — wires everything together |

## Build

```bash
make        # Concatenates src/*.sh → dist/claude-cage (dependency order)
make clean  # Remove built file
```

## Sync Mechanism

### Outbound (Claude → Source)

When `autoSync = true` (default): Claude commits + pushes → intermediary's `post-receive` hook writes to named pipe → pipe listener calls `sync_to_source()` → walks `oldrev..newrev`, skips commits already in mapping (loop prevention), applies each via `git format-patch` + `git am --3way` (same branch) or temp-index + `git update-ref` (user switched branches). New branches created on source from mapped parent. If user is on the target branch and `syncActiveBranch` is not `true`: skip (suggest `claude-cage git-merge`). With `syncActiveBranch`: stash/apply/pop cycle around the sync.

### Inbound (Source → Intermediary)

Source `post-commit` / `post-merge` hooks fire → check commit mapping (skip if already mapped) → call `claude-cage-sync-commit` helper → `git fast-export -1 <hash>` with pathspec excludes to temp file → detect excluded-only commits (no `commit` or no `from` line) → if valid, `git fast-import` on intermediary → update marks + commit mapping. Claude runs `git pull` when ready.

### Sessions

Multiple concurrent sessions share the same intermediary. Each gets its own work directory. PID-based session tracking in `$XDG_RUNTIME_DIR/claude-cage/sessions/<session-id>/<pid>` (file content = source_dir). When `isolated = false` (default), sessions are shared across projects: an active session for project A can be joined by project B, and inactive clean sessions are reusable by any project. When `isolated = true`, sessions are project-scoped (marked with `.claude-cage-isolated`). `--attach-session` shares an active session's work dir.

### Failed Patches

When `git am` fails, patches are saved to `<source>/claude-cage-failed-patches/from-intermediary/<branch>/`. At next startup, an interactive prompt offers to apply, delete, or skip them.

## Configuration

Config files loaded and merged in order (later values override, arrays merge): system (`/etc/claude-cage.conf`) → user (`~/.config/claude-cage/config`) → includeIf (directory-scoped, declared in system/user config) → local (`.claude-cage` at git root). No config triggers an interactive builder.

Example `.claude-cage`:

```lua
claude_cage {
    exclude = { ".env", "secrets/**", "application-*.properties" },
    carry = { "CLAUDE.md", ".cursorrules" },  -- gitignored files copied at startup/exit
    mode = "bwrap",  -- or "docker"
    autoSync = true,
    -- syncActiveBranch = false,  -- EXPERIMENTAL: also sync active branch (stash/apply/pop)
    showBanner = true,

    networkMode = "allowlist",  -- "disabled", "allowlist", or "blocklist"
    allow = {
        domains = { "github.com:443", "api.anthropic.com:443" },
        ips = { "8.8.8.8:53" },
        networks = { "10.0.0.0/8" }
    },
    block = {
        domains = { "internal.company.com" },
        ips = { "169.254.169.254" }
    },

    git = {
        historyDepth = 50,
        defaultBranch = "auto",
        blockForceAdd = true,
    },

    bwrap = {
        systemMounts = { "/etc", "/usr", "/bin", "/lib", "/lib64", "/sbin" },
        maskPaths = {
            "/etc/shadow", "/etc/gshadow", "/etc/sudoers", "/etc/sudoers.d",
            "/etc/ssl/private", "/etc/pki/tls/private", "/etc/pki/nssdb",
            "/etc/letsencrypt", "/etc/security",
            "/etc/openvpn", "/etc/wireguard", "/etc/ipsec.d", "/etc/ipsec.secrets",
            "/etc/NetworkManager/system-connections", "/etc/wpa_supplicant", "/etc/ppp",
            "/etc/docker", "/etc/samba", "/etc/krb5.keytab", "/etc/machine-id",
        },
    },

    additionalMounts = {
        "~/.gitconfig",
        { source = "~/.claude", mode = "rw" },
    },
}
```

### Key Options

| Option | Default | Description |
|--------|---------|-------------|
| `launch` | `"claude"` | Command to run inside sandbox |
| `exclude` | `{}` | Patterns to exclude from intermediary |
| `carry` | `{}` | Gitignored files copied source↔work at startup/exit |
| `mode` | `"bwrap"` | Sandbox mode: `"bwrap"` or `"docker"` |
| `autoSync` | `true` | Real-time sync of non-active branches via named pipe |
| `syncActiveBranch` | `false` | **EXPERIMENTAL** Also sync active branch (stash/apply/pop) |
| `allowNonGit` | unset | Allow non-git directories (triggers direct mount) |
| `directMount` | `false` | Mount source directly, skip git sync entirely |
| `isolated` | `false` | Only mount single project (not all same-session projects) |
| `showBanner` | `true` | Show ASCII banner |
| `hideConfirmationPrompt` | `false` | Skip confirmation prompt before entering sandbox |
| `createCagedDir` | `false` | Create `.caged/` symlinks to session caches |
| `additionalMounts` | `{}` | Extra mounts (`source`, `as`/`dest`, `mode: "ro"/"rw"`) |
| `networkMode` | `"disabled"` | `"disabled"`, `"allowlist"`, or `"blocklist"` |
| `allow` / `block` | `{}` | Network destinations (domains, ips, networks with optional ports) |
| `bwrap.systemMounts` | `{"/etc", "/usr", "/bin", "/lib", "/lib64", "/sbin"}` | Host dirs mounted read-only in bwrap mode |
| `bwrap.maskPaths` | *(see below)* | Sensitive host paths masked (dirs→tmpfs, files→/dev/null) |
| `docker.image` | `"node:lts-slim"` | Docker image (docker mode only) |
| `docker.packages` | `{"curl", "iputils-ping"}` | Packages to install in Docker container |
| `git.historyDepth` | `50` | First-parent depth on default branch |
| `git.defaultBranch` | `"auto"` | Branch for history anchoring |
| `git.blockForceAdd` | `true` | Block commits with force-added gitignored files |

Array options (`exclude`, `carry`, `allow`, `block`, `additionalMounts`, `docker.packages`, `bwrap.systemMounts`, `bwrap.maskPaths`) merge across config levels. Scalar options are overridden by later configs.

## CLI Usage

```bash
./claude-cage                                      # Basic usage
./claude-cage --resume                             # Pass args to launch command
./claude-cage --test                               # Shell inside sandbox
./claude-cage --direct-mount                       # Skip git sync
./claude-cage git-merge [<branch>|--all]            # Sync intermediary commits to source
./claude-cage --attach-session [<timestamp>]       # Share active session
./claude-cage clean [<id>|--all]                   # Clean cached sessions
./claude-cage completion bash|zsh                  # Output completion script
./claude-cage install-completions                  # Auto-install completions
./claude-cage --dry-run                            # Show commands without executing
./claude-cage --verbose|-v                         # Verbose output
./claude-cage --debug                              # Verbose + show command output
```

## File Locations

```
~/.cache/claude-cage/
├── intermediary/<project-path>/          # Shared bare repo (unscoped)
├── scoped/<git-root>/<scope-path>/.bare/ # Scoped bare repo
│   ├── hooks/{post-receive,pre-receive}
│   ├── claude-cage-commit-map            # <intermediary-hash> <source-hash>
│   ├── claude-cage-{source,import}-marks # Fast-export/import marks
│   ├── claude-cage-source-branches       # Source branch names (pre-receive guard)
│   ├── claude-cage-exclude-hash          # Rebuild detection
│   └── sync.log
├── logs/<session-id>.log                 # Per-session operational log
└── sessions/<timestamp>/work/<project>/  # Claude's working directory

$XDG_RUNTIME_DIR/claude-cage/
├── pipes/<timestamp>/<project-path>      # Named pipe
└── sessions/<session-id>/<pid>            # Session tracking (content = source_dir)

project/.git/hooks/
├── post-commit.d/claude-cage-<hash>      # Source→intermediary sync
└── post-merge.d/claude-cage-<hash>       # Merge sync
```

### Environment Variables

**User-configurable:** `CLAUDE_CAGE_CACHE` (cache dir), `CLAUDE_CAGE_RUNTIME` (runtime dir), `CLAUDE_CAGE_SESSION` (session ID), `CLAUDE_CAGE_MOUNTED_PIPE` (pipe path in hooks), `CLAUDE_CAGE_ALLOW_IGNORED` (override blockForceAdd).

**Internal:** `CLAUDE_CAGE_VERSION`, `CLAUDE_CAGE_SOURCING` (sourcing for function defs), `CLAUDE_CAGE_SYNCING` (suppress hook re-sync during git-am), `SLIRP_NETWORK` (inside slirp namespace), `BWRAP_REAL_{UID,GID,USER,HOME}` (real user info in network namespace).

## Testing

```bash
bash tests/run-all.sh
```

| Test File | Component | Tests |
|-----------|-----------|-------|
| test-helpers.sh | helpers.sh | 7 |
| test-config.sh | config.sh | 18 |
| test-banner.sh | banner.sh | 6 |
| test-git-clone.sh | git-clone.sh | 22 |
| test-git-filter-stream.sh | pathspec exclude filtering | 23 |
| test-git-hooks.sh | git-hooks.sh | 22 |
| test-git-patches.sh | git-patches.sh | 13 |
| test-git-sync.sh | git-sync.sh | 26 |
| test-network.sh | network.sh | 31 |
| test-bwrap.sh | bwrap.sh | 13 |
| test-docker.sh | docker.sh | 18 |
| test-clean.sh | clean commands | 14 |
| test-direct-mount.sh | direct mount mode | 8 |
| test-scoped.sh | scoped intermediary | 66 |
| test-session-log.sh | per-session logging | 15 |
| test-cross-session.sh | cross-project session sharing | 21 |

**~323 assertions across 16 files.** bwrap tests skipped if user namespaces unavailable.

## TODO

- More graceful conflict resolution when git-am fails (currently saves to failed-patches)

## Voice/Style

All user-facing text uses Nic Cage's voice from Con Air. This applies to:

- **Commit messages** — The subject line only, not the body/details below. Keep subjects under 50 characters.
- **README.md** — Prose text only (not example code, config, or comments within code blocks)
- **Tool output in source code** — Echo statements, error messages, banners

Example commit: `Cleanin' house - this is the main show now`

Example output: `Hold on now. I need bubblewrap (bwrap) installed for sandboxing.`

This does NOT apply to:
- Code comments
- Other documentation files (just README.md)
- Config examples
- Technical error messages from git/system commands
