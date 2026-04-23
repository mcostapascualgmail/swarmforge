Feature: SwarmForge PowerShell agent launch

  The PowerShell launcher generates startup instructions for each role,
  launches agent backends in their assigned worktrees, and provides a
  helper script for agent-to-agent messaging.

  Scenario: Startup writes one generated instruction file per agent-backed role
    Given "swarmforge/swarmforge.conf" contains:
      """
      window architect claude master
      window coder codex coder
      window reviewer codex reviewer
      window logger none none
      """
    And the matching prompt files exist
    When "swarmforge.ps1" launches the roles
    Then the file ".swarmforge/prompts/architect.md" exists
    And the file ".swarmforge/prompts/coder.md" exists
    And the file ".swarmforge/prompts/reviewer.md" exists
    And no generated prompt file is required for "logger"

  Scenario: Generated instructions tell agents to read constitution and role prompts recursively
    Given "swarmforge/swarmforge.conf" contains:
      """
      window architect claude master
      """
    And "swarmforge/architect.prompt" exists
    When "swarmforge.ps1" writes the generated instruction file for "architect"
    Then ".swarmforge/prompts/architect.md" contains "Read swarmforge/constitution.prompt"
    And ".swarmforge/prompts/architect.md" contains "read every file it refers to recursively"
    And ".swarmforge/prompts/architect.md" contains "Read swarmforge/architect.prompt"

  Scenario: Claude roles launch in their assigned worktrees with the generated prompt
    Given "swarmforge/swarmforge.conf" contains:
      """
      window architect claude master
      """
    And "swarmforge/architect.prompt" exists
    When "swarmforge.ps1" launches the "architect" role
    Then tmux sends a command containing "Set-Location" to the architect pane
    And the command contains "claude"
    And the command contains "--model us.anthropic.claude-opus-4-6-v1"
    And the command contains "--append-system-prompt-file"
    And the command contains "--permission-mode acceptEdits"
    And the command contains "$promptText"

  Scenario: Codex roles launch in their assigned worktrees with the generated prompt
    Given "swarmforge/swarmforge.conf" contains:
      """
      window coder codex coder
      """
    And "swarmforge/coder.prompt" exists
    When "swarmforge.ps1" launches the "coder" role
    Then tmux sends a command containing "codex -C" to the coder pane
    And the command contains "$promptText"

  Scenario: The logger role tails the shared agent log without an agent backend
    Given "swarmforge/swarmforge.conf" contains:
      """
      window logger none none
      """
    When "swarmforge.ps1" launches the "logger" role
    Then tmux sends a command containing "New-Item -ItemType File -Force" to the logger pane
    And the command contains "Get-Content -LiteralPath"
    And the command contains "-Wait"

  Scenario: The notify helper routes messages by role or index
    Given ".swarmforge/sessions.tsv" contains target rows for "architect" and "coder"
    When ".worktrees/swarmtools/notify-agent.ps1" sends a message to "architect"
    Then the message is sent to the architect tmux pane
    When ".worktrees/swarmtools/notify-agent.ps1" sends a message to "2"
    Then the message is sent to the coder tmux pane

  Scenario: The notify helper logs the message before sending it to tmux
    Given ".swarmforge/sessions.tsv" contains a target row for "architect"
    When ".worktrees/swarmtools/notify-agent.ps1" sends the message "hello architect"
    Then "logs/agent_messages.log" receives a timestamped entry for that tmux target
    And tmux sends the literal message text to pane "0.0"

  Scenario: The cleanup owner appends shutdown cleanup to its launch command
    Given a valid swarm configuration with an active "architect" role
    When "swarmforge.ps1" chooses the cleanup owner
    Then the "architect" role becomes the cleanup owner when it has an agent backend
    And its launch command includes "swarm-cleanup.ps1"
