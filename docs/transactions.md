# Transactions

MongrelDB commits every write through a single atomic transaction endpoint
(`POST /kit/txn`). This guide covers the two ways to use it - a one-shot
single op, and a staged batch - plus idempotency keys for safe retries, typed
constraint-violation handling, and rollback.

The engine enforces `UNIQUE`, foreign-key, check, and trigger constraints at
**commit time**. A violation aborts the entire batch: no op in the batch
becomes visible.

---

## Single puts vs. batch transactions

### Single op: `Client#put`

`Client#put` is a convenience wrapper that sends a one-op transaction. Use it
when a write is independent and you do not need atomicity across multiple
rows.

```crystal
# One row, one atomic op. nil means "no idempotency key".
res = db.put("orders", {1 => 1, 2 => "Alice", 3 => 99.5})
puts res
```

`Client#upsert`, `Client#delete`, and `Client#delete_by_pk` are the same shape:
single-op transactions.

### Batch: `Client#begin_transaction` + `Transaction`

When several writes must succeed or fail together, stage them on a
`Transaction` and commit once. All ops go to the server in a single HTTP
request and commit atomically.

```crystal
txn = db.begin_transaction
txn.put("orders", {1 => 10, 2 => "Dave", 3 => 50.0})
txn.put("orders", {1 => 11, 2 => "Eve",  3 => 75.0})
txn.delete_by_pk("orders", 2)

results = txn.commit
puts "committed #{results.size} ops"
```

The `returning:` argument on `Transaction#put` asks the daemon to echo the
written row back in the result - useful for reading server-assigned values.

```crystal
txn = db.begin_transaction
txn.put("orders", {1 => 42, 2 => "Hal", 3 => 12.0}, returning: true)
res = txn.commit
puts "server echoed: #{res[0]}"
```

`Transaction#upsert(table, cells, update_cells:)` applies `update_cells` on a
primary-key conflict. A `nil` `update_cells` means "do nothing on conflict".

## Idempotency keys for safe retries

Networks drop requests and daemons crash after committing but before replying.
An idempotency key makes a commit safe to retry: the daemon remembers the key
and replays the **original** result on a duplicate commit, even across
restarts.

Pass the key with the `idempotency_key:` argument on `commit` (or on
`Client#put`/`Client#upsert`):

```crystal
# A web handler that must not double-charge, even if the client retries or the
# connection drops after the daemon committed.
def charge(db, order_id)
  txn = db.begin_transaction
  txn.put("charges", {1 => order_id, 2 => 199.0})

  # Use a stable, business-meaningful key derived from the request. On a retry
  # with the same key the daemon returns the first commit's result instead of
  # inserting a second row.
  txn.commit(idempotency_key: "charge:#{order_id}")
end
```

Rules for keys:

- Any non-empty string works. Prefer content-derived, globally-unique values
  (e.g. `"charge:#{order_id}"`).
- `nil` (the default) disables idempotency - a retry will commit again.
- The key scopes the **entire batch**, not individual ops. Reuse the exact
  same ops and key together when retrying.

A safe retry loop:

```crystal
def commit_with_retry(db, build_txn, key, max_attempts = 3)
  max_attempts.times do |attempt|
    # Build a fresh Transaction inside the loop so retries always start clean.
    txn = build_txn.call(db)
    return txn.commit(idempotency_key: key)
  rescue ex : MongrelDB::ConflictError | MongrelDB::AuthError
    raise ex # not transient - surface to the caller
  rescue ex : MongrelDB::MongrelDBError
    # QueryError / network - the idempotency key makes it safe to retry.
    raise ex if attempt == max_attempts - 1
    sleep(1 << attempt)
  end
end
```

Build the transaction inside the retry loop so a failed `commit` (which flips
the `Transaction` to "committed") is replaced by a fresh one carrying the same
ops and the same key.

## Handling constraint violations

Constraint violations arrive as HTTP 409, mapped to `MongrelDB::ConflictError`.
It carries the structured `error_code` and the offending op index:

```crystal
txn = db.begin_transaction
txn.put("orders", {1 => 1}) # duplicate PK
txn.commit
rescue ex : MongrelDB::ConflictError
  case ex.error_code
  when "UNIQUE_VIOLATION"
    STDERR.puts "duplicate at op #{ex.op_index}: #{ex.message}"
  when "FK_VIOLATION"
    STDERR.puts "missing parent at op #{ex.op_index}: #{ex.message}"
  when "CHECK_VIOLATION"
    STDERR.puts "check failed at op #{ex.op_index}: #{ex.message}"
  else
    STDERR.puts "other conflict: #{ex.message}"
  end
end
```

The error envelope from the daemon looks like:

```json
{"status": "aborted", "error": {"code": "UNIQUE_VIOLATION", "message": "...", "op_index": 0}}
```

`op_index` points at the offending op within the batch so you can report which
row caused the failure.

## Rollback after failure

There are two notions of "rollback":

1. **Server-side.** When `commit` raises `ConflictError`, the engine has
   already discarded the entire batch. Nothing was written; there is no server
   rollback to perform.
2. **Client-side.** `Transaction#rollback` clears the locally staged ops. Call
   it to release the `Transaction` when you decide not to commit (for example,
   after a validation error in your own code, before ever sending).

```crystal
txn = db.begin_transaction
txn.put("orders", {1 => 1, 2 => "Iris", 3 => 5.0})

unless business_rule_ok
  # Throw the staged ops away locally. Nothing has been sent to the daemon.
  txn.rollback
  next
end

begin
  txn.commit
rescue ex : MongrelDB::ConflictError
  # On conflict the server already rolled back; nothing more to do.
end
```

`rollback` and `commit` both raise `Exception` if the transaction was already
committed. Treat that as a programming error to fix upstream, not a runtime
condition to silence.

## Summary

| Goal | Use |
|------|-----|
| One independent write | `Client#put` / `upsert` / `delete` / `delete_by_pk` |
| Several writes that must commit together | `Client#begin_transaction` + `Transaction#commit` |
| Retry safely after a network blip | `commit(idempotency_key:)` with a stable key |
| Distinguish constraint classes | rescue `ConflictError`, read `.error_code` and `.op_index` |
| Abort before sending | `Transaction#rollback` |

See [errors.md](errors.md) for the full error hierarchy and [queries.md](queries.md)
for read patterns.
