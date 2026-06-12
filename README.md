# agent-tools

Shared agent tooling for the Proofhouse org. The repo ships Go
command-line tools for agent harnesses, plus the org's shared
[APM](https://microsoft.github.io/apm) package of agent primitives.

## APM package

Repos across the org install the shared primitives with the
[APM CLI](https://microsoft.github.io/apm/quickstart/):

```bash
apm install proofhouse/agent-tools#v0.1.0
```

The package ships these primitives from [`.apm/`](.apm/):

| Primitive | Type | Purpose |
| --- | --- | --- |
| `commit` | skill | Draft commit messages in `COMMIT_AGENTMSG`, lint with `just lint-commit-msg`, then commit the validated draft. |
| `worktree-wip` | instructions | Stash and work-in-progress rules for repos that run more than one agent worktree session. |

This repo dogfoods its own package: `apm install` deploys the
primitives into the local harness layout, and CI rejects drift between
`.apm/` sources and the deployed copies.

## Go tools

Each tool under [`cmd/`](cmd/) builds as a standalone binary:

- `agenthooks` manages shared agent hooks.
- `agentstore` stores shared agent state.
- `agentcontext` assembles shared agent context.

Install one directly:

```bash
go install github.com/proofhouse/agent-tools/cmd/agenthooks@latest
```

Or build everything from a checkout:

```bash
just build
```

## Development

`just` drives the workflow: `just lint` runs the full lint suite,
`just test` runs the tests, and `just build` compiles the binaries
into `bin/`. See the [Justfile](Justfile) for the complete recipe
list, and [AGENTS.md](AGENTS.md) for the agent-facing contributor
guide.

## Releases

[cocogitto](https://github.com/cocogitto/cocogitto) cuts `vX.Y.Z` tags
from the Conventional Commit history. One tag serves both consumer
paths, with APM installs pinning `proofhouse/agent-tools#vX.Y.Z` and
Go installs pinning `@vX.Y.Z`.

## License

Apache-2.0. See [LICENSE](LICENSE).
