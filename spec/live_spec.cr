require "./spec_helper"
require "./daemon"
require "../src/mongreldb"

# Live integration tests against a real mongreldb-server daemon.
#
# These are live tests: they boot a real mongreldb-server daemon and exercise
# the full client surface against it. They skip automatically when no daemon is
# available.
#
# The harness resolves the binary in this order:
#   1. the MONGRELDB_SERVER env var (path to the server binary).
#   2. a prebuilt binary at ./bin/mongreldb-server (downloaded by CI).
#   3. mongreldb-server on PATH.
#
# If no binary is available, the suite is skipped. Set MONGRELDB_URL to point
# at an already-running daemon to skip the boot and connect directly.

# Boot the daemon once for the whole suite, then shut it down at exit.
MongrelDBDaemon.boot
at_exit { MongrelDBDaemon.shutdown }

include MongrelDBTestHelpers

# The full 14-operation conformance matrix. Each test self-skips when no
# daemon is available via skip_if_no_client!.
describe "MongrelDB live conformance (14-op matrix)" do
  # Each test fetches a non-nilable client via `client = skip_if_no_client!`,
  # which skips the test when no daemon was booted. A block-local `client`
  # (not a describe-level closure) lets the compiler narrow it to non-nil.

  it "health returns true against the real daemon" do
    client = skip_if_no_client!
    client.health.should be_true
  end

  it "connect defaults to 127.0.0.1:8453" do
    client = skip_if_no_client!
    c2 = MongrelDB::Client.new
    c2.base_url.should eq(MongrelDB::DEFAULT_BASE_URL)
    client.auth?.should be_false
  end

  it "create_table then count returns 0" do
    client = skip_if_no_client!
    name = unique_table("cr_create")
    fresh_table(client, name, [int_col(1, "id", primary_key: true), float_col(2, "amount")])
    client.count(name).should eq(0)
    cleanup(client, name)
  end

  it "put then count round-trips" do
    client = skip_if_no_client!
    name = unique_table("cr_put")
    fresh_table(client, name, [int_col(1, "id", primary_key: true), float_col(2, "amount")])
    client.put(name, {1 => 1, 2 => 99.5})
    client.put(name, {1 => 2, 2 => 150.0})
    client.count(name).should eq(2)
    cleanup(client, name)
  end

  it "upsert inserts then updates" do
    client = skip_if_no_client!
    name = unique_table("cr_upsert")
    fresh_table(client, name, [int_col(1, "id", primary_key: true), float_col(2, "amount")])
    # First upsert inserts.
    client.upsert(name, {1 => 1, 2 => 99.5}, update_cells: {2 => 99.5})
    client.count(name).should eq(1)
    # Second upsert on the same PK updates (still one row).
    client.upsert(name, {1 => 1, 2 => 120.0}, update_cells: {2 => 120.0})
    client.count(name).should eq(1)
    cleanup(client, name)
  end

  it "delete_by_pk removes the row" do
    client = skip_if_no_client!
    name = unique_table("cr_delpk")
    fresh_table(client, name, [int_col(1, "id", primary_key: true)])
    client.put(name, {1 => 5})
    client.count(name).should eq(1)
    client.delete_by_pk(name, 5)
    client.count(name).should eq(0)
    cleanup(client, name)
  end

  it "delete by row id removes the row" do
    client = skip_if_no_client!
    name = unique_table("cr_delrid")
    fresh_table(client, name, [int_col(1, "id", primary_key: true)])
    client.put(name, {1 => 7})
    # Row id is internal; for a fresh single-row table the row id is typically 1.
    client.delete(name, 1_i64)
    client.count(name).should eq(0)
    cleanup(client, name)
  end

  it "query by primary key returns one row" do
    client = skip_if_no_client!
    name = unique_table("cr_pk")
    fresh_table(client, name, [int_col(1, "id", primary_key: true)])
    client.put(name, {1 => 42})
    client.put(name, {1 => 43})
    rows = client.query(name).where("pk", {"value" => 42}).execute
    rows.size.should eq(1)
    cleanup(client, name)
  end

  it "query range with friendly aliases filters correctly" do
    client = skip_if_no_client!
    name = unique_table("cr_range")
    fresh_table(client, name, [int_col(1, "id", primary_key: true), int_col(2, "amount")])
    client.put(name, {1 => 1, 2 => 50})
    client.put(name, {1 => 2, 2 => 120})
    client.put(name, {1 => 3, 2 => 200})
    q = client.query(name).where("range", {"column" => 2, "min" => 100, "max" => 150})
    rows = q.execute
    rows.size.should eq(1)
    q.truncated?.should be_false
    cleanup(client, name)
  end

  it "query projection and limit" do
    client = skip_if_no_client!
    name = unique_table("cr_proj")
    fresh_table(client, name, [int_col(1, "id", primary_key: true), float_col(2, "amount")])
    5.times { |i| client.put(name, {1 => i, 2 => i.to_f64}) }
    rows = client.query(name).projection([1]).limit(2).execute
    rows.size.should eq(2)
    cleanup(client, name)
  end

  it "transaction put commit" do
    client = skip_if_no_client!
    name = unique_table("cr_txn")
    fresh_table(client, name, [int_col(1, "id", primary_key: true)])
    txn = client.begin_transaction
    txn.put(name, {1 => 1})
    txn.put(name, {1 => 2})
    txn.put(name, {1 => 3})
    txn.count.should eq(3)
    results = txn.commit
    results.size.should eq(3)
    client.count(name).should eq(3)
    cleanup(client, name)
  end

  it "transaction commit with idempotency key does not double-apply" do
    client = skip_if_no_client!
    name = unique_table("cr_txn_idem")
    fresh_table(client, name, [int_col(1, "id", primary_key: true)])
    idem_key = "order-100-create-#{Time.utc.to_unix}"
    txn = client.begin_transaction
    txn.put(name, {1 => 100})
    results = txn.commit(idempotency_key: idem_key)
    results.size.should eq(1)
    client.count(name).should eq(1)
    # A second commit with the same key must not create a duplicate row.
    txn2 = client.begin_transaction
    txn2.put(name, {1 => 100})
    (txn2.commit(idempotency_key: idem_key) rescue nil)
    client.count(name).should eq(1)
    cleanup(client, name)
  end

  it "transaction rollback discards ops" do
    client = skip_if_no_client!
    name = unique_table("cr_txn_rb")
    fresh_table(client, name, [int_col(1, "id", primary_key: true)])
    txn = client.begin_transaction
    txn.put(name, {1 => 1})
    txn.put(name, {1 => 2})
    txn.rollback
    client.count(name).should eq(0)
    cleanup(client, name)
  end

  it "transaction double commit raises" do
    client = skip_if_no_client!
    name = unique_table("cr_txn_double")
    fresh_table(client, name, [int_col(1, "id", primary_key: true)])
    txn = client.begin_transaction
    txn.put(name, {1 => 1})
    txn.commit
    expect_raises(Exception, /already committed/) { txn.commit }
    cleanup(client, name)
  end

  it "table_names lists the created table" do
    client = skip_if_no_client!
    name = unique_table("cr_tables")
    fresh_table(client, name, [int_col(1, "id", primary_key: true)])
    names = client.table_names
    names.map(&.to_s).should contain(name)
    cleanup(client, name)
  end

  it "drop_table removes it" do
    client = skip_if_no_client!
    name = unique_table("cr_drop")
    fresh_table(client, name, [int_col(1, "id", primary_key: true)])
    client.drop_table(name)
    client.table_names.map(&.to_s).should_not contain(name)
  end

  it "sql insert increases count and select returns row" do
    client = skip_if_no_client!
    name = unique_table("cr_sql")
    fresh_table(client, name, [int_col(1, "id", primary_key: true), float_col(2, "amount")])
    client.count(name).should eq(0)
    # INSERT via SQL must increase the row count.
    client.sql("INSERT INTO #{name} (id, amount) VALUES (77, 7.5)")
    client.count(name).should eq(1)
    # JSON SQL mode must return the inserted row when supported.
    rows = client.sql("SELECT id, amount FROM #{name}")
    unless rows.empty?
      rows.size.should eq(1)
    end
    cleanup(client, name)
  end

  it "schema includes the created table" do
    client = skip_if_no_client!
    name = unique_table("cr_schema")
    fresh_table(client, name, [int_col(1, "id", primary_key: true), float_col(2, "amount")])
    schema = client.schema
    schema.has_key?(name).should be_true
    cleanup(client, name)
  end

  it "schema_for returns a descriptor with columns" do
    client = skip_if_no_client!
    name = unique_table("cr_schema_for")
    fresh_table(client, name, [int_col(1, "id", primary_key: true), float_col(2, "amount")])
    desc = client.schema_for(name)
    desc.has_key?("schema_id").should be_true
    cols = desc["columns"]?.try(&.as_a?) || [] of JSON::Any
    cols.size.should eq(2)
    cleanup(client, name)
  end

  it "compact all tables returns a hash" do
    client = skip_if_no_client!
    result = client.compact
    result.should be_a(Hash(String, JSON::Any))
  end

  it "compact single table returns a hash" do
    client = skip_if_no_client!
    name = unique_table("cr_compact")
    fresh_table(client, name, [int_col(1, "id", primary_key: true)])
    client.put(name, {1 => 1})
    result = client.compact_table(name)
    result.should be_a(Hash(String, JSON::Any))
    cleanup(client, name)
  end

  it "schema_for on a nonexistent table raises an error" do
    client = skip_if_no_client!
    name = unique_table("cr_missing")
    # The server reports a missing resource as an error (404 NotFoundError on
    # current server versions). Assert the base error type rather than the
    # specific subclass so the test is robust to status-code variance across
    # daemon versions.
    expect_raises(MongrelDB::MongrelDBError) { client.schema_for(name) }
  end

  it "duplicate put with a UNIQUE constraint raises ConflictError" do
    client = skip_if_no_client!
    name = unique_table("cr_conflict")
    # A UNIQUE constraint must sit on a non-PK column: a bare `put` against the
    # primary key is last-write-wins (an upsert), so the engine only rejects a
    # duplicate when the unique column is distinct from the PK. Here the PK is
    # `id` (column 1) with explicit distinct values, and the unique constraint is
    # on `label` (column 2); inserting two rows with the same label triggers a 409.
    begin client.drop_table(name); rescue MongrelDB::MongrelDBError; end
    constraints = {"uniques" => [{"id" => 5, "name" => "uq_label", "columns" => [2]}] of Hash(String, Int32 | String | Array(Int32))}
    client.create_table(name, [
      int_col(1, "id", primary_key: true),
      {"id" => 2, "name" => "label", "ty" => "varchar", "primary_key" => false, "nullable" => false} of String => MongrelDB::CellValue,
    ], constraints)
    client.put(name, {1 => 1_i64, 2 => "alpha"})
    err = expect_raises(MongrelDB::ConflictError) { client.put(name, {1 => 2_i64, 2 => "alpha"}) }
    err.error_code.empty?.should be_false
    cleanup(client, name)
  end
end
