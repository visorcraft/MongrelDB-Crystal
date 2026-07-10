# SQL

MongrelDB ships a DataFusion-backed SQL engine at `POST /sql`. From Crystal,
run SQL with `Client#sql`:

```crystal
rows = db.sql("SELECT 1")
```

This guide covers the SQL surface - DDL, DML, `CREATE TABLE AS SELECT`,
recursive CTEs, and window functions - and when to reach for SQL versus the
native query builder.

---

## How `sql` behaves

`Client#sql(sql)` sends `{"sql": "...", "format": "json"}` to `/sql`. It
requests JSON output and returns the decoded rows when the daemon replies with
a JSON result set, and an empty array with a nil error otherwise.

In practice:

- **DDL and DML** (`CREATE TABLE`, `INSERT`, `UPDATE`, `DELETE`) reply with a
  non-JSON status body. `sql` returns `[]` - success is the signal.
- **`SELECT`** in most daemon builds streams Arrow IPC bytes rather than JSON.
  `sql` therefore returns `[]` for SELECTs too. Use the native `QueryBuilder`
  for typed row retrieval in application code, and use `sql` for statements
  whose execution is the goal (DDL/DML/admin).

Errors are mapped to the same typed exceptions as everything else: an HTTP 400
or 5xx raises `QueryError`; 409 raises `ConflictError`; and so on. See
[errors.md](errors.md).

```crystal
begin
  db.sql("INSERT INTO orders (id, customer, amount) VALUES (99, 'Zoe', 999.0)")
rescue ex : MongrelDB::ConflictError
  STDERR.puts "duplicate row: #{ex.message}" if ex.error_code == "UNIQUE_VIOLATION"
end
```

## CREATE TABLE

Define a table in SQL instead of via `Client#create_table`. Column ids are
assigned by the server when not stated.

```crystal
db.sql(<<-SQL)
  CREATE TABLE products (
    id          INT64 PRIMARY KEY,
    name        VARCHAR,
    price       FLOAT64,
    category    VARCHAR,
    in_stock    BOOLEAN
  )
SQL
```

## INSERT

```crystal
db.sql("INSERT INTO products (id, name, price, category, in_stock) VALUES (1, 'Widget', 9.99, 'tools', true)")
db.sql("INSERT INTO products VALUES (2, 'Gadget', 19.99, 'tools', true)")
```

For bulk inserts, the native batch transaction (`Client#begin_transaction`) is
usually faster because it stages ops in one round trip without re-parsing SQL.

## UPDATE

```crystal
db.sql("UPDATE products SET price = 14.99 WHERE id = 1")
db.sql("UPDATE orders SET amount = 200.0 WHERE customer = 'Bob'")
```

## DELETE

```crystal
db.sql("DELETE FROM products WHERE in_stock = false")
db.sql("DELETE FROM products WHERE id = 2")
```

## SELECT

```crystal
db.sql("SELECT id, name FROM products WHERE category = 'tools' ORDER BY price")
db.sql("SELECT category, COUNT(*) AS n FROM products GROUP BY category")
```

Remember SELECT bodies usually arrive as Arrow IPC, so `sql` returns an empty
array. To read rows back into Crystal, mirror the same lookup with the
`QueryBuilder`.

## CREATE TABLE AS SELECT

Materialize a query result into a new table. Great for snapshots, rollups,
and denormalized aggregates.

```crystal
# Snapshot all high-value orders into a new table.
db.sql("CREATE TABLE archive AS SELECT * FROM orders WHERE amount > 500")

# Roll up sales by customer.
db.sql(<<-SQL)
  CREATE TABLE sales_by_customer AS
  SELECT customer, SUM(amount) AS total
  FROM orders
  GROUP BY customer
SQL
```

The new table inherits column types from the query. Query it afterward with
the native builder or SQL.

## Recursive CTEs

`WITH RECURSIVE` is fully supported. Classic use cases: series generation,
hierarchy/graph traversal.

```crystal
# Generate the numbers 1..10.
db.sql(<<-SQL)
  WITH RECURSIVE r(n) AS (
    SELECT 1
    UNION ALL
    SELECT n + 1 FROM r WHERE n < 10
  )
  SELECT n FROM r
SQL
```

A common practical example is walking an adjacency list:

```crystal
db.sql(<<-SQL)
  WITH RECURSIVE descendants(id) AS (
    SELECT id FROM categories WHERE id = 1
    UNION ALL
    SELECT c.id FROM categories c
    JOIN descendants d ON c.parent_id = d.id
  )
  SELECT id FROM descendants
SQL
```

## Window functions

Window functions compute aggregates/rankings across a moving window without
collapsing rows. Useful for top-N-per-group, running totals, and row numbers.

```crystal
# Row number within each customer, ordered by amount descending.
db.sql(<<-SQL)
  SELECT id, customer, amount,
         ROW_NUMBER() OVER (PARTITION BY customer ORDER BY amount DESC) AS rn
  FROM orders
SQL

# Running total per customer.
db.sql(<<-SQL)
  SELECT id, customer, amount,
         SUM(amount) OVER (PARTITION BY customer ORDER BY id) AS running_total
  FROM orders
SQL
```

`RANK()`, `DENSE_RANK()`, `LAG()`, `LEAD()`, `NTILE()`, and the usual
window-frame clauses are available through DataFusion.

## When to use SQL vs. the query builder

Both read from the same tables, but they are optimized for different jobs.

| Reach for | When |
|-----------|------|
| **`QueryBuilder`** | Point lookups, range scans, bitmap filters, full-text, and vector similarity that map to a native index. Sub-millisecond, no parser overhead, and rows decode into Crystal directly. |
| **SQL** | DDL (`CREATE TABLE`, schemas, materialized views), multi-statement setup, joins, recursive CTEs, window functions, and arbitrary aggregates. Also the natural choice for admin scripts and one-off analysis. |

Rules of thumb:

- Need a typed `Array(JSON::Any)` of matching rows? Use the query builder.
- Building/dropping tables, or running a `CREATE TABLE AS SELECT`? Use SQL.
- Joining multiple tables, computing rankings, or walking a graph? Use SQL.
- Filtering by one or more indexed columns? Use the query builder - it is
  faster and avoids Arrow-to-Crystal decoding.

Mix freely: create tables with SQL, write rows with `Client#put`, read them
back with `QueryBuilder`, and run analytics with SQL.

## Next steps

- [queries.md](queries.md) - every native index condition in detail
- [transactions.md](transactions.md) - bulk inserts via batch transactions
- [errors.md](errors.md) - handling SQL execution errors
