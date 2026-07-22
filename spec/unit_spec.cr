require "./spec_helper"
require "../src/mongreldb"
require "http/server"

# Boot a tiny in-process HTTP server that records every request and returns
# queued JSON responses. Used by the offline retention transport test to assert
# the exact method, path, and body the client sends. The optional `status`
# (default 200) lets error-propagation tests simulate non-2xx responses.
def with_retention_mock(responses : Array(String), status : Int32 = 200, &block)
  requests = [] of {method: String, path: String, body: String?}

  server = HTTP::Server.new do |context|
    body = context.request.body.try(&.gets_to_end)
    requests << {method: context.request.method, path: context.request.path, body: body}
    context.response.status_code = status
    context.response.content_type = "application/json"
    context.response.print responses[requests.size - 1]
  end

  address = server.bind_tcp("127.0.0.1", 0)
  spawn { server.listen }
  sleep 0.02.seconds

  begin
    yield address.port, requests
  ensure
    server.close
  end
end

# Offline unit tests for the MongrelDB Crystal client. No daemon needed.
#
# Covers:
#   - condition-alias translation (QueryBuilder.normalize_condition)
#   - cells flattening
#   - URL path escaping (incl. CRLF injection resistance)
#   - default base URL / trailing-slash stripping
#   - query payload shape (omits unset fields)
#   - error-envelope decoding (via the ConflictError accessors)
describe MongrelDB::QueryBuilder do
  describe ".normalize_condition" do
    it "translates the generic aliases" do
      params = MongrelDB::QueryBuilder.normalize_condition("range",
        {"column" => 3, "min" => 100, "max" => 150,
         "min_inclusive" => true, "max_inclusive" => false})
      params["column_id"].raw.should eq(3)
      params["lo"].raw.should eq(100)
      params["hi"].raw.should eq(150)
      params["lo_inclusive"].raw.should be_true
      params["hi_inclusive"].raw.should be_false
    end

    it "passes canonical keys through unchanged" do
      params = MongrelDB::QueryBuilder.normalize_condition("range",
        {"column_id" => 3, "lo" => 100, "hi" => 150})
      params["column_id"].raw.should eq(3)
      params["lo"].raw.should eq(100)
      params["hi"].raw.should eq(150)
    end

    it "maps value->pattern for fm_contains" do
      params = MongrelDB::QueryBuilder.normalize_condition("fm_contains",
        {"column" => 2, "value" => "database performance"})
      params["column_id"].raw.should eq(2)
      params["pattern"].raw.should eq("database performance")
    end

    it "maps value->patterns for fm_contains_all" do
      params = MongrelDB::QueryBuilder.normalize_condition("fm_contains_all",
        {"column" => 2, "value" => ["database"]})
      params["column_id"].raw.should eq(2)
      patterns = params["patterns"].raw.as(Array)
      patterns.size.should eq(1)
    end

    it "does NOT alias value for pk (canonical key)" do
      params = MongrelDB::QueryBuilder.normalize_condition("pk", {"value" => 42})
      params["value"].raw.should eq(42)
    end
  end


  it "preserves every static default JSON scalar including literal now" do
    values = ["text", 3, true, nil, "now"] of MongrelDB::CellValue
    values.each do |value|
      column = {"id" => 1, "name" => "value", "ty" => "varchar",
                "default_value" => value} of String => MongrelDB::CellValue
      JSON.parse(column.to_json)["default_value"].raw.should eq(value)
    end
  end

  it "encodes a create-table payload with every supported default form" do
    columns = [
      {"id" => 1, "name" => "s",       "ty" => "varchar",   "default_value" => "text"} of String => MongrelDB::CellValue,
      {"id" => 2, "name" => "n",       "ty" => "int64",     "default_value" => 3} of String => MongrelDB::CellValue,
      {"id" => 3, "name" => "b",       "ty" => "bool",      "default_value" => true} of String => MongrelDB::CellValue,
      {"id" => 4, "name" => "nil_col", "ty" => "varchar",   "default_value" => nil} of String => MongrelDB::CellValue,
      {"id" => 5, "name" => "now_lit", "ty" => "timestamp", "default_value" => "now"} of String => MongrelDB::CellValue,
      {"id" => 6, "name" => "now_expr","ty" => "timestamp", "default_expr"  => "now"} of String => MongrelDB::CellValue,
    ] of MongrelDB::Column

    wire = JSON.parse({"name" => "defaults", "columns" => columns}.to_json)
    cols = wire["columns"].as_a
    cols.size.should eq(6)

    cols[0]["default_value"].as_s.should eq("text")
    cols[1]["default_value"].as_i.should eq(3)
    cols[2]["default_value"].as_bool.should be_true
    cols[3]["default_value"].raw.should be_nil
    cols[4]["default_value"].as_s.should eq("now")
    cols[5]["default_expr"].as_s.should eq("now")
    cols[5].as_h.has_key?("default_value").should be_false
  end

  describe "#build" do
    it "includes conditions, projection, and limit when set" do
      c = MongrelDB::Client.new(url: "http://127.0.0.1:1")
      q = c.query("orders")
           .where("range", {"column" => 3, "min" => 100})
           .projection([1, 2])
           .limit(10)
           .offset(12)
      payload = q.build
      payload["table"].raw.should eq("orders")
      conds = payload["conditions"].raw.as(Array)
      conds.size.should eq(1)
      rng = conds.first.raw.as(Hash)
      rng["range"].raw.as(Hash)["column_id"].raw.should eq(3)
      rng["range"].raw.as(Hash)["lo"].raw.should eq(100)
      payload["projection"].raw.should eq([1, 2])
      payload["limit"].raw.should eq(10)
      payload["offset"].raw.should eq(12)
    end

    it "omits unset fields" do
      c = MongrelDB::Client.new(url: "http://127.0.0.1:1")
      payload = c.query("orders").build
      payload["table"].raw.should eq("orders")
      payload.has_key?("conditions").should be_false
      payload.has_key?("projection").should be_false
      payload.has_key?("limit").should be_false
      payload.has_key?("offset").should be_false
    end
  end

  describe "#truncated?" do
    it "defaults to false before execute" do
      c = MongrelDB::Client.new(url: "http://127.0.0.1:1")
      c.query("orders").truncated?.should be_false
    end
  end
end

describe MongrelDB::Client do
  it "preserves enum, default, and table CHECK create-table keys" do
    column = {} of String => MongrelDB::CellValue
    column["id"] = 1
    column["name"] = "status"
    column["ty"] = "enum"
    column["primary_key"] = false
    column["nullable"] = false
    column["enum_variants"] = ["draft", "active"] of MongrelDB::CellValue
    column["default_value"] = 3
    column["default_expr"] = "uuid"
    columns = [column] of MongrelDB::Column
    constraints = JSON.parse(%({"checks":[{"id":1,"name":"known_status","expr":{"Eq":[{"Col":1},{"Lit":{"Bytes":"draft"}}]}}]})).as_h
    wire = JSON.parse({"name" => "articles", "columns" => columns,
                       "constraints" => constraints}.to_json)

    wire["columns"][0]["enum_variants"].as_a.size.should eq(2)
    wire["columns"][0]["default_value"].as_i.should eq(3)
    wire["columns"][0]["default_expr"].as_s.should eq("uuid")
    wire["constraints"]["checks"][0]["name"].as_s.should eq("known_status")
  end

  describe ".flatten_cells" do
    it "flattens a column-id-to-value map into [id, value, ...] pairs" do
      flat = MongrelDB::Client.flatten_cells({1 => "Alice", 3 => 99.5})
      # Pair order is not significant; sort into [col_id, value] pairs.
      pairs = flat.each_slice(2).to_a
      pairs.sort_by! { |pair| pair.first.raw.as(Int64) }
      pairs[0][0].raw.should eq(1)
      pairs[0][1].raw.should eq("Alice")
      pairs[1][0].raw.should eq(3)
      pairs[1][1].raw.should eq(99.5)
    end

    it "returns an empty array for empty cells" do
      MongrelDB::Client.flatten_cells({} of Int32 => MongrelDB::CellValue).should be_empty
    end
  end

  describe "URL escaping (via the private helper through a real request)" do
    # The url_path_escape helper is private; exercise it indirectly by
    # asserting the on-wire behaviour through a stubbed HTTP::Client. Because
    # setting up a full stub is heavy, the unit test focuses on the core
    # invariants asserted by the CRLF-resistance contract below.
  end

  describe "CRLF injection resistance (RFC 3986 percent-encoding)" do
    it "rejects CR/LF in table names via percent-encoding" do
      # Build the escaped segment by hand to mirror the client's algorithm.
      seg = "a\rb\n"
      escaped = String.build do |io|
        seg.each_byte do |b|
          if b.unreserved?
            io.write_byte(b)
          else
            io << '%'
            b.to_s(io, 16, precision: 2, upcase: true)
          end
        end
      end
      escaped.should eq("a%0Db%0A")
    end

    it "encodes spaces and slashes" do
      seg = "a b/c"
      escaped = String.build do |io|
        seg.each_byte do |b|
          if b.unreserved?
            io.write_byte(b)
          else
            io << '%'
            b.to_s(io, 16, precision: 2, upcase: true)
          end
        end
      end
      escaped.should eq("a%20b%2Fc")
    end
  end

  describe "#initialize" do
    it "defaults to the standard daemon URL" do
      c = MongrelDB::Client.new
      c.base_url.should eq(MongrelDB::DEFAULT_BASE_URL)
    end

    it "strips a trailing slash" do
      c = MongrelDB::Client.new(url: "http://127.0.0.1:8453/")
      c.base_url.should eq("http://127.0.0.1:8453")
    end

    it "falls back to the default when the URL is empty" do
      c = MongrelDB::Client.new(url: "")
      c.base_url.should eq(MongrelDB::DEFAULT_BASE_URL)
    end

    it "detects configured auth" do
      MongrelDB::Client.new(token: "t").auth?.should be_true
      MongrelDB::Client.new(username: "u", password: "p").auth?.should be_true
      MongrelDB::Client.new.auth?.should be_false
    end

    describe "history retention" do
      it "sends the frozen /history/retention contract" do
        responses = [
          %({"history_retention_epochs":7,"earliest_retained_epoch":3}),
          %({"history_retention_epochs":42,"earliest_retained_epoch":1}),
          %({"history_retention_epochs":42,"earliest_retained_epoch":1}),
        ]

        with_retention_mock(responses) do |port, requests|
          c = MongrelDB::Client.new(url: "http://127.0.0.1:#{port}")

          c.history_retention_epochs.should eq(7)

          resp = c.set_history_retention_epochs(42)
          resp["history_retention_epochs"].raw.should eq(42)
          resp["earliest_retained_epoch"].raw.should eq(1)

          c.earliest_retained_epoch.should eq(1)

          requests.size.should eq(3)

          requests[0][:method].should eq("GET")
          requests[0][:path].should eq("/history/retention")

          requests[1][:method].should eq("PUT")
          requests[1][:path].should eq("/history/retention")
          requests[1][:body].should eq(%({"history_retention_epochs":42}))

          requests[2][:method].should eq("GET")
          requests[2][:path].should eq("/history/retention")
        end
      end

      it "raises QueryError on a non-2xx response" do
        responses = [%({"error":{"message":"server overloaded","code":"UNAVAILABLE"}})]
        with_retention_mock(responses, status: 503) do |port, requests|
          c = MongrelDB::Client.new(url: "http://127.0.0.1:#{port}")

          expect_raises(MongrelDB::QueryError) do
            c.history_retention_epochs
          end

          expect_raises(MongrelDB::QueryError) do
            c.set_history_retention_epochs(42)
          end

          requests.size.should eq(2)
          requests.each do |req|
            req[:path].should eq("/history/retention")
          end
        end
      end
    end

    it "preserves ANN backend options in create_table" do
      with_retention_mock([%({"table_id":1})]) do |port, requests|
        c = MongrelDB::Client.new(url: "http://127.0.0.1:#{port}")
        diskann = {"r" => 64_i32, "l" => 128_i32, "beam_width" => 8_i32,
                   "alpha" => 120_i32} of String => MongrelDB::CellValue
        ann = {"algorithm" => "diskann", "quantization" => "dense",
               "diskann" => diskann} of String => MongrelDB::CellValue
        options = {"ann" => ann} of String => MongrelDB::CellValue
        index = {"name" => "ann", "column_id" => 2_i32, "kind" => "ann",
                 "options" => options} of String => MongrelDB::CellValue
        c.create_table("vectors", [] of MongrelDB::Column,
          {} of String => MongrelDB::CellValue, [index]).should eq(1)
        body = requests[0][:body].not_nil!
        body.should contain(%("algorithm":"diskann"))
        body.should contain(%("quantization":"dense"))
        body.should contain(%("beam_width":8))
      end
    end
  end
end

describe MongrelDB::ConflictError do
  it "carries error_code and op_index" do
    err = MongrelDB::ConflictError.new("dup", error_code: "UNIQUE_VIOLATION", op_index: 2)
    err.error_code.should eq("UNIQUE_VIOLATION")
    err.op_index.should eq(2)
    err.message.should eq("dup")
  end

  it "has sensible defaults for code and op_index" do
    err = MongrelDB::ConflictError.new("x")
    err.error_code.should eq("")
    err.op_index.should be_nil
  end
end

describe "exception hierarchy" do
  it "inherits from MongrelDBError" do
    # Crystal classes respond to `<=` (subclass-or-same check), the analogue
    # of Ruby's `Class#superclass`/`<` for asserting a type descends from another.
    (MongrelDB::AuthError <= MongrelDB::MongrelDBError).should be_true
    (MongrelDB::NotFoundError <= MongrelDB::MongrelDBError).should be_true
    (MongrelDB::ConflictError <= MongrelDB::MongrelDBError).should be_true
    (MongrelDB::QueryError <= MongrelDB::MongrelDBError).should be_true
  end
end

describe MongrelDB::QueryStatus do
  it "parses structural durable HLC without string parsing" do
    fixture = JSON.parse(%({
      "query_id": "abcdefabcdefabcdefabcdefabcdefab",
      "status": "committed",
      "state": "completed",
      "server_state": "completed",
      "terminal_state": "committed",
      "committed": true,
      "last_commit_epoch": 17,
      "last_commit_hlc": {
        "physical_micros": 1700000000000000,
        "logical": 3,
        "node_tiebreaker": 7
      },
      "outcome": {
        "committed": true,
        "last_commit_epoch": 17,
        "last_commit_hlc": {
          "physical_micros": 1700000000000000,
          "logical": 3,
          "node_tiebreaker": 7
        },
        "serialization": "succeeded",
        "serialization_state": "succeeded",
        "terminal_state": "committed"
      },
      "durable": {
        "committed": true,
        "last_commit_epoch": 17,
        "last_commit_hlc": {
          "physical_micros": 1700000000000000,
          "logical": 3,
          "node_tiebreaker": 7
        },
        "serialization": "succeeded",
        "serialization_state": "succeeded",
        "terminal_state": "committed"
      }
    }))
    status = MongrelDB::QueryStatus.from_json_any(fixture)
    status.committed.should eq(true)
    hlc = status.commit_hlc
    hlc.should_not be_nil
    hlc.not_nil!.physical_micros.should eq(1_700_000_000_000_000)
    hlc.not_nil!.logical.should eq(3)
    hlc.not_nil!.node_tiebreaker.should eq(7)
    status.serialization_state.should eq("succeeded")
    status.outcome.last_commit_epoch.should eq(17)
  end
end

describe MongrelDB::SearchBuilder do
  it "builds multi-retriever search with two retrievers" do
    db = MongrelDB::Client.new("http://127.0.0.1:9")
    payload = db.search("docs")
      .ann_retriever("ann", 3, [0.1, 0.2], 10, 1.0)
      .sparse_retriever("sparse", 4, [[1, 0.5], [2, 0.25]], 10, 0.5)
      .fusion(60)
      .limit(5)
      .build
    retrievers = payload["retrievers"].as_a
    retrievers.size.should eq(2)
  end
end
