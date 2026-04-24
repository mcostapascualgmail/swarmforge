# SwarmForge

**A disciplined tmux-based agent orchestration platform that turns swarms of AI agents into reliable, professional software engineers.**

## Intent

SwarmForge is an agent coordination system that facilitates communication between agents working in different git worktrees.

It provides a shared structure for role-specific prompts, worktree assignment, tmux sessions, and message passing so multiple agents can collaborate on the same project without stepping on each other.

## What SwarmForge Does

SwarmForge is a lightweight, tmux-based orchestration layer that:

- Launches a **config-driven swarm** from a project-local `swarmforge/swarmforge.conf`
- Creates one tmux session for the swarm with one split pane per configured role
- Reads behavior from project-local `swarmforge/<role>.prompt` files plus a layered `swarmforge/constitution.prompt`
- Supports per-role backends such as `claude`, `codex`, or `none`
- Creates a project-local `.worktrees/swarmtools/` directory with notification helpers for the active swarm
- Creates one git worktree per role with a dedicated worktree name under `.worktrees/`
- Initializes a git repository in a new working directory and creates a first commit with `logs/` and `agent_context/` ignored
- Keeps all swarm state local to the working directory in `.swarmforge/`

## Core Features

- **Config-Driven Topology** — The swarm shape comes from `swarmforge/swarmforge.conf`, not hardcoded shell variables.
- **Project-Local Roles** — Each role is defined by `swarmforge/<role>.prompt` in the working tree being orchestrated.
- **Layered Constitution** — `swarmforge/constitution.prompt` can delegate to subordinate files such as `swarmforge/constitution/project.prompt`, `engineering.prompt`, and `workflow.prompt`.
- **Backend Selection Per Role** — A role can launch `claude`, `codex`, or no agent at all.
- **Observable Swarm** — Attach once and watch every role side by side in a single tmux layout.
- **Self-Hosted & Lightweight** — Runs locally in tmux and Terminal with minimal machinery.

## Constitution And Roles

In a configuration with an `architect`, `coder`, and `reviewer`, the recommended prompt layout is:

```text
swarmforge/
  swarmforge.conf
  constitution.prompt
  constitution/
    project.prompt
    engineering.prompt
    workflow.prompt
  architect.prompt
  coder.prompt
  reviewer.prompt
```

`constitution.prompt` is the entry point. It can define precedence and direct agents to read subordinate constitution files in order. That lets you separate project-specific rules from engineering rules and workflow rules without forcing everything into one large prompt.

The default three-agent workflow is:

- `architect` defines behavior, plans, and acceptance-level intent
- `coder` implements one small slice at a time and hands off completed work
- `reviewer` performs deeper verification and quality checks before final handoff

`logger` remains an optional utility role with no agent backend.

## How It Works (High Level)

1. Create a `swarmforge/` directory in the target working directory.
2. Put `swarmforge.conf`, `constitution.prompt`, and one `<role>.prompt` file per configured role inside it. If needed, add subordinate files under `swarmforge/constitution/`.
3. In `swarmforge/swarmforge.conf`, define each window as `window <role> <agent> <worktree>`.
4. Add `swarmforge.ps1` to your shell `PATH` before startup.
5. Run `swarmforge.ps1 <working-directory>` or run it from inside that directory.
6. Startup always ensures `.gitignore` contains `.swarmforge/`, `.worktrees/`, `logs/`, and `agent_context/`.
7. If the working directory is not already a git repo, startup runs `git init`, renames the initial branch to `master`, and makes the first commit from the current project state.
8. Startup creates a git worktree for each window under `.worktrees/<worktree>`, unless the worktree field is `root` or a legacy root alias. Existing `swarmforge-<worktree>` branches are reused instead of reset.
9. Startup creates `.worktrees/swarmtools/notify-agent.ps1` for that project.
10. SwarmForge creates one tmux session, splits one tmux window into one pane per configured role, and launches each configured backend in its assigned worktree.
11. Roles communicate through helper commands such as `.worktrees/swarmtools/notify-agent.ps1`.

By default, closing or detaching the attached tmux client tears down the swarm and stops launcher PowerShell process trees for that project. SwarmForge also starts a small hidden watcher so an abrupt terminal close still cleans up the tmux session instead of leaving PowerShell pane processes behind. Start with `-KeepSessionOnDetach` when you intentionally want the tmux session to keep running for manual reattach.

## The `swarmforge.conf` File

`swarmforge/swarmforge.conf` defines the swarm window-by-window. Each line has this form:

```conf
window <role> <agent> <worktree>
```

You can define as many windows as your project needs. Each `role` maps to a corresponding prompt file at `swarmforge/<role>.prompt`, so a config containing `architect`, `coder`, `reviewer`, `research`, and `release` windows would expect:

- `swarmforge/architect.prompt`
- `swarmforge/coder.prompt`
- `swarmforge/reviewer.prompt`
- `swarmforge/research.prompt`
- `swarmforge/release.prompt`

This lets each project choose its own swarm shape instead of being locked to a fixed set of roles. The only special case is a utility role such as `logger` using the `none` backend, which opens a tmux pane without launching an agent.

Example config:

```conf
window architect claude architect
window coder codex coder
window reviewer codex reviewer
window logger none root
```

`logger` is a utility role. When configured with the `none` backend, it tails `logs/agent_messages.log`.

In the example above, the agents run in these worktrees:

- `architect` -> `.worktrees/architect`
- `coder` -> `.worktrees/coder`
- `reviewer` -> `.worktrees/reviewer`
- `logger` -> main working directory

Use `root` for roles that should run in the root checkout. Legacy configs may also use `none` or `master` as root-checkout aliases, but `master` is deprecated because it does not guarantee the branch is named `master`.

When tmux is available only through WSL, SwarmForge resolves `pwsh`, agent backends, and launch paths inside WSL so dependency checks and role startup use the same environment.

Codex roles are launched with `-m gpt-5.4`.

At runtime, SwarmForge creates one shared tmux session named after the working directory and lays out one visible tmux pane per configured role in a single shared window. If started with `-KeepSessionOnDetach`, reattach with `tmux attach-session -t <session-name>` or `wsl tmux attach-session -t <session-name>` when tmux is running inside WSL.

## Examples

The repository includes example swarm definitions under `examples/`.

- `examples/clojureHTW/swarmforge/` shows a layered constitution and agent prompts for a Clojure Hunt The Wumpus project, including a queueing rule for messages that arrive while an agent is busy.

Use these example directories as starting points for project-local `swarmforge/` folders.

## Getting Started

- Clone this repository and make `swarmforge.ps1` executable.
- Add the directory containing `swarmforge.ps1` to your shell `PATH`.
- Create or choose the project directory you want SwarmForge to manage.
- Inside that project, create a `swarmforge/` directory.
- Create `swarmforge/swarmforge.conf` and define the windows for your swarm.
- Use the earlier `Constitution And Roles`, `How It Works`, and `The swarmforge.conf File` sections as the reference for the expected prompt layout, role files, and window definitions.
- Type `swarmforge`.
