Feature: SwarmForge PowerShell workspace setup

  The PowerShell launcher prepares a project-local workspace, initializes git
  when needed, writes helper state, creates worktrees, and starts one
  tmux session containing one visible pane per configured role.

  Scenario: Startup initializes a git repository when the working directory is not a repo
    Given a working directory without a ".git" directory
    When "swarmforge.ps1" starts
    Then a git repository is initialized
    And the default branch is renamed to "master"
    And the first commit message is "Initial swarmforge repository"

  Scenario: Startup ensures the SwarmForge paths are ignored by git
    Given a working directory without a ".gitignore" file
    When "swarmforge.ps1" initializes the repository
    Then ".gitignore" contains ".swarmforge/"
    And ".gitignore" contains ".worktrees/"
    And ".gitignore" contains "logs/"
    And ".gitignore" contains "agent_context/"

  Scenario: Startup adds SwarmForge ignore entries for existing repositories
    Given a working directory with an existing git repository
    And the repository already has a commit
    When "swarmforge.ps1" initializes the repository
    Then ".gitignore" contains ".swarmforge/"
    And ".gitignore" contains ".worktrees/"
    And ".gitignore" contains "logs/"
    And ".gitignore" contains "agent_context/"

  Scenario: Startup prepares the local workspace directories
    Given a valid swarm configuration
    When "swarmforge.ps1" prepares the workspace
    Then the directory "features" exists under the project root
    And the directory "logs" exists under the project root
    And the directory "agent_context" exists under the project root
    And the directory ".swarmforge" exists under the project root
    And the directory ".swarmforge/prompts" exists under the project root
    And the directory ".worktrees" exists under the project root
    And the directory ".worktrees/swarmtools" exists under the project root

  Scenario: Startup writes sessions metadata and a notify helper
    Given a valid swarm configuration
    When "swarmforge.ps1" prepares the workspace
    Then the file ".swarmforge/sessions.tsv" exists
    And the file ".worktrees/swarmtools/notify-agent.ps1" exists

  Scenario: Startup creates one git worktree per dedicated role
    Given "swarmforge/swarmforge.conf" contains:
      """
      window architect claude architect
      window coder codex coder
      window reviewer codex reviewer
      window logger none root
      """
    And the matching prompt files exist
    When "swarmforge.ps1" prepares worktrees
    Then the worktree ".worktrees/architect" is created from "HEAD"
    And the worktree ".worktrees/coder" is created from "HEAD"
    And the worktree ".worktrees/reviewer" is created from "HEAD"
    And no worktree is created for "root"

  Scenario: Existing worktrees are reused
    Given a valid swarm configuration with a "coder" worktree
    And ".worktrees/coder/.git" already exists
    When "swarmforge.ps1" prepares worktrees
    Then the existing "coder" worktree is left in place

  Scenario: Existing role branches are reused without resetting them
    Given a valid swarm configuration with a "coder" worktree
    And the branch "swarmforge-coder" already exists
    And ".worktrees/coder/.git" does not exist
    When "swarmforge.ps1" prepares worktrees
    Then the worktree ".worktrees/coder" is created from "swarmforge-coder"
    And the branch "swarmforge-coder" is not reset to "HEAD"

  Scenario: Existing swarm sessions are killed before startup continues
    Given a valid swarm configuration
    And tmux already has a session for the swarm
    When "swarmforge.ps1" starts the tmux session
    Then the existing session is killed before a replacement session is created

  Scenario: Startup creates one tmux session with one pane per configured role
    Given a valid swarm configuration
    When "swarmforge.ps1" launches the swarm
    Then one tmux session named "swarmforge-<working-directory-name>" is created
    And the session has one shared window with panes for "architect", "coder", "reviewer", and "logger"
    And startup reports the resolved location and current branch for each role

  Scenario: Startup attaches the current shell to the shared swarm session
    Given a valid swarm configuration
    When "swarmforge.ps1" finishes launching the swarm
    Then the current shell attaches to one running tmux session
