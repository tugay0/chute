# Contributing to Chute

Thanks for taking a look! Chute is intentionally small and dependency-free — the
whole CLI is Go standard library shelling out to `ssh` + `rsync`.

## Develop

```bash
git clone https://github.com/tugay0/chute
cd chute
go build ./...          # build everything
go test ./...           # run tests
go vet ./...            # static checks
go run ./cmd/chute help
```

Point it at a scratch config so you don't touch your real one:

```bash
export CHUTE_CONFIG_DIR=/tmp/chute-dev
go run ./cmd/chute targets add local user@localhost '~/inbox/'
go run ./cmd/chute doctor
```

## Guidelines

- **No new dependencies** in the CLI without a very good reason — the zero-deps,
  single-binary property is a feature.
- Keep transfers transparent: everything should map to an `rsync`/`ssh` command a
  user could have typed themselves.
- Run `gofmt`/`go vet` before opening a PR; add a test when you fix a bug.
- Conventional-commit-style messages (`feat:`, `fix:`, `docs:`) are appreciated.

## Releases

Push a tag and GitHub Actions + GoReleaser do the rest:

```bash
git tag v0.2.0 && git push origin v0.2.0
```

The macOS menu-bar companion lives under [`app/`](app/) and builds with the system
`swiftc` (`cd app && ./build.sh`) — no Xcode project required.
