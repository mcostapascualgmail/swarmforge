Feature: SwarmForge PowerShell configuration

  The `swarmforge.ps1` launcher reads a project-local `swarmforge/`
  directory and validates the swarm definition before starting any
  sessions or agents.

  Scenario: Startup fails when the swarmforge.conf file is missing
    Given a working directory without "swarmforge/swarmforge.conf"
    When "swarmforge.ps1" starts
    Then startup fails with an error mentioning "Config not found"

  Scenario: Startup fails when the constitution prompt is missing
    Given a working directory with "swarmforge/swarmforge.conf"
    And the file "swarmforge/constitution.prompt" does not exist
    When "swarmforge.ps1" starts
    Then startup fails with an error mentioning "Constitution prompt not found"

  Scenario: Each config line defines one swarm window
    Given "swarmforge/swarmforge.conf" contains:
      """
      window architect claude architect
      window coder codex coder
      window reviewer codex reviewer
      window logger none root
      """
    When "swarmforge.ps1" parses the config
    Then four windows are defined
    And the roles are "architect", "coder", "reviewer", and "logger"
    And the backends are "claude", "codex", "codex", and "none"

  Scenario: Every agent-backed role requires a matching prompt file
    Given "swarmforge/swarmforge.conf" contains:
      """
      window architect claude architect
      window reviewer codex reviewer
      """
    And "swarmforge/architect.prompt" exists
    And "swarmforge/reviewer.prompt" does not exist
    When "swarmforge.ps1" parses the config
    Then startup fails with an error mentioning "Missing role prompt"

  Scenario: Unsupported backends are rejected
    Given "swarmforge/swarmforge.conf" contains:
      """
      window architect gpt architect
      """
    And "swarmforge/architect.prompt" exists
    When "swarmforge.ps1" parses the config
    Then startup fails with an error mentioning "Unsupported agent"

  Scenario: Duplicate roles are rejected
    Given "swarmforge/swarmforge.conf" contains:
      """
      window architect claude architect
      window architect codex reviewer
      """
    And "swarmforge/architect.prompt" exists
    When "swarmforge.ps1" parses the config
    Then startup fails with an error mentioning "Duplicate role"

  Scenario: Duplicate dedicated worktrees are rejected
    Given "swarmforge/swarmforge.conf" contains:
      """
      window coder codex shared
      window reviewer codex shared
      """
    And "swarmforge/coder.prompt" exists
    And "swarmforge/reviewer.prompt" exists
    When "swarmforge.ps1" parses the config
    Then startup fails with an error mentioning "Duplicate worktree"

  Scenario: The deprecated master worktree alias warns and uses the root checkout
    Given "swarmforge/swarmforge.conf" contains:
      """
      window logger none master
      """
    When "swarmforge.ps1" parses the config
    Then startup warns that "master" is deprecated as a root-checkout alias
    And the "logger" role is assigned to the root checkout

  Scenario: Unsafe worktree names are rejected
    Given "swarmforge/swarmforge.conf" contains:
      """
      window coder codex ../reviewer
      """
    And "swarmforge/coder.prompt" exists
    When "swarmforge.ps1" parses the config
    Then startup fails with an error mentioning "Invalid worktree"
