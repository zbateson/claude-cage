# CLAUDE-git.md

Documentation for `claude-cage-git` - a lightweight sandboxed git workflow for Claude Code.

## Overview

`claude-cage-git` is a simplified variant of `claude-cage` that uses git-based isolation instead of unison sync. It creates a sanitized copy of your project (excluding sensitive files) and uses git to sync changes back.

**Key differences from main claude-cage:**
- No unison dependency - uses git archive + fresh init
- No sudo required - runs as current user
- Simpler architecture - just bwrap/docker sandbox with git repos
- File exclusion happens at archive time (no history of excluded files)

## Architecture

```
Source Project                    .caged/intermediary              .caged/work
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
2. **Intermediary** (`.caged/intermediary/`) - Fresh git repo on `claude` branch, excluded files removed, no history of sensitive data
3. **Work** (`.caged/work/`) - Clone of intermediary on `claude` branch where Claude works

Both intermediary and work use a single `claude` branch. Intermediary has `receive.denyCurrentBranch=updateInstead` to allow pushing to the checked-out branch.

### Why Intermediary?

The intermediary repo serves as a buffer:
- Claude's git remote points here, not your source
- Post-receive hook triggers sync to source
- Prevents accidental direct access to source history
- Clean slate - no git history containing excluded files

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

`dist/claude-cage-git` is the concatenated script (all src files in order).

## Sync Mechanism

### Outbound (Claude -> Source)

When `autoMerge = true`:

1. Claude makes commits in `.caged/work/`
2. Claude runs `git push origin`
3. Intermediary's `post-receive` hook fires
4. Hook writes `<refname> <newrev>` to named pipe (`.caged/.pipe`)
5. Pipe listener on host reads the message
6. `sync_to_source()` runs:
   - Skips initial commit (just a copy)
   - Uses `git format-patch` on intermediary
   - Applies to source with `git am --3way`

### Inbound (Source -> Intermediary)

When you commit to source:

1. `post-commit` hook on source fires
2. Creates patch excluding sensitive files (`git format-patch -- . ':!pattern'`)
3. Applies patch to intermediary's `claude` branch with `git am`
4. Claude runs `git pull` when ready to get changes

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

## CLI Usage

```bash
# Basic usage - creates intermediary + work, shows sandbox info
./claude-cage-git

# Drop into sandbox shell for testing
./claude-cage-git --test

# Manual merge (fetch refs from intermediary)
./claude-cage-git git-merge

# Dry run (show commands without executing)
./claude-cage-git --dry-run

# Verbose output
./claude-cage-git --verbose
./claude-cage-git -v
```

## Current State

### Implemented

- [x] Config parsing (Lua-based, same as main claude-cage)
- [x] `create_intermediary_clone()` - git ls-files + tar with excludes
- [x] Fresh git init (no history of excluded files)
- [x] Work directory clone with `claude` branch
- [x] `run_in_bwrap()` - full bwrap sandbox
- [x] `run_in_docker()` - Docker container sandbox
- [x] Named pipe communication (`.caged/.pipe`)
- [x] `post-receive` hook on intermediary
- [x] `sync_to_source()` using format-patch/git-am
- [x] Pipe listener background process
- [x] `pre-commit` hook (prevents mixed commits)
- [x] `post-commit` hook (syncs source -> intermediary)
- [x] `manual_git_merge()` for manual sync
- [x] Cleanup on exit
- [x] `receive.denyCurrentBranch=updateInstead` for push to checked-out branch
- [x] Comprehensive test suite (82 tests across 8 files)

### Known Issues / TODO

- [ ] **No Claude Code launch yet** - only `--test` mode works (drops into shell)
- [ ] Build script missing - currently just concatenating files manually
- [ ] Header/shebang handling in dist needs verification
- [ ] Testing on actual Claude Code workflow
- [ ] Conflict resolution when git-am fails
- [ ] Instance tracking (multiple concurrent runs)
- [ ] Network restriction integration (iptables/pf)

## How It Differs from Main claude-cage

| Aspect | claude-cage | claude-cage-git |
|--------|-------------|-----------------|
| Sync method | unison (bidirectional) | git archive + patches |
| Excludes | Real-time, bidirectional | At archive time only |
| Dependencies | unison, bindfs, iptables | git, tar, bwrap/docker |
| Sudo required | Yes (user isolation) | No (current user) |
| Live sync | Yes (inotify/fsmonitor) | On git push only |
| History sanitization | No (excludes just hidden) | Yes (fresh init) |

## File Locations

```
project/
├── claude-cage.config      # Config file (required)
├── .caged/                 # Created by claude-cage-git
│   ├── intermediary/       # Sanitized repo (git origin for work)
│   │   └── .git/hooks/post-receive  # Triggers sync
│   ├── work/               # Claude's working directory
│   └── .pipe               # Named pipe for communication
└── .git/hooks/
    ├── pre-commit          # Prevents mixed commits (autoMerge)
    └── post-commit         # Syncs to intermediary (autoMerge)
```

## Debugging

```bash
# Verbose mode shows all commands
./claude-cage-git --verbose --test

# Debug mode shows command output (not just commands)
./claude-cage-git --debug --test

# Check what would run without executing
./claude-cage-git --dry-run
```

## Testing

Run the test suite:
```bash
bash tests-git/run-all.sh
```

| Test File | Component | Tests |
|-----------|-----------|-------|
| test-helpers.sh | helpers.sh | 7 |
| test-config.sh | config.sh | 13 |
| test-banner.sh | banner.sh | 6 |
| test-git-clone.sh | git-clone.sh | 13 |
| test-git-hooks.sh | git-hooks.sh | 12 |
| test-git-sync.sh | git-sync.sh | 9 |
| test-bwrap.sh | bwrap.sh | 11 |
| test-docker.sh | docker.sh | 11 |

**Total: 82 tests**

Note: bwrap execution tests are skipped if user namespaces are unavailable.

## Next Steps

1. Add Claude Code launch (not just `--test` mode)
2. Create build script for concatenating src/ -> dist/
3. Add `--cleanup` flag for removing .caged and hooks
4. Test full workflow with actual Claude Code session
5. Handle git-am conflicts gracefully
