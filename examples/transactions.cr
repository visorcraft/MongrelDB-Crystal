#!/usr/bin/env crystal
#
# Example: atomic batch transactions with the MongrelDB Crystal client.
#
# Run:    crystal run examples/transactions.cr
# Requires: mongreldb-server running on http://127.0.0.1:8453
#
# Creates a table, stages three inserts in a single transaction, commits them
# atomically, verifies the count, then demonstrates idempotent retries by
# re-committing with the same idempotency key (the daemon returns the original
# result and applies no duplicate rows). Cleans up by dropping the table.

require "../src/mongreldb"

URL = "http://127.0.0.1:8453"
# Unique suffix per run so repeated/concurrent runs don't collide.
SUFFIX = "#{Time.utc.to_unix}_#{Random::Secure.hex(4)}"
TABLE = "example_txn_#{SUFFIX}"
# Idempotency key must be unique per run so retry logic isn't confused with a
# previous run's committed batch.
IDEMPOTENCY_KEY = "example-txn-#{SUFFIX}"

db = MongrelDB::Client.new(url: URL)

unless db.health
  STDERR.puts "daemon not reachable at #{URL}"
  exit 1
end
puts "Connected to MongrelDB"

begin
  db.create_table(TABLE, [
    {"id" => 1, "name" => "id", "ty" => "int64", "primary_key" => true, "nullable" => false},
    {"id" => 2, "name" => "name", "ty" => "varchar", "primary_key" => false, "nullable" => false},
    {"id" => 3, "name" => "score", "ty" => "float64", "primary_key" => false, "nullable" => false},
  ])
  puts "Created table #{TABLE}"

  # Stage three puts and commit them atomically. Either every op lands or none
  # do; a constraint violation rolls back the whole batch.
  txn = db.begin_transaction
  txn.put(TABLE, {1 => 1, 2 => "Alice", 3 => 95.5})
  txn.put(TABLE, {1 => 2, 2 => "Bob", 3 => 82.0})
  txn.put(TABLE, {1 => 3, 2 => "Carol", 3 => 78.3})
  puts "Staged #{txn.count} operations"

  results = txn.commit
  puts "Committed atomically: #{results.size} operations applied"

  puts "Verified row count after commit: #{db.count(TABLE)}"

  # Idempotent retry: stage the same batch again with an idempotency key, then
  # commit a second time with the SAME key. The daemon replays the original
  # result and applies no extra rows.
  retry_txn = db.begin_transaction
  retry_txn.put(TABLE, {1 => 4, 2 => "Dave", 3 => 60.0})
  retry_txn.commit(idempotency_key: IDEMPOTENCY_KEY)
  puts "After first idempotent commit: #{db.count(TABLE)} rows"

  retry2 = db.begin_transaction
  retry2.put(TABLE, {1 => 4, 2 => "Dave", 3 => 60.0})
  retry2.commit(idempotency_key: IDEMPOTENCY_KEY)
  puts "After duplicate idempotent commit (same key): #{db.count(TABLE)} rows (no double-apply)"
ensure
  # Always drop the table, even if an earlier step raised.
  (db.drop_table(TABLE) rescue nil)
  puts "Dropped table #{TABLE}"
end
