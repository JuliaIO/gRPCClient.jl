# Contributing to gRPCClient.jl

Thanks for your interest in improving gRPCClient.jl. Issues and pull requests are welcome.

## Formatting

This repository is formatted with [Runic.jl](https://github.com/fredrikekre/Runic.jl). Please run the
formatter over your changes before opening a pull request, so that diffs stay free of unrelated
whitespace churn.

Install it once as an app, from the Julia Pkg REPL:

```
] app add Runic
```

Then format the repository in place, from the repository root:

```bash
runic --inplace .
```

To check without writing, which is what a reviewer will do, swap `--inplace` for `--check --diff`.
Runic has no configuration, so there is nothing to tune: whatever it emits is the house style.

App installation needs Julia 1.12 or newer, and `~/.julia/bin` on your `PATH`. On an older Julia,
`julia --project=@runic -e 'using Runic; exit(Runic.main(ARGS))' -- --inplace .` does the same thing
against an environment you have added Runic to.

CI runs the same check on every pull request that touches a `.jl` file, so an unformatted branch
shows up as a red Format job.

If you would rather catch it before pushing, Runic ships editor integrations, and the repository
ships a pre-commit hook in `scripts/pre-commit-runic`. Install it into your clone with:

```bash
cp scripts/pre-commit-runic .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit
```

`.git/hooks/` is local to your clone and not tracked, so the hook is opt-in. It formats the `.jl`
files staged for the commit with `runic --inplace` and re-stages the result, so what you commit
always passes the check; unrelated work-in-progress files are left alone. One edge case to be
aware of: a partially staged file that needs formatting cannot be re-staged without pulling its
unstaged hunks into the commit, so the hook refuses and asks you to `git add` the whole file and
retry. If the `runic` CLI is missing the hook skips silently, and `git commit --no-verify` bypasses
it for a single commit.

## Tests

The suite runs against the Go reference server in `test/go`. Build it first, then let the suite
manage its lifetime:

```bash
cd test/go && go build -o grpc_test_server && cd ../..
JULIA_GRPCCLIENT_TEST_START_SERVER=go julia --project test/runtests.jl
```

If you already have a server listening on `localhost:8001`, plain `julia --project test/runtests.jl`
is enough. `GRPC_TEST_SERVER_HOST` and `GRPC_TEST_SERVER_PORT` point the suite elsewhere.

CI covers Julia 1.10, 1.12, and nightly across Linux, Windows, and macOS.

## Pull requests

- Keep the change focused, and describe what it does and why in the PR body
- Add or extend tests in `test/runtests.jl` for behavior changes, including the failure paths
- If you change `src/ProtoBuf.jl`, regenerate the checked-in stubs with `bash protoc.sh` from `test`,
  since the `Code Generation` testset asserts on the generated text
- If you change a public method signature, update the `@docs` blocks in `docs/src/index.md`, which
  Documenter builds strictly
- The `skills/` directory is the authoritative reference for library behavior; update it when
  behavior changes
