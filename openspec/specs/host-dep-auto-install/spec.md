## ADDED Requirements

### Requirement: Detect installable missing packages
When missing dependencies are found, the system SHALL classify them as auto-installable (`curl`, `jq`, `uuidgen`, `python3`) or manual-only (`docker`, `docker compose`). Classification SHALL occur only when a supported package manager is present on the host.

#### Scenario: All missing deps are installable
- **WHEN** `curl` and `jq` are missing and `apt-get` is available
- **THEN** both are classified as auto-installable and no manual-only list is shown

#### Scenario: Docker is missing
- **WHEN** `docker` is not installed
- **THEN** it is classified as manual-only regardless of package manager availability

### Requirement: Prompt before installing
The system SHALL display the list of auto-installable packages and prompt the user for confirmation (`[y/N]`) before running any install command. Default is no.

#### Scenario: User confirms install
- **WHEN** user enters `y` or `Y` at the prompt
- **THEN** the system SHALL install all listed packages and continue

#### Scenario: User declines install
- **WHEN** user presses Enter or enters anything other than `y`/`Y`
- **THEN** the system SHALL exit with an error listing all missing packages (original behavior)

### Requirement: Supported package managers
The system SHALL support `apt-get` (Debian/Ubuntu/WSL2), `dnf` (Fedora/RHEL), and `pacman` (Arch). If none are found, the system SHALL fall through to the original error behavior.

#### Scenario: apt-get available
- **WHEN** `apt-get` is on PATH
- **THEN** system uses `apt-get update -qq && apt-get install -y <pkgs>`

#### Scenario: No supported package manager
- **WHEN** neither `apt-get`, `dnf`, nor `pacman` is on PATH
- **THEN** auto-install offer is skipped; system lists missing deps and exits

### Requirement: Post-install re-verification
After installing, the system SHALL re-verify each package with `command -v`. If any package is still missing, the system SHALL exit with an error.

#### Scenario: Install succeeds
- **WHEN** all packages install successfully
- **THEN** system continues with the rest of installation

#### Scenario: Install fails for one package
- **WHEN** a package is still not found after install
- **THEN** system exits with a clear error naming the missing package

### Requirement: Python version check after install
After installing `python3`, the system SHALL verify the installed version is ≥ 3.11. If it is not, the system SHALL exit with an error message that includes instructions for installing a newer version (e.g., via deadsnakes PPA on Ubuntu).

#### Scenario: python3 installed but version too old
- **WHEN** `apt-get install python3` installs Python 3.10
- **THEN** system exits with error: "Python 3.11+ required. Found 3.10. On Ubuntu: sudo add-apt-repository ppa:deadsnakes/ppa && sudo apt-get install python3.11"

#### Scenario: python3 installed and version sufficient
- **WHEN** `apt-get install python3` installs Python 3.11 or newer
- **THEN** system continues without error
