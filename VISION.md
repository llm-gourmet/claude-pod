# Vision

claude-pod provides a fully controlled environment for running Claude Code autonomously on real projects with real secrets.

Every outbound network call is authorized explicitly by the user. No secret ever leaves the environment in an uncontrolled way. Claude cannot reach unknown domains. Claude cannot affect the host system. Claude cannot write to the host — only specific host files are readable inside the sandbox. No network call leaves without explicit user authorization.

Within those boundaries, Claude operates as a capable autonomous agent, executing the user's custom workflows without interruption. The user stays in the loop: every action is logged and every decision is traceable.

**The governing principle:** autonomy inside the sandbox, control at the boundary.
