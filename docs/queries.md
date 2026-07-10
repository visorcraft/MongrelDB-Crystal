# Queries

The fluent `QueryBuilder` pushes conditions down to MongrelDB's native indexes
for sub-millisecond lookups - bitmap, learned-range, FM-index full text, HNSW
vector similarity, and more. Each condition type maps to one specialized
index; conditions are AND-ed together.

```crystal
rows = db.query("orders")
  .where("range_f64", {"column" => 3, "min" => 100.0, "max" => 500.0})
  .projection([1, 2])
  .limit(100)
  .execute
```

This guide covers every condition type, projection, limits and truncation,
combining conditions, and the friendly aliases the builder translates for you.

---

## The basics

Every query starts with `Client#query(table)` and ends with `execute`:

| Method | Purpose |
|--------|---------|
| `where(type, params)` | Add a native condition. Multiple `where` calls are AND-ed. |
| `projection(column_ids)` | Return only these column ids (`nil` means all columns). |
| `limit(n)` | Cap the number of rows. |
| `build` | Produce the request payload (useful for debugging). |
| `execute` | Send and decode. Records the `truncated?` flag. |
| `truncated?` | Whether the last `execute` hit the limit. |

The request body produced by `build` matches the daemon's `/kit/query` shape:

```json
{
  "table": "orders",
  "conditions": [{"range_f64": {"column_id": 3, "lo": 100.0, "hi": 500.0, "lo_inclusive": true, "hi_inclusive": true}}],
  "projection": [1, 2],
  "limit": 100
}
```

## Condition types

`params` is a `Hash`. Column references use the numeric **column id**, never
the column name.

### `pk` - exact primary-key match

The fastest lookup. `value` is the primary-key value.

```crystal
db.query("orders").where("pk", {"value" => 42}).execute
```

### `range` - integer range (learned-range index)

Inclusive bounds. Omit `lo` or `hi` for an open range.

```crystal
db.query("orders")
  .where("range", {"column" => 3, "min" => 100, "max" => 500})
  .execute

# Open-ended: amount >= 100
db.query("orders")
  .where("range", {"column" => 3, "min" => 100})
  .execute
```

### `range_f64` - float range with inclusive/exclusive control

Adds `lo_inclusive` / `hi_inclusive` flags (default inclusive).

```crystal
db.query("orders")
  .where("range_f64",
    {"column" => 3,
     "min" => 100.0,
     "max" => 500.0,
     "min_inclusive" => true,
     "max_inclusive" => false}) # (100.0, 500.0]
  .execute
```

### `bitmap_eq` - equality on a bitmap-indexed column

Best for low-cardinality columns (status, category, booleans).

```crystal
db.query("orders")
  .where("bitmap_eq", {"column" => 2, "value" => "Alice"})
  .execute
```

### `bitmap_in` - IN predicate on a bitmap-indexed column

Match any of a set of values.

```crystal
db.query("orders")
  .where("bitmap_in", {"column" => 2, "values" => ["Alice", "Bob", "Carol"]})
  .execute
```

### `is_null` / `is_not_null` - null checks

```crystal
db.query("orders").where("is_null", {"column" => 3}).execute
db.query("orders").where("is_not_null", {"column" => 3}).execute
```

### `fm_contains` - full-text substring search (FM-index)

Substring match within a column. Use `pattern` (the server key) or the
friendly `value` alias - both translate to `pattern` on the wire for FTS
conditions.

```crystal
db.query("documents")
  .where("fm_contains", {"column" => 2, "pattern" => "database performance"})
  .limit(10).execute

# Friendly alias: "value" -> "pattern" for fm_contains only.
db.query("documents")
  .where("fm_contains", {"column" => 2, "value" => "database"})
  .execute
```

### `fm_contains_all` - multiple substrings, all must match

```crystal
db.query("documents")
  .where("fm_contains_all", {"column" => 2, "patterns" => ["database", "performance"]})
  .execute
```

### `ann` - dense vector similarity (HNSW)

Approximate nearest-neighbors over a `float` vector column. `k` is the result
count.

```crystal
db.query("embeddings")
  .where("ann", {"column" => 2, "query" => [0.1, 0.2, 0.3, 0.4], "k" => 10})
  .execute
```

### `sparse_match` - sparse vector match

For sparse/bag-of-words vectors.

```crystal
db.query("docs")
  .where("sparse_match", {"column" => 2, "query" => {"0" => 1.0, "7" => 0.5, "42" => 2.0}, "k" => 10})
  .execute
```

### `min_hash_similar` - MinHash similarity

Near-duplicate detection via MinHash signatures.

```crystal
db.query("pages")
  .where("min_hash_similar", {"column" => 2, "query" => [12, 99, 421, 7], "k" => 5})
  .execute
```

## Projection (column selection)

`projection([1, 2, ...])` restricts the columns in each returned row. Pass
`nil` (or skip the call) for all columns. Projecting to only the columns you
need cuts bandwidth and decode cost.

```crystal
db.query("orders")
  .where("range", {"column" => 3, "min" => 100})
  .projection([1, 2])
  .execute
```

Returned rows are `JSON::Any` objects; access fields by key.

## Limit and the truncated flag

`limit(n)` caps the result. When the server has more matches than the limit
allows, it returns the first `n` and sets `truncated: true`. Read it with
`truncated?` **after** `execute`.

```crystal
q = db.query("orders").where("range", {"column" => 3, "min" => 0}).limit(100)
rows = q.execute
if q.truncated?
  # 100 rows came back but more exist on the server. Either raise the limit,
  # page with a range predicate on the PK, or accept the cap.
  STDERR.puts "result capped at #{rows.size}; more rows available"
end
```

`truncated?` returns `false` until `execute` has run, so build a fresh query
for each independent lookup.

## Multiple AND conditions

Chain `where` calls. Every condition must match; the server intersects the
index results.

```crystal
# Customer is Alice AND amount is between 100 and 500.
db.query("orders")
  .where("bitmap_eq", {"column" => 2, "value" => "Alice"})
  .where("range", {"column" => 3, "min" => 100, "max" => 500})
  .projection([1, 3])
  .limit(50)
  .execute
```

## Friendly alias translation

The builder accepts readable parameter names and translates them to the
server's canonical on-wire keys. Both spellings work, so use whichever is
clearer in context.

| You write | Sent as | Applies to |
|-----------|---------|------------|
| `column` | `column_id` | all condition types |
| `min` | `lo` | `range`, `range_f64` |
| `max` | `hi` | `range`, `range_f64` |
| `min_inclusive` | `lo_inclusive` | `range_f64` |
| `max_inclusive` | `hi_inclusive` | `range_f64` |
| `value` | `pattern` | `fm_contains`, `fm_contains_all` only |

The `value` -> `pattern` alias applies **only** to FTS conditions, because
`pk` and `bitmap_eq` use `value` as their canonical key. For those, write
`value` directly.

## Putting it together

A realistic combined lookup - bitmap equality + range + projection + limit +
truncation check:

```crystal
def top_spenders(db, customer)
  q = db.query("orders")
    .where("bitmap_eq", {"column" => 2, "value" => customer})
    .where("range", {"column" => 3, "min" => 100})
    .projection([1, 3])
    .limit(50)
  rows = q.execute
  STDERR.puts "warning: top_spenders result capped at 50" if q.truncated?
  rows
end
```

For arbitrary predicates, joins, and aggregations that the native indexes do
not cover, use SQL instead - see [sql.md](sql.md).
