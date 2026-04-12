A push landed on branch `{{BRANCH}}` of {{REPO_NAME}}.

**Commit:** {{COMMIT_SHA}}
**Author:** {{COMMIT_AUTHOR}}
**Pusher:** {{PUSHER}}
**Compare:** {{COMPARE_URL}}

**Message:**
{{COMMIT_MESSAGE}}

---

Please investigate this push:
1. Fetch the latest state with `git fetch` and `git checkout {{BRANCH}}`.
2. Review the diff introduced by this commit: `git show {{COMMIT_SHA}}`.
3. If the change touches documentation, verify links and TOC.
4. If the change touches code, run the test suite (find the test command in README, Makefile, or package.json).
5. Post a short summary of what you found as a comment on the most recently-opened related PR if one exists, otherwise log your findings to a local file.

Do not push any new commits in this session.
