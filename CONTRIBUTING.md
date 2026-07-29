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

If you would rather catch it before pushing, Runic ships editor integrations, and a git hook is a
few lines. Put this in `.git/hooks/pre-commit` and make it executable; the file is local to your
clone and is not tracked:

```bash
#!/usr/bin/env bash
exec 1>&2
set -o pipefail
git diff --cached -z --name-only --diff-filter=ACM -- '*.jl' \
    | xargs -0 --no-run-if-empty runic --check --diff
```

Then `chmod +x .git/hooks/pre-commit`. The hook prints a diff and aborts the commit when a staged
Julia file is unformatted; `runic --inplace .` fixes it, and `git commit --no-verify` skips the check
for a single commit. Note that it reads the working tree copy rather than the staged blob, so a
partially staged file is judged by its full contents.

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
