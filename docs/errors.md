# Error handling

Every non-2xx response from the daemon is mapped to a typed Crystal exception.
This is the complete reference: the exception hierarchy, the HTTP-status
mapping, the daemon's error envelope, and recovery patterns for each category.

---

## The error model

All client errors descend from `MongrelDB::MongrelDBError`. The client raises a
specific subclass for each failure category:

| Class | Meaning | Typical cause |
|-------|---------|---------------|
| `MongrelDB::MongrelDBError` | Base class for all client errors | (rescue this to catch any failure) |
| `MongrelDB::AuthError` | HTTP 401 or 403 | Missing/bad credentials against an auth-enabled daemon |
| `MongrelDB::NotFoundError` | HTTP 404 | Missing table, schema, or resource |
| `MongrelDB::ConflictError` | HTTP 409 | Unique, foreign-key, check, or trigger violation at commit |
| `MongrelDB::QueryError` | HTTP 400 or 5xx, plus network | Malformed request, server failure, transport error |

`ConflictError` carries extra detail via accessors:

| Accessor | Meaning |
|--------|---------|
| `ex.error_code` | The server's structured error code (e.g. `"UNIQUE_VIOLATION"`); `""` when absent |
| `ex.op_index` | The offending op index within a batch, when reported; `nil` otherwise |

## The daemon's error envelope

```json
{
  "status": "aborted",
  "error": {
    "code": "UNIQUE_VIOLATION",
    "message": "duplicate key in column 1",
    "op_index": 0
  }
}
```

Structured codes you will commonly see in `error_code`:

| `error_code` | Meaning |
|--------------|---------|
| `UNIQUE_VIOLATION` | A unique/PK constraint rejected the commit |
| `FK_VIOLATION` | A foreign-key reference was missing |
| `CHECK_VIOLATION` | A check constraint or trigger rejected the commit |
| `NOT_FOUND` | A named resource (table, schema) does not exist |

## HTTP status -> exception mapping

| HTTP status | Exception | Notes |
|-------------|-----------|-------|
| 401, 403 | `AuthError` | Bad/missing credentials |
| 404 | `NotFoundError` | Resource not found |
| 409 | `ConflictError` | Constraint violation at commit |
| 400 | `QueryError` | Malformed request / bad query |
| 5xx | `QueryError` | Daemon-side failure |
| other non-2xx | `QueryError` | Catch-all |
| 2xx | (no error) | Success |

Network and encoding problems (`Socket::Error`, `IO::Error`, JSON encode
failures for NaN/Infinity, etc.) are also mapped to `QueryError`.

## Discriminating errors

### By category - rescue the subclass

```crystal
begin
  db.schema_for("missing_table")
rescue ex : MongrelDB::NotFoundError
  puts "table does not exist"
rescue ex : MongrelDB::ConflictError
  puts "unexpected conflict on a read"
rescue ex : MongrelDB::AuthError
  puts "bad credentials"
rescue ex : MongrelDB::QueryError
  puts "server error or malformed request"
rescue ex : MongrelDB::MongrelDBError
  puts "other error: #{ex.message}"
end
```

### By details - read `ConflictError` fields

```crystal
begin
  txn.commit
rescue ex : MongrelDB::ConflictError
  puts "status=409 code=#{ex.error_code} op=#{ex.op_index} msg=#{ex.message}"
end
```

## Recovery patterns

### Auth failure - do not retry blindly

A retry will not fix bad credentials. Surface the error to the caller or
operator.

```crystal
rescue ex : MongrelDB::AuthError
  raise "credentials rejected; refresh token: #{ex.message}"
end
```

### Not found - fall back, do not crash

For lookups by primary key, a 404 may be a normal "absent" result.

```crystal
begin
  db.schema_for(table_name)
rescue ex : MongrelDB::NotFoundError
  {} of String => JSON::Any # table missing - treat as empty
end
```

Note: a `pk` query against an existing table returns zero rows, not a 404;
`NotFoundError` here means the table itself is missing.

### Constraint conflict - report the offending op

```crystal
begin
  txn.commit
rescue ex : MongrelDB::ConflictError
  if idx = ex.op_index
    STDERR.puts "op #{idx} violated #{ex.error_code}: #{ex.message}"
  else
    STDERR.puts "conflict #{ex.error_code}: #{ex.message}"
  end
  raise ex
end
```

The engine already rolled back the whole batch - there is nothing to undo.

### Transient failure - retry with an idempotency key

`QueryError` covers transport and 5xx failures. With an idempotency key,
retrying a transaction is safe (see [transactions.md](transactions.md)).

```crystal
def run(db, build_txn, key)
  # build_txn is a Proc returning a fresh Transaction with the same ops.
  build_txn.call(db).commit(idempotency_key: key)
rescue ex : MongrelDB::AuthError | MongrelDB::ConflictError
  raise ex # not transient
rescue ex : MongrelDB::MongrelDBError
  raise ex # QueryError / network - caller may retry with the same key
end
```

### Transaction-state error

Calling `commit` or `rollback` twice on the same `Transaction` raises
`Exception`. That is a programming bug - fix the control flow rather than
catching it.

## Quick reference

```crystal
# Category checks (most specific first):
rescue ex : MongrelDB::AuthError      # 401/403
rescue ex : MongrelDB::NotFoundError  # 404
rescue ex : MongrelDB::ConflictError  # 409
rescue ex : MongrelDB::QueryError     # 400/5xx/network
rescue ex : MongrelDB::MongrelDBError # base

# Detail extraction on a conflict:
rescue ex : MongrelDB::ConflictError
  ex.error_code # String, e.g. "UNIQUE_VIOLATION"
  ex.op_index   # Int32? or nil
  ex.message    # String
end
```

## Next steps

- [transactions.md](transactions.md) - constraint handling and retries in context
- [auth.md](auth.md) - credential management
