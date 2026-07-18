# Quickstart

Zero to a running MongrelDB Crystal program in fifteen minutes. This guide
assumes a fresh machine and walks through installing the prerequisites,
starting the daemon, and writing, running, and understanding a complete
program.

---

## 1. Prerequisites

You need two things installed: the Crystal toolchain and a `mongreldb-server`
daemon.

### Install Crystal 1.10 or newer

Verify it:

```sh
crystal --version
# Crystal 1.x.x ...
```

If you do not have it, install from <https://crystal-lang.org/install/> or
your package manager (e.g. `pacman -S crystal`, `brew install crystal`).
`shards` (the dependency manager) ships with Crystal.

### Install mongreldb-server

Fetch a prebuilt server binary from the
[MongrelDB releases](https://github.com/visorcraft/MongrelDB/releases):

```sh
mkdir -p bin
curl -fsSL -o bin/mongreldb-server \
  https://github.com/visorcraft/MongrelDB/releases/download/v0.60.2/mongreldb-server-linux-x64
chmod +x bin/mongreldb-server
```

Verify it runs:

```sh
./bin/mongreldb-server --version
```

## 2. Start the daemon

By default `mongreldb-server` listens on `http://127.0.0.1:8453` and stores
data in the current working directory.

```sh
mkdir -p /tmp/mdb-data && cd /tmp/mdb-data
/path/to/mongreldb-server
```

In another terminal, sanity-check it:

```sh
curl http://127.0.0.1:8453/health
# ok
```

Leave the daemon running for the rest of this guide.

## 3. Create a project and pull in the client

Add the dependency to your `shard.yml`:

```yaml
dependencies:
  mongreldb:
    github: visorcraft/MongrelDB-Crystal
```

Then:

```sh
shards install
```

## 4. Write your first program

Create `src/demo.cr`:

```crystal
require "mongreldb"

# 1. Connect to the daemon. Empty/omitted URL falls back to http://127.0.0.1:8453.
db = MongrelDB::Client.new(url: "http://127.0.0.1:8453")

# 2. Health check before doing anything else.
unless db.health
  STDERR.puts "daemon not reachable"
  exit 1
end

# 3. Create a table. Each column has a stable numeric id, a name, a type, and
#    flags. The first column is the primary key.
tid = db.create_table("orders", [
  {"id" => 1, "name" => "id",       "ty" => "int64",   "primary_key" => true,  "nullable" => false},
  {"id" => 2, "name" => "customer", "ty" => "varchar", "primary_key" => false, "nullable" => false},
  {"id" => 3, "name" => "amount",   "ty" => "float64", "primary_key" => false, "nullable" => false},
])
puts "created table id: #{tid}"

# 4. Insert rows. Cells maps column id -> value.
db.put("orders", {1 => 1, 2 => "Alice", 3 => 99.5})
db.put("orders", {1 => 2, 2 => "Bob",   3 => 150.0})

# 5. Query with a native index condition. The range index serves this in
#    sub-millisecond. Projection selects only column ids 1 and 2.
rows = db.query("orders")
  .where("range_f64", {"column" => 3, "min" => 100.0})
  .projection([1, 2])
  .limit(100)
  .execute
rows.each { |row| puts "row: #{row.inspect}" }

# 6. Count the rows.
puts "total rows: #{db.count("orders")}"
```

Run it:

```sh
crystal run src/demo.cr
```

## 5. What each part does

| Code | What it does |
|------|--------------|
| `MongrelDB::Client.new(url)` | Builds an HTTP client targeting one daemon. Safe to share across fibers. |
| `db.health` | GET `/health`; returns `true` when the daemon answers. Always check before real work. |
| `db.create_table(name, cols)` | POST `/kit/create_table`. Column `id`s are the on-wire identifiers; use them everywhere else. |
| `db.put(table, cells)` | Single-op transaction: POST `/kit/txn` with one `put` op. `cells` is flattened to `[col_id, val, ...]`. |
| `db.query(table).where(...)` | Builds a `/kit/query` body. `where` pushes a condition down to a native index. |
| `.projection([1, 2])` | Server returns only those column ids, saving bandwidth. |
| `.limit(100)` | Caps the result; check `q.truncated?` afterward to detect overflow. |
| `.execute` | Sends the query and decodes the `rows` array. |
| `db.count(table)` | GET `/tables/{name}/count`. |

## 6. Retention, defaults, and time travel

The daemon retains a rolling window of MVCC commit epochs. You can inspect and
adjust it at runtime:

```crystal
db.set_history_retention_epochs(100)
puts db.history_retention_epochs   # => 100
puts db.earliest_retained_epoch    # => oldest readable epoch
```

Both endpoints require `ADMIN` permission when the daemon is started with
`--auth-token` or `--auth-users`. Connect with an admin user or token. Raising
the limit cannot bring back epochs that were already pruned.

With the window open, query older versions of a row:

```crystal
rows = db.sql("SELECT amount FROM orders AS OF EPOCH 42 WHERE id = 1")
```

Column definitions also support scalar defaults and dynamic `default_expr`
values. The following table mixes string, number, boolean, explicit null,
literal `"now"`, and `default_expr: "now"` defaults in one payload:

```crystal
db.create_table("events", [
  {"id" => 1, "name" => "id",     "ty" => "int64",     "primary_key" => true,  "nullable" => false},
  {"id" => 2, "name" => "msg",   "ty" => "varchar",   "default_value" => "untitled"},
  {"id" => 3, "name" => "score", "ty" => "int64",     "default_value" => 0},
  {"id" => 4, "name" => "live",  "ty" => "bool",      "default_value" => true},
  {"id" => 5, "name" => "extra", "ty" => "varchar",   "default_value" => nil},
  {"id" => 6, "name" => "ts",    "ty" => "timestamp", "default_value" => "now"},
  {"id" => 7, "name" => "ts2",   "ty" => "timestamp", "default_expr"  => "now"},
])
```

## 7. Common pitfalls

**Using the column name instead of the column id.** Every on-wire API uses the
numeric `id` from `create_table`, never the `name`. The query builder's
`column` alias maps to the server's `column_id` - pass the integer id, not the
string name:

```crystal
# Wrong:
.where("range_f64", {"column" => "amount", "min" => 100.0})
# Right:
.where("range_f64", {"column" => 3, "min" => 100.0})
```

**Treating a single `put` as non-transactional.** `put` is a one-op
transaction. A unique constraint violation surfaces as a `ConflictError`
(HTTP 409), not as a silent no-op.

**Calling `commit` twice on the same `Transaction`.** The second call raises
`Exception: transaction already committed`. Create a fresh
`db.begin_transaction` for each logical unit of work.

**Reusing a `QueryBuilder` and expecting a fresh `truncated?`.** `truncated?`
reflects the most recent `execute`. Build a new query, or re-run `execute`
before reading it.

**Expecting `sql` to always return rows.** The `/sql` endpoint streams Arrow
IPC for `SELECT` in most builds, so `sql` returns an empty array (not an
error) for result sets. Use it for DDL/DML and statements whose success is the
signal; use the native query builder for typed row retrieval.

**Pointing at a daemon that requires auth.** If the daemon was started with
`--auth-token` or `--auth-users`, every call raises `AuthError` unless you pass
`token:` or `username:`/`password:`. See [auth.md](auth.md).

## 8. Next steps

- [transactions.md](transactions.md) - atomic batches, idempotency, retries
- [queries.md](queries.md) - every native index condition
- [sql.md](sql.md) - recursive CTEs, window functions, `CREATE TABLE AS SELECT`
- [auth.md](auth.md) - bearer tokens, basic auth, user/role management
- [errors.md](errors.md) - the full error hierarchy and recovery patterns
