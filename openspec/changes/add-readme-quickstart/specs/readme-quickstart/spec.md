## ADDED Requirements

### Requirement: Quickstart section exists in README
README.md SHALL contain a section titled "Quickstart" positioned immediately after the opening description line and before the Installation section.

#### Scenario: Section is discoverable
- **WHEN** a user opens README.md and reads top to bottom
- **THEN** they encounter the Quickstart section before any other section heading

#### Scenario: Section is self-contained
- **WHEN** a user follows only the Quickstart steps
- **THEN** they reach an interactive Claude Code session without consulting any other section

### Requirement: Quickstart covers prerequisites
The Quickstart section SHALL state the required host dependencies (Docker Engine 24+, Docker Compose v2, curl, jq, uuidgen) and supported platforms (Linux, WSL2) before the first command.

#### Scenario: Prerequisites listed
- **WHEN** a user reads the Quickstart
- **THEN** they see the prerequisite list before any shell command is shown

### Requirement: Quickstart commands are copy-paste ready
Every shell command in the Quickstart SHALL be runnable without substitution — no `<placeholder>` tokens — except for the profile name and workspace path, which SHALL use obvious literal examples (e.g. `myapp`, `~/projects/myapp`).

#### Scenario: No required placeholder substitution
- **WHEN** a user copies the install and start commands verbatim
- **THEN** the commands execute without modification

### Requirement: Quickstart covers the end-to-end flow in five steps or fewer
The Quickstart SHALL guide the user through: (1) clone and install, (2) OAuth token setup, (3) profile creation, (4) starting a session. An optional fifth step for adding a secret SHALL be included but clearly marked optional.

#### Scenario: Mandatory steps lead to a session
- **WHEN** a user completes steps 1 through 4
- **THEN** an interactive Claude Code session is running inside the Docker sandbox

#### Scenario: Optional secret step is skippable
- **WHEN** a user skips the optional secret step
- **THEN** the session still starts successfully

### Requirement: Quickstart links to reference sections
The Quickstart SHALL include a note after the auth step pointing to the Installation section for API key setup, and a "Next steps" or equivalent pointer to the Profiles and CLI sections for deeper reference.

#### Scenario: API key alternative is surfaced
- **WHEN** a user reads the Quickstart
- **THEN** they see a reference to the Installation section for API key authentication

#### Scenario: Reference sections are linked
- **WHEN** a user finishes the Quickstart
- **THEN** they are pointed to where to find full profile and CLI documentation
