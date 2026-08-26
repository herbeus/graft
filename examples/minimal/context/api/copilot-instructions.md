# payments-api - shared agent instructions

Linked into the checkout as `.github/copilot-instructions.md`.

## Stack

- Go 1.23, chi router, sqlc against PostgreSQL.
- `make test` runs unit tests; `make test-integration` needs docker.

## House rules for agents

- Money is `int64` minor units. Never a float. Not once.
- Every handler needs a table-driven test including the error path.
- Migrations are append-only: never edit a migration that is already merged.
