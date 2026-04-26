## MODIFIED Requirements

### Requirement: Bootstrap script creates standard project folder structure
A script `scripts/new-project.sh <project-name>` SHALL create a folder tree under `projects/<project-name>/` by copying all files and subdirectories from `$CONFIG_DIR/docs-templates/` into the new project directory. The script SHALL exit with a non-zero status and print an error if `projects/<project-name>/` already exists. The set of scaffolded files is determined dynamically by the contents of `$CONFIG_DIR/docs-templates/` — no filenames are hardcoded in the script.

#### Scenario: New project scaffolded successfully
- **WHEN** `scripts/new-project.sh my-project` is run and `projects/my-project/` does not exist
- **THEN** the directory `projects/my-project/` is created containing all files and subdirectories from `$CONFIG_DIR/docs-templates/`, each with its template content

#### Scenario: Project already exists is rejected
- **WHEN** `scripts/new-project.sh my-project` is run and `projects/my-project/` already exists
- **THEN** the script exits with status 1 and prints `Error: projects/my-project already exists`

#### Scenario: Missing argument is rejected
- **WHEN** `scripts/new-project.sh` is run with no arguments
- **THEN** the script exits with status 1 and prints `Usage: new-project.sh <project-name>`

#### Scenario: Missing docs-templates dir produces clear error
- **WHEN** `scripts/new-project.sh my-project` is run and `$CONFIG_DIR/docs-templates/` does not exist
- **THEN** the script exits with status 1 and prints an error directing the user to re-run `install.sh`

## REMOVED Requirements

### Requirement: GOALS.md seeded from template
**Reason**: GOALS.md template was removed from the template set; the goals concept is covered by VISION.md and TASKS.md in practice.
**Migration**: No migration needed — existing `GOALS.md` files in projects are unaffected.
