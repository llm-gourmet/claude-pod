A CI workflow failed on {{REPO_NAME}}.

**Workflow:** {{WORKFLOW_NAME}}
**Run ID:** {{WORKFLOW_RUN_ID}}
**Branch:** {{BRANCH}}
**Commit:** {{COMMIT_SHA}}
**Conclusion:** {{WORKFLOW_CONCLUSION}}
**Run URL:** {{WORKFLOW_RUN_URL}}

---

Please diagnose the failure:
1. Fetch the run logs with `gh run view {{WORKFLOW_RUN_ID}} --repo {{REPO_NAME}} --log-failed`.
2. Identify the specific step and command that failed.
3. Check out the failing commit: `git fetch && git checkout {{COMMIT_SHA}}`.
4. Reproduce the failure locally if possible.
5. Propose a fix in a comment on the commit: `gh api repos/{{REPO_NAME}}/commits/{{COMMIT_SHA}}/comments -f body="..."`, or open an issue with the diagnosis.

Do not push a fix directly to `{{BRANCH}}`. Your deliverable is a diagnosis comment, not a patch.
