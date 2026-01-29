# Using an Existing Docker Container

This guide explains how to run Claude Code inside an existing Docker container that you manage yourself. This is useful when:

- You have a dev container with all your project's dependencies already installed
- You want Claude to work in the same environment your app builds/runs in
- You need specific tooling or configurations that are easier to set up in your own Dockerfile

## Limitations

When using an existing container, claude-cage has limited control:

| Feature | Managed Container | Existing Container |
|---------|-------------------|-------------------|
| Volume mounts | Automatic | You must configure |
| homeConfigSync | Automatic | Not available |
| Network restrictions | Automatic | Not available |
| File sync (sync mode) | Automatic | Not available |
| Container lifecycle | Managed by claude-cage | Managed by you |

**Key limitation:** Volume mounts can only be set when a container is created (`docker run -v`). claude-cage cannot add mounts to an existing running container.

## Setup

### 1. Create Your Container with the Right Mount

When creating your container, mount your project directory:

```bash
# Simple example
docker run -d --name my-dev-container \
    -v /home/user/projects:/workspace \
    node:lts-slim \
    tail -f /dev/null

# With more options
docker run -d --name my-dev-container \
    -v /home/user/projects:/workspace \
    -v /home/user/.gitconfig:/home/node/.gitconfig:ro \
    -v /home/user/.claude:/home/node/.claude \
    --user "$(id -u):$(id -g)" \
    node:lts-slim \
    tail -f /dev/null
```

Or use docker-compose:

```yaml
# docker-compose.yml
version: '3.8'
services:
  dev:
    image: node:lts-slim
    container_name: my-dev-container
    volumes:
      - /home/user/projects:/workspace
      - /home/user/.gitconfig:/home/node/.gitconfig:ro
      - /home/user/.claude:/home/node/.claude
    user: "${UID}:${GID}"
    command: tail -f /dev/null
    # Keep running so claude-cage can exec into it
```

```bash
docker-compose up -d
```

### 2. Install Claude Code in the Container

Claude Code needs to be installed inside the container:

```bash
docker exec -it my-dev-container bash -c "curl -fsSL https://claude.ai/install.sh | sh"
```

### 3. Configure claude-cage

```lua
claude_cage {
    isolationMode = "docker",

    docker = {
        -- Use your existing container
        container = "my-dev-container",

        -- User to run as inside the container
        user = "node",  -- or "root", or "1000", etc.

        -- Working directory where your project is mounted
        workdir = "/workspace/my-project",
    }
}
```

### 4. Run claude-cage

```bash
# No sudo needed for Docker mode
claude-cage
```

## Configuration Options

| Option | Description |
|--------|-------------|
| `docker.container` | Name or ID of your existing container |
| `docker.user` | User to run commands as inside the container |
| `docker.workdir` | Working directory inside the container |

When `docker.container` is set, these options are ignored:
- `docker.image`
- `docker.packages`
- `docker.isolated`
- `docker.namePrefix`
- `docker.extraArgs`

## Tips

### Claude Code Authentication

Mount your `~/.claude` directory into the container to preserve authentication:

```bash
-v /home/user/.claude:/home/node/.claude
```

### Git Configuration

Mount your `.gitconfig` for git to work properly:

```bash
-v /home/user/.gitconfig:/home/node/.gitconfig:ro
```

### File Ownership

Run the container with your UID/GID so files created have the right ownership:

```bash
docker run --user "$(id -u):$(id -g)" ...
```

Or in docker-compose:
```yaml
user: "${UID}:${GID}"
```

### Keep Container Running

The container must be running for claude-cage to exec into it. Use a command that keeps it alive:

```bash
command: tail -f /dev/null
# or
command: sleep infinity
```

### Multiple Projects

If you have multiple projects, mount the parent directory and use `workdir` to specify which project:

```lua
-- For project A
docker = {
    container = "my-dev-container",
    workdir = "/workspace/project-a",
}

-- For project B
docker = {
    container = "my-dev-container",
    workdir = "/workspace/project-b",
}
```

## Example: Using Your App's Dev Container

If you already have a Dockerfile for your application:

```dockerfile
# Dockerfile.dev
FROM node:lts-slim

# Install your app's dependencies and tools
RUN apt-get update && apt-get install -y git curl

# Install Claude Code
RUN curl -fsSL https://claude.ai/install.sh | sh

WORKDIR /app
```

```yaml
# docker-compose.yml
version: '3.8'
services:
  dev:
    build:
      context: .
      dockerfile: Dockerfile.dev
    container_name: my-app-dev
    volumes:
      - .:/app
      - /home/user/.claude:/root/.claude
    command: tail -f /dev/null
```

```lua
-- claude-cage.config
claude_cage {
    isolationMode = "docker",
    docker = {
        container = "my-app-dev",
        user = "root",
        workdir = "/app",
    }
}
```

## Troubleshooting

### "Container don't exist"

Make sure your container is created and the name matches:

```bash
docker ps -a  # List all containers
```

### "Container exists but ain't runnin'"

Start your container:

```bash
docker start my-dev-container
```

### Claude Code not found

Install Claude Code inside the container:

```bash
docker exec -it my-dev-container bash -c "curl -fsSL https://claude.ai/install.sh | sh"
```

### Permission denied on files

Check that you're running with the right user and the files are accessible:

```bash
docker exec -it my-dev-container ls -la /workspace
```

Consider running the container with `--user "$(id -u):$(id -g)"`.
