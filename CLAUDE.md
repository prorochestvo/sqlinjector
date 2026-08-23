# CLAUDE.md

## Build & Run Commands

This module is a **library** (`package sqlinjector`, import path
`github.com/prorochestvo/sqlinjector`) — there is no `main` package and no binary to run.
All drivers are pure-Go, so everything builds and tests with `CGO_ENABLED=0`.

There is no Makefile; use the Go toolchain directly:

```bash
CGO_ENABLED=0 go build ./...                 # compile every package
CGO_ENABLED=0 go vet ./...                   # static checks
gofmt -l -w .                                # format (lists + rewrites)
CGO_ENABLED=0 go test -race ./...            # full test suite
```

Targeted runs use standard `go test` flags, e.g. `CGO_ENABLED=0 go test -race -run 'TestODataExpression/filter_eq' ./` (root) or `-v ./internal/expression/`; add `-coverprofile=cover.out` then `go tool cover -html` for coverage.

**Docker for tests.** SQLite tests run in-memory (pure Go, no Docker). The Postgres/MySQL paths (`NewSandboxOf*`, `internal/sandbox`) spin up ephemeral `testcontainers-go` containers and need a running Docker daemon (they pull `postgres:latest`/`mysql:latest` on first run). `docker-compose.yaml` is a separate local convenience — the suite does **not** read it and consumes no DSN env var.

## Architecture Overview

SQLInjector is a thin toolkit layered on top of the
[SQLBoiler](https://github.com/volatiletech/sqlboiler) ORM. It bundles four concerns a
SQLBoiler-based app repeatedly needs: opening/configuring database sessions across three
dialects, applying schema migrations, building queries (including OData `$filter` parsing)
into SQLBoiler `qm.QueryMod`s, and running actions inside a single commit/rollback
transaction. A generic in-memory repository and disposable database "sandboxes" round it
out so downstream packages can unit-test without a real database. The public surface lives
in the root package; `internal/` holds the dialect-specific machinery.

### Components

| File / package | Role |
|----------------|------|
| `connection.go` | Opens dialect sessions (`NewPostgreSQL`/`NewMySQL`/`NewSQLite3`) returning a `Vault`; pool tuning via `Parameter`s. |
| `expression.go` | Query builder: clause builders + `ODataExpression` (parses `$filter`/`$sort`/`$Limit`/`$Offset`) into `qm.QueryMod`. |
| `migration.go` | `Migrater` plus migration sources (file, embed, memory, struct-reflection); `MultipleMigration` merges + ID-sorts. |
| `repository.go` | Generic `Repository[K,V]` CRUD/batch contract + in-memory `DummyRepository` test double. |
| `sandbox.go` | Disposable migrated databases: Postgres/MySQL via Docker pool, SQLite in-memory. Caller must Close the `Vault`. |
| `transaction.go` | Runs typed `Action[T]`s inside one commit/rollback transaction. |
| `internal/vault.go` | Core interfaces (`Vault`/`Transaction`/`Executor`/`Extractor`) — the `database/sql` surface the library targets. |
| `internal/dialect.go` | `Dialect` enum -> `sql.Open` driver names. |
| `internal/expression/` | Per-clause builders, the `combiner` that flattens them to `qm.QueryMod`, and the OData filter parser. |
| `internal/schema/` | Migration engine: `.sql`/struct parsing, MD5 identities, State/Plan/Up/Down against the tracking table. |
| `internal/sandbox/` | `testcontainers-go` wrappers + `imitator.go` (in-memory expression evaluator backing `DummyRepository`). |
| `internal/transaction/` | Runs an action slice in one `*sql.Tx`, committing/rolling back as a unit. |

### Key Patterns

- **Vault abstraction** — everything programs against `internal.Vault` (Begin/Exec/Query/Close), never a concrete `*sql.DB`, so connections, migrations, transactions and sandboxes are interchangeable and a `*sql.Tx` can stand in for any executor.
- **Expression -> QueryMod** — each clause implements `Expression` (`QueryMod() []qm.QueryMod`); `combiner` concatenates them, so builders, OData parsing and the in-memory imitator share one representation. Gotcha: `Or` only fuses concrete `*expression.Where` operands; mixed types fall back to AND-combining.
- **Generic repository + in-memory double** — `Repository[K constraints.Ordered, V any]` is the persistence contract; `DummyRepository` satisfies it in memory (keyed by a reflected `id`-style field, filtered via the sandbox imitator) so service/handler code is tested without a DB.
- **Disposable sandboxes** — a fully-migrated throwaway DB per call (pooled `testcontainers` container, isolated by a generated schema/db name, or in-memory SQLite); the caller must Close the returned `Vault` to free Docker resources.

### Database

Three engines, all **pure-Go (no CGO)**: PostgreSQL (`lib/pq`), MySQL (`go-sql-driver/mysql`), SQLite3 (`glebarez/sqlite`, a `modernc.org/sqlite` driver). The `glebarez` choice is what keeps the build CGO-free — never swap to CGO `mattn/go-sqlite3` (see Constraints).

**Schema & migrations** (driven by `Migrater`, no external tool):

- An `Instruction` = `ID` + up/down SQL; identity is the **MD5 of `up + "\n" + down`**. `.sql` files use `--- #migrate:up` / `--- #migrate:down` markers (`MigrationCommandPrefix`); other `--` lines are comments. For file/embed sources the **filename is the migration ID** and instructions apply in **lexicographic ID order** — no enforced `YYYYMM`/counter convention, so name files to sort correctly.
- Applied migrations are tracked in `_migrations` (override via `SetTableName`; columns `id, md5, applied_at`). `Up` applies all pending in **one transaction**; `Down` reverses the latest applied tail; `Clean` reverses everything.
- **Drift**: `State` marks each instruction applied `[X]` / pending `[ ]` / `ERR` (stored MD5 no longer matches code = migration edited after apply). `Plan` errors if the DB holds migration IDs the code doesn't know.
- `NewStructMigration` reflects `boil` field tags into `CREATE TABLE` DDL; per-dialect type mapping in `internal/schema/instruction.go` (`fieldType.toSqlType`).

> Caution: the migration-table `INSERT`/`DELETE` statements are string-formatted, not
> parameterized (IDs/MD5s are stripped of quotes first). Migration IDs are developer-controlled,
> not user input — keep it that way.

### Key Dependencies

Direct deps live in `go.mod`: SQLBoiler (+ `queries/qm`, the expression builder's target), `volatiletech/null` (nullable types the DDL generator recognises), the three pure-Go drivers, `testcontainers-go`, `testify`, and `golang.org/x/exp/constraints` (the `Ordered` key constraint). The pure-Go SQLite choice is the load-bearing one — see Constraints.

### Error Handling

Library surfaces return plain `error` (no `PublicError` user/internal split). Wrap with `fmt.Errorf("...: %w", err)` to preserve the cause for `errors.Is`/`As`; aggregate teardown failures with `errors.Join` (e.g. an op error joined with the `Rollback()`/`Close()` error in `defer`) so a secondary failure is never swallowed. No exported sentinels or custom error types — callers match on wrapped causes.

## Conventions

Generic Go conventions (style, declaration order, test structure, godoc, error discipline,
build hygiene, organisation) come from the `stack-go` plugin skills and are not restated
anywhere in this repo. Project-specific constraints:

- **Forbidden imports**: never introduce `github.com/mattn/go-sqlite3` (or any other
  CGO-dependent driver) — it would force `CGO_ENABLED=1` and break the pure-Go build.
  The SQLite path must stay on `github.com/glebarez/sqlite`.
- **Docker for DB tests**: PostgreSQL/MySQL tests need a running Docker daemon
  (`testcontainers-go`); SQLite tests run in-memory without it.
- **No Makefile**: gates run as raw Go commands (`gofmt -l .`,
  `CGO_ENABLED=0 go vet ./...`, `CGO_ENABLED=0 go test -race ./...`). Scratch stays
  in `./tmp/`, never the repo root.

## Working agreement

Plan-first pipeline; the canonical procedure is the `pipeline:working-agreement` skill — load it
before starting non-trivial work. Project delta:

- **Gate:** `gofmt -l .` clean, then `CGO_ENABLED=0 go vet ./...` and
  `CGO_ENABLED=0 go test -race ./...` green.
- **Lenses:** standard set — see `pipeline:working-agreement`, which includes lens O.
- **Branching:** standard (`type/<issue>-<slug>`, PR into `main`).
