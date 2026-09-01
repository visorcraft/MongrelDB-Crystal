# Pure Crystal HTTP client for a running `mongreldb-server` daemon.
#
# Talks to the daemon's JSON API over the standard-library `HTTP::Client` --
# no external shards are required. The API mirrors the MongrelDB PHP, Go, Ruby,
# and Java clients: typed CRUD over the Kit transaction endpoint, a fluent
# query builder that pushes conditions down to the engine's native indexes,
# idempotent batch transactions, full SQL access, schema introspection, and
# maintenance operations.

# Standard-library prelude. These modules define the types the client relies on
# (JSON::Any, JSON.parse, HTTP::Client, Base64, URI, OpenSSL, ...). The Crystal
# prelude does not auto-require them, so load them explicitly before the file
# references them.
require "json"
require "http/client"
require "base64"
#
# Connect with a base URL and optional credentials:
#
# ```
# db = MongrelDB::Client.new(url: "http://127.0.0.1:8453")
# db.health # => true
# ```
#
# See https://www.MongrelDB.com for the daemon and full documentation.
module MongrelDB
  VERSION = "0.64.17"

  # Default daemon address used when none is supplied.
  DEFAULT_BASE_URL = "http://127.0.0.1:8453"

  # Maximum response body size (256 MB). Bodies larger than this are aborted
  # with a `QueryError` to guard client memory against a malicious or buggy
  # server.
  MAX_RESPONSE_BYTES = 268_435_456

  # Base class for every error raised by the client. Rescue this to catch any
  # MongrelDB failure (network, auth, not-found, conflict, query).
  class MongrelDBError < Exception
  end

  # Raised for HTTP 401 or 403 responses -- bad or missing credentials.
  class AuthError < MongrelDBError
  end

  # Raised for HTTP 404 responses -- a missing table, schema, or resource.
  class NotFoundError < MongrelDBError
  end

  # Raised for HTTP 409 responses -- a unique, foreign-key, check, or trigger
  # constraint violation. Carries the server's structured error code (e.g.
  # `UNIQUE_VIOLATION`) and, when the daemon reports one, the index of the
  # offending operation within the transaction.
  class ConflictError < MongrelDBError
    # The server's structured error code, when present (e.g.
    # `UNIQUE_VIOLATION`, `FK_VIOLATION`). Empty string when the server did
    # not supply one.
    getter error_code : String

    # The index of the offending operation within a transaction commit, when
    # the daemon reports one. `nil` otherwise.
    getter op_index : Int32?

    def initialize(message : String, @error_code : String = "", @op_index : Int32? = nil)
      super(message)
    end
  end

  # Raised for HTTP 400 and 5xx responses, and for any request-level failure
  # not covered by the more specific errors (including network/encoding
  # problems).
  class QueryError < MongrelDBError
  end

  # Structural HLC from durable recovery (0.64+).
  struct CommitHlc
    getter physical_micros : Int64
    getter logical : Int32
    getter node_tiebreaker : Int32

    def initialize(@physical_micros : Int64, @logical : Int32 = 0, @node_tiebreaker : Int32 = 0)
    end

    def self.from_json_any(raw : JSON::Any?) : CommitHlc?
      return nil if raw.nil?
      h = raw.as_h?
      return nil if h.nil?
      phys = h["physical_micros"]?
      return nil if phys.nil?
      logical = h["logical"]?.try(&.as_i?) || 0
      node = h["node_tiebreaker"]?.try(&.as_i?) || 0
      CommitHlc.new(phys.as_i64, logical.to_i32, node.to_i32)
    rescue
      nil
    end
  end

  # Nested durable recovery payload.
  struct DurableOutcome
    getter committed : Bool?
    getter last_commit_epoch : Int64?
    getter last_commit_hlc : CommitHlc?
    getter serialization : String
    getter serialization_state : String?
    getter terminal_state : String?

    def initialize(
      @committed : Bool? = nil,
      @last_commit_epoch : Int64? = nil,
      @last_commit_hlc : CommitHlc? = nil,
      @serialization : String = "",
      @serialization_state : String? = nil,
      @terminal_state : String? = nil
    )
    end

    def self.from_json_any(raw : JSON::Any?) : DurableOutcome
      h = raw.try(&.as_h?) || {} of String => JSON::Any
      committed = h["committed"]?.try(&.as_bool?)
      epoch = h["last_commit_epoch"]?.try(&.as_i64?)
      ser = h["serialization"]?.try(&.as_s?) || ""
      ser_state = h["serialization_state"]?.try(&.as_s?)
      term = h["terminal_state"]?.try(&.as_s?)
      DurableOutcome.new(
        committed,
        epoch,
        CommitHlc.from_json_any(h["last_commit_hlc"]?),
        ser,
        ser_state,
        term
      )
    end
  end

  # GET /queries/{query_id} decoded status for durable recovery.
  class QueryStatus
    getter query_id : String
    getter status : String
    getter state : String
    getter server_state : String
    getter terminal_state : String?
    getter committed : Bool?
    getter last_commit_epoch : Int64?
    getter last_commit_hlc : CommitHlc?
    getter outcome : DurableOutcome
    getter durable : DurableOutcome?
    getter raw : Hash(String, JSON::Any)

    def initialize(raw : Hash(String, JSON::Any))
      @raw = raw
      @query_id = raw["query_id"]?.try(&.as_s?) || ""
      @status = raw["status"]?.try(&.as_s?) || ""
      @state = raw["state"]?.try(&.as_s?) || ""
      @server_state = raw["server_state"]?.try(&.as_s?) || @state
      @terminal_state = raw["terminal_state"]?.try(&.as_s?)
      @committed = raw["committed"]?.try(&.as_bool?)
      @last_commit_epoch = raw["last_commit_epoch"]?.try(&.as_i64?)
      @last_commit_hlc = CommitHlc.from_json_any(raw["last_commit_hlc"]?)
      @outcome = DurableOutcome.from_json_any(raw["outcome"]?)
      durable_raw = raw["durable"]?
      @durable = durable_raw.try { |d| DurableOutcome.from_json_any(d) }
    end

    def self.from_json_any(raw : JSON::Any) : QueryStatus
      h = raw.as_h? || {} of String => JSON::Any
      new(h)
    end

    # Authoritative HLC: durable → outcome → top-level.
    def commit_hlc : CommitHlc?
      if d = @durable
        return d.last_commit_hlc if d.last_commit_hlc
      end
      return @outcome.last_commit_hlc if @outcome.last_commit_hlc
      @last_commit_hlc
    end

    def serialization_state : String
      if d = @durable
        return d.serialization_state.not_nil! if d.serialization_state && !d.serialization_state.not_nil!.empty?
        return d.serialization if !d.serialization.empty?
      end
      if @outcome.serialization_state && !@outcome.serialization_state.not_nil!.empty?
        return @outcome.serialization_state.not_nil!
      end
      @outcome.serialization
    end
  end

  # Response wraps one HTTP response from the daemon. It exposes the raw
  # status code and body and a `json` helper for decoding a JSON body.
  struct Response
    # The HTTP status code.
    getter status : Int32
    # The raw response body (may be empty).
    getter body : String

    def initialize(@status : Int32, @body : String = "")
    end

    # Parse the response body as JSON and return the decoded value (Hash,
    # Array, String, Int64, ...). Returns `nil` for an empty body. Raises
    # `QueryError` if the body is not valid JSON.
    def json
      return nil if body.nil? || body.empty?
      JSON.parse(body)
    rescue ex : JSON::ParseException
      raise QueryError.new("Failed to decode JSON response: #{ex.message}")
    end

    # True when the HTTP status is in the 2xx success range.
    def success? : Bool
      status && status >= 200 && status < 300
    end
  end

  # Client is the MongrelDB HTTP client. Create one with `Client.new` and a
  # base URL, then use its methods for health, table management, CRUD, query,
  # SQL, schema, and maintenance.
  #
  # A Client is safe for concurrent use by multiple fibers once configured --
  # each request builds its own `HTTP::Client`.
  class Client
    # The daemon base URL the client was configured with (no trailing slash).
    getter base_url : String

    @token : String?
    @username : String?
    @password : String?
    @connect_timeout : Float64
    @read_timeout : Float64

    # Create a new MongrelDB client.
    #
    # - `url` - daemon base URL (e.g. `http://127.0.0.1:8453`). Defaults to
    #   `DEFAULT_BASE_URL` when empty.
    # - `token` - bearer token (`--auth-token` mode). Takes precedence over
    #   basic-auth credentials when set.
    # - `username` / `password` - basic auth (`--auth-users` mode).
    # - `connect_timeout` - seconds to wait for the connection to open.
    # - `read_timeout` - seconds to wait for one block of the response body.
    def initialize(url : String = DEFAULT_BASE_URL, @token : String? = nil,
                   @username : String? = nil, @password : String? = nil,
                   @connect_timeout : Float64 = 30.0, @read_timeout : Float64 = 60.0)
      @base_url = url.nil? || url.empty? ? DEFAULT_BASE_URL : url.to_s
      @base_url = @base_url.gsub(/\/$/, "")
    end

    # True when a bearer token or basic-auth username is configured.
    def auth? : Bool
      !@token.nil? || !@username.nil?
    end

    # ── Health & tables ────────────────────────────────────────────────────

    # Check whether the daemon is reachable and healthy. Returns `true` on a
    # successful `/health` request, `false` on any error.
    def health : Bool
      get("/health")
      true
    rescue ex : MongrelDBError
      false
    end

    # List all table names in the database (empty array when none).
    def table_names : Array(JSON::Any)
      data = get("/tables").json
      data.try(&.as_a?) || [] of JSON::Any
    end

    # Inspect the durable MVCC history window. Returns both
    # `history_retention_epochs` and `earliest_retained_epoch`.
    def history_retention : Hash(String, JSON::Any)
      data = get("/history/retention").json
      (data.try(&.as_h?) || {} of String => JSON::Any)
    end

    # Current number of commit epochs the daemon will retain for time travel.
    def history_retention_epochs : Int64
      n = history_retention["history_retention_epochs"]?.try(&.as_i64?)
      raise QueryError.new("malformed history retention response from server") unless n
      n
    end

    # The oldest epoch still available for `AS OF EPOCH` queries.
    def earliest_retained_epoch : Int64
      n = history_retention["earliest_retained_epoch"]?.try(&.as_i64?)
      raise QueryError.new("malformed history retention response from server") unless n
      n
    end

    # Set the durable MVCC history window. Requires ADMIN permission when the
    # daemon runs with catalog authentication. Returns the post-update window.
    def set_history_retention_epochs(epochs : Int) : Hash(String, JSON::Any)
      data = put("/history/retention", {"history_retention_epochs" => epochs}).json
      (data.try(&.as_h?) || {} of String => JSON::Any)
    end

    # Create a table with typed columns. Returns the assigned table id.
    def create_table(name : String, columns : Array(Column)) : Int64
      body = {"name" => name, "columns" => columns}
      data = post("/kit/create_table", body).json
      (data.try(&.["table_id"]?).try(&.as_i64?) || 0_i64)
    end

    # Create a table with a `constraints` block (uniques, foreign keys).
    def create_table(name : String, columns : Array(Column), constraints : Hash) : Int64
      body = {"name" => name, "columns" => columns, "constraints" => constraints}
      data = post("/kit/create_table", body).json
      (data.try(&.["table_id"]?).try(&.as_i64?) || 0_i64)
    end

    # Create a table with constraints and full secondary-index definitions.
    def create_table(name : String, columns : Array(Column), constraints : Hash,
                     indexes : Array(Index)) : Int64
      body = {"name" => name, "columns" => columns,
              "constraints" => constraints, "indexes" => indexes}
      data = post("/kit/create_table", body).json
      (data.try(&.["table_id"]?).try(&.as_i64?) || 0_i64)
    end

    # Drop a table by name.
    def drop_table(name : String) : Nil
      http_delete("/tables/#{url_path_escape(name)}")
      nil
    end

    # Get the row count for a table.
    def count(table : String) : Int64
      data = get("/tables/#{url_path_escape(table)}/count").json
      n = data.try(&.["count"]?).try(&.as_i64?)
      raise QueryError.new("malformed count response from server") unless n
      n
    end

    # ── CRUD (via the Kit typed transaction endpoint) ──────────────────────

    # Insert a row.
    #
    # - `table` - table name.
    # - `cells` - column id -> value pairs (e.g. `{1 => 1, 2 => "Alice"}`).
    #   Flattened to the server's `[col_id, value, ...]` array before sending.
    # - `idempotency_key` - when non-empty, makes the commit safe to retry.
    def put(table : String, cells : Cells, idempotency_key : String? = nil) : Hash(String, JSON::Any)
      inner = {} of String => JSON::Any
      inner["table"] = JSON::Any.new(table)
      inner["cells"] = JSON::Any.new(Client.flatten_cells(cells))
      results = commit_one([{"put" => JSON::Any.new(inner)}], idempotency_key)
      results.first? || {} of String => JSON::Any
    end

    # Upsert a row (insert or update on a primary-key conflict).
    #
    # - `update_cells` - values written on a primary-key conflict (`nil` means
    #   DO NOTHING).
    # - `idempotency_key` - idempotency key for safe retries.
    def upsert(table : String, cells : Cells, update_cells : Cells? = nil,
               idempotency_key : String? = nil) : Hash(String, JSON::Any)
      inner = {} of String => JSON::Any
      inner["table"] = JSON::Any.new(table)
      inner["cells"] = JSON::Any.new(Client.flatten_cells(cells))
      if uc = update_cells
        inner["update_cells"] = JSON::Any.new(Client.flatten_cells(uc))
      end
      results = commit_one([{"upsert" => JSON::Any.new(inner)}], idempotency_key)
      results.first? || {} of String => JSON::Any
    end

    # Delete a row by its internal row id.
    def delete(table : String, row_id : Int64) : Nil
      inner = {} of String => JSON::Any
      inner["table"] = JSON::Any.new(table)
      inner["row_id"] = JSON::Any.new(row_id)
      commit_one([{"delete" => JSON::Any.new(inner)}], nil)
      nil
    end

    # Delete a row by its primary-key value.
    def delete_by_pk(table : String, pk : CellValue) : Nil
      inner = {} of String => JSON::Any
      inner["table"] = JSON::Any.new(table)
      inner["pk"] = Client.to_any(pk)
      commit_one([{"delete_by_pk" => JSON::Any.new(inner)}], nil)
      nil
    end

    # ── Query ──────────────────────────────────────────────────────────────

    # Start a fluent `QueryBuilder` against `table`.
    def query(table : String) : QueryBuilder
      QueryBuilder.new(self, table)
    end

    # Start a hybrid `SearchBuilder` against `table` (POST /kit/search).
    def search(table : String) : SearchBuilder
      SearchBuilder.new(self, table)
    end

    # Text → embed → ANN retrieve (POST /kit/retrieve_text, 0.64+).
    def retrieve_text(table : String, embedding_column : Int32, text : String,
                      k : Int32? = nil, deadline_ms : Int64? = nil, max_work : Int64? = nil) : Hash(String, JSON::Any)
      raise QueryError.new("table is required") if table.empty?
      raise QueryError.new("text is required") if text.empty?
      payload = {} of String => JSON::Any
      payload["table"] = JSON::Any.new(table)
      payload["embedding_column"] = JSON::Any.new(embedding_column.to_i64)
      payload["text"] = JSON::Any.new(text)
      payload["k"] = JSON::Any.new(k.to_i64) if k
      payload["deadline_ms"] = JSON::Any.new(deadline_ms.not_nil!) if deadline_ms
      payload["max_work"] = JSON::Any.new(max_work.not_nil!) if max_work
      data = post("/kit/retrieve_text", payload).json
      h = data.try(&.as_h?) || {} of String => JSON::Any
      h["hits"] = JSON::Any.new([] of JSON::Any) unless h.has_key?("hits")
      h["provenance"] = JSON::Any.new({} of String => JSON::Any) unless h.has_key?("provenance")
      h
    end

    # Retained SQL status for durable recovery (GET /queries/{query_id}).
    def query_status(query_id : String) : QueryStatus
      raise QueryError.new("query_id is required") if query_id.empty?
      data = get("/queries/#{url_path_escape(query_id)}").json
      raise QueryError.new("query status response was not a JSON object") unless data
      QueryStatus.from_json_any(data)
    end

    # Request cancellation of a running SQL query.
    def cancel_query(query_id : String) : Hash(String, JSON::Any)
      raise QueryError.new("query_id is required") if query_id.empty?
      data = post("/queries/#{url_path_escape(query_id)}/cancel", {} of String => JSON::Any).json
      data.try(&.as_h?) || {} of String => JSON::Any
    end

    # ── SQL ────────────────────────────────────────────────────────────────

    # Execute a SQL statement via the `/sql` endpoint, requesting JSON output.
    # The server returns a JSON array of row objects keyed by column name. For
    # statements that yield no rows (DDL/DML), an empty array is returned.
    def sql(sql : String) : Array(JSON::Any)
      response = post("/sql", {"sql" => sql, "format" => "json"})
      body = response.body
      return [] of JSON::Any if body.blank?
      parsed = JSON.parse(body)
      parsed.as_a? || [] of JSON::Any
    rescue ex : JSON::ParseException
      [] of JSON::Any
    end

    # ── Schema ─────────────────────────────────────────────────────────────

    # Get the full schema catalog (table name -> descriptor).
    def schema : Hash(String, JSON::Any)
      data = get("/kit/schema").json
      (data.try(&.["tables"]?).try(&.as_h?) || {} of String => JSON::Any)
    end

    # Get the descriptor for a single table.
    def schema_for(table : String) : Hash(String, JSON::Any)
      data = get("/kit/schema/#{url_path_escape(table)}").json
      (data.try(&.as_h?) || {} of String => JSON::Any)
    end

    # ── Maintenance ────────────────────────────────────────────────────────

    # Compact (merge sorted runs) across all tables.
    def compact : Hash(String, JSON::Any)
      post_decode("/compact")
    end

    # Compact a single table.
    def compact_table(name : String) : Hash(String, JSON::Any)
      post_decode("/tables/#{url_path_escape(name)}/compact")
    end

    # ── Transactions ───────────────────────────────────────────────────────

    # Begin a batch transaction. Operations are staged locally and committed
    # atomically in a single `/kit/txn` request.
    def begin_transaction : Transaction
      Transaction.new(self)
    end

    # Commit a batch of staged operations atomically. Exposed for the
    # `Transaction` type; prefer `Transaction#commit`.
    def commit_txn(ops : Array, idempotency_key : String? = nil) : Array(Hash(String, JSON::Any))
      return [] of Hash(String, JSON::Any) if ops.empty?

      payload = {} of String => JSON::Any
      payload["ops"] = JSON::Any.new(ops.map { |op| JSON::Any.new(op) })
      unless idempotency_key.nil? || idempotency_key.empty?
        payload["idempotency_key"] = JSON::Any.new(idempotency_key)
      end
      decode_results(post("/kit/txn", payload).body)
    end

    # ── Low-level HTTP ─────────────────────────────────────────────────────
    #
    # These are public so that `Transaction` and `QueryBuilder` can share the
    # transport, and so callers can reach endpoints the convenience methods do
    # not yet cover.

    # Perform a GET request and return the `Response`, mapping HTTP errors to
    # typed exceptions.
    def get(path : String) : Response
      request("GET", path, nil)
    end

    # Perform a POST request with a JSON body (Content-Type: application/json)
    # and return the `Response`. A `nil` body sends an empty request.
    def post(path : String, body = nil) : Response
      request("POST", path, body)
    end

    def put(path : String, body) : Response
      request("PUT", path, body)
    end

    # Perform a DELETE request and return the `Response`.
    # (Named `http_delete` to avoid clobbering the typed CRUD method
    # `delete(table, row_id)` defined above.)
    def http_delete(path : String) : Response
      request("DELETE", path, nil)
    end

    # ── Shared helpers ─────────────────────────────────────────────────────
    #
    # Public so `Transaction` and `QueryBuilder` can flatten cells and decode
    # transaction results without duplicating logic.

    # Convert a column-id-to-value map to the server's flat
    # `[col_id, value, col_id, value, ...]` array. Pair order is not
    # significant -- each value is preceded by its own column id.
    # Flatten a column-id-to-value map to the server's flat
    # `[col_id, value, ...]` array in ascending column-id order.
    # Stable ordering is required for idempotency keys: the server hashes the
    # request payload, and unordered hash iteration would make two commits of
    # the same cells look like a reuse mismatch.
    def self.flatten_cells(cells : Cells) : Array(JSON::Any)
      flat = [] of JSON::Any
      cells.keys.sort.each do |col_id|
        flat << JSON::Any.new(col_id.to_i64)
        flat << to_any(cells[col_id])
      end
      flat
    end

    # Coerce a Crystal value into a `JSON::Any` for the request payload.
    #
    # Accepts the native Crystal scalars and containers callers pass in (from
    # `Cells`/`Column` values as well as ad-hoc query-parameter literals).
    # Generic `Array` and `Hash` literals (e.g. `["a", "b"]` typed as
    # `Array(String)`) are coerced element-wise so callers do not have to widen
    # them to `Array(CellValue)` themselves.
    def self.to_any(value) : JSON::Any
      case value
      when Int64                     then JSON::Any.new(value)
      when Int32                     then JSON::Any.new(value.to_i64)
      when Float64                   then JSON::Any.new(value)
      when Float32                   then JSON::Any.new(value.to_f64)
      when Bool                      then JSON::Any.new(value)
      when String                    then JSON::Any.new(value)
      when Nil                       then JSON::Any.new(nil)
      when Array                     then JSON::Any.new(value.map { |v| to_any(v) })
      when Hash                      then JSON::Any.new(value.transform_values { |v| to_any(v) })
      else                                JSON::Any.new(value.to_s)
      end
    end

    # ── Internal helpers ───────────────────────────────────────────────────

    private def request(method : String, path : String, body)
      uri = URI.parse(uri_for(path))
      client = HTTP::Client.new(uri)
      client.connect_timeout = @connect_timeout
      client.read_timeout = @read_timeout

      headers = HTTP::Headers.new
      headers["Accept"] = "application/json"

      request_body : String? = nil
      unless body.nil?
        request_body = encode_json(body)
        headers["Content-Type"] = "application/json"
      end

      apply_auth(headers)

      response = begin
        case method
        when "GET"    then client.get(uri.request_target, headers)
        when "POST"   then client.post(uri.request_target, headers: headers, body: request_body)
        when "PUT"    then client.put(uri.request_target, headers: headers, body: request_body)
        when "DELETE" then client.delete(uri.request_target, headers)
        else               raise QueryError.new("unsupported HTTP method: #{method}")
        end
      rescue ex : IO::Error | Socket::Error | OpenSSL::SSL::Error
        raise QueryError.new("request #{path} failed: #{ex.message}")
      end

      if response.body.bytesize > MAX_RESPONSE_BYTES
        raise QueryError.new("Response body exceeds maximum size of #{MAX_RESPONSE_BYTES} bytes")
      end

      resp = Response.new(response.status_code.to_i, response.body)
      return resp if resp.success?

      throw_for_status(resp.status, resp.body)
    end

    # Set the Authorization header according to the configured credentials. A
    # bearer token takes precedence over basic auth.
    private def apply_auth(headers : HTTP::Headers) : Nil
      if token = @token
        headers["Authorization"] = "Bearer #{token}"
      elsif username = @username
        password = @password || ""
        creds = Base64.encode("#{username}:#{password}").strip
        headers["Authorization"] = "Basic #{creds}"
      end
    end

    # JSON-encode a request body. Raises `QueryError` for values with no JSON
    # representation (NaN, Infinity, recursive structures).
    private def encode_json(data) : String
      JSON.build do |json|
        write_any(json, data)
      end
    rescue ex : JSON::Error | OverflowError
      raise QueryError.new("Request payload cannot be JSON-encoded: #{ex.message}. " \
                           "(NaN, Infinity, and recursive structures have no JSON representation.)")
    end

    # Recursively serialize a Crystal value into a JSON::Builder.
    private def write_any(json : JSON::Builder, value)
      case value
      when Hash
        json.object do
          value.each do |k, v|
            json.field(k.to_s) { write_any(json, v) }
          end
        end
      when Array
        json.array do
          value.each { |v| write_any(json, v) }
        end
      when JSON::Any
        value.to_json(json)
      else
        value.to_json(json)
      end
    end

    # Send a single-op transaction and return the results array.
    private def commit_one(ops : Array, idempotency_key : String?) : Array(Hash(String, JSON::Any))
      commit_txn(ops, idempotency_key)
    end

    # POST with no body and decode the JSON object response.
    private def post_decode(path : String) : Hash(String, JSON::Any)
      data = post(path).json
      (data.try(&.as_h?) || {} of String => JSON::Any)
    end

    # Decode the results array out of a `/kit/txn` response.
    private def decode_results(body : String) : Array(Hash(String, JSON::Any))
      return [] of Hash(String, JSON::Any) if body.nil? || body.blank?
      data = JSON.parse(body)
      results = data["results"]?.try(&.as_a?) || [] of JSON::Any
      results.map(&.as_h)
    rescue ex : JSON::ParseException
      raise QueryError.new("Failed to decode transaction response: #{ex.message}")
    end

    # Build the full URI for a path.
    private def uri_for(path : String) : String
      p = path.to_s
      p = p.lchop('/')
      "#{@base_url}/#{p}"
    end

    # Map the HTTP status code and body to the appropriate typed exception.
    private def throw_for_status(status : Int32, body : String) : NoReturn
      message, error_code, op_index = decode_error_envelope(body)

      case status
      when 401, 403
        raise AuthError.new(message_for(message, "Authentication failed (#{status})"))
      when 404
        raise NotFoundError.new(message_for(message, "Resource not found"))
      when 409
        raise ConflictError.new(
          message_for(message, "Constraint violation"),
          error_code: error_code.to_s,
          op_index: op_index
        )
      else
        raise QueryError.new(message_for(message, "Server error (#{status})"))
      end
    end

    private def message_for(decoded : String?, fallback : String) : String
      decoded.nil? || decoded.empty? ? fallback : decoded
    end

    # Decode the server's JSON error envelope ({error: {message, code,
    # op_index}}) or a flat {message, code} object. Returns [message, code,
    # op_index]; message falls back to the raw body when it is non-JSON.
    private def decode_error_envelope(body : String) : {String?, String?, Int32?}
      return {nil, nil, nil} if body.nil? || body.empty?

      trimmed = body.lstrip
      return {body, nil, nil} unless trimmed.starts_with?('{')

      data = JSON.parse(body)
      return {body, nil, nil} unless data.as_h?

      err = data["error"]?
      if err && err.as_h?
        m = err["error"]? || err["message"]?
        msg = err["message"]?.try(&.as_s?)
        code = err["code"]?.try(&.as_s?)
        op = err["op_index"]?.try(&.as_i?)
        return {msg, code, op}
      end

      {data["message"]?.try(&.as_s?), data["code"]?.try(&.as_s?), nil}
    rescue ex : JSON::ParseException
      {body, nil, nil}
    end

    # Percent-escape a path segment so table names containing '/', '?', '#',
    # or spaces cannot inject extra segments or break routing. Only RFC 3986
    # unreserved characters pass through unescaped.
    private def url_path_escape(segment : String) : String
      String.build do |io|
        segment.to_s.each_byte do |b|
          if b.unreserved?
            io.write_byte(b)
          else
            io << '%'
            b.to_s(io, 16, precision: 2, upcase: true)
          end
        end
      end
    end
  end

  # QueryBuilder builds a request for the daemon's `/kit/query` endpoint,
  # where conditions push down to the engine's specialized indexes.
  #
  # Condition parameters accept friendly aliases that are translated to the
  # server's exact on-wire keys before sending (see `#where`).
  #
  # Example:
  #
  # ```
  # rows = db.query("orders")
  #   .where("bitmap_eq", {"column" => 2, "value" => "electronics"})
  #   .where("range_f64", {"column" => 3, "min" => 100.0})
  #   .projection([1, 2, 3])
  #   .limit(50)
  #   .execute
  #
  # if db.query("orders").truncated
  #   # result set hit the limit; more matches exist on the server
  # end
  # ```
  class QueryBuilder
    @conditions : Array(Hash(String, JSON::Any)) = [] of Hash(String, JSON::Any)
    @projection : Array(Int32)?
    @limit : Int32?
    @offset : Int64?
    @last_truncated = false

    # Initialize a new QueryBuilder. Normally created via `Client#query`.
    def initialize(@client : Client, @table : String)
    end

    # Add a native condition (AND-ed). Friendly aliases (`column` ->
    # `column_id`, `min`/`max` -> `lo`/`hi`) are accepted; the server's
    # canonical keys are also accepted as-is.
    def where(type : String, params : Hash) : QueryBuilder
      entry = {} of String => JSON::Any
      entry[type] = JSON::Any.new(QueryBuilder.normalize_condition(type, params))
      @conditions << entry
      self
    end

    # Set the column projection (column ids to return). `nil` means all columns.
    def projection(column_ids : Array(Int32)?) : QueryBuilder
      @projection = column_ids
      self
    end

    # Cap the number of rows returned.
    def limit(limit : Int32?) : QueryBuilder
      @limit = limit
      self
    end

    # Skip matching rows before applying the limit.
    def offset(offset : Int64?) : QueryBuilder
      @offset = offset
      self
    end

    # Build the request payload that will be sent to `/kit/query`.
    def build : Hash(String, JSON::Any)
      payload = {} of String => JSON::Any
      payload["table"] = JSON::Any.new(@table)
      unless @conditions.empty?
        payload["conditions"] = JSON::Any.new(@conditions.map { |cond| JSON::Any.new(cond) })
      end
      if proj = @projection
        payload["projection"] = JSON::Any.new(proj.map { |i| JSON::Any.new(i.to_i64) })
      end
      if lim = @limit
        payload["limit"] = JSON::Any.new(lim.to_i64)
      end
      if off = @offset
        payload["offset"] = JSON::Any.new(off)
      end
      payload
    end

    # Run the query and return the matching rows. Also records whether the
    # result was truncated by the limit; check it with `#truncated`.
    def execute : Array(JSON::Any)
      data = @client.post("/kit/query", build).json
      data = data.is_a?(JSON::Any) ? data.as_h? : nil
      data ||= {} of String => JSON::Any

      @last_truncated = data["truncated"]?.try(&.as_bool?) || false
      rows = data["rows"]?.try(&.as_a?) || [] of JSON::Any
      rows
    end

    # Whether the most recent `#execute` result was capped by the limit.
    # Returns `false` until `#execute` has been called.
    def truncated? : Bool
      @last_truncated
    end

    # ── Internal helpers ───────────────────────────────────────────────────

    # Translate friendly parameter aliases to the server's canonical on-wire
    # keys. Both spellings are accepted, so callers may use whichever is clearer.
    def self.normalize_condition(type : String, params : Hash) : Hash(String, JSON::Any)
      aliases = {
        "column"        => "column_id",
        "min"           => "lo",
        "max"           => "hi",
        "min_inclusive" => "lo_inclusive",
        "max_inclusive" => "hi_inclusive",
      }
      # Type-specific aliases (FTS only): value -> pattern/patterns.
      case type
      when "fm_contains"
        aliases = aliases.merge({"value" => "pattern"})
      when "fm_contains_all"
        aliases = aliases.merge({"value" => "patterns"})
      end

      normalized = {} of String => JSON::Any
      params.each do |key, value|
        canon = aliases[key.to_s]? || key.to_s
        normalized[canon] = Client.to_any(value)
      end
      normalized
    end
  end

  # Builds a request for POST /kit/search — multi-retriever hybrid search.
  class SearchBuilder
    @must = [] of Hash(String, JSON::Any)
    @retrievers = [] of Hash(String, JSON::Any)
    @fusion = {} of String => JSON::Any
    @rerank : Hash(String, JSON::Any)?
    @limit : Int32 = 10
    @projection : Array(Int32)?
    @explain = false
    @cursor : String?

    def initialize(@client : Client, @table : String)
      rr = {} of String => JSON::Any
      rr["constant"] = JSON::Any.new(60_i64)
      @fusion = {"reciprocal_rank" => JSON::Any.new(rr)}
    end

    def must(type : String, params : Hash = {} of String => JSON::Any) : SearchBuilder
      entry = {} of String => JSON::Any
      entry[type] = JSON::Any.new(QueryBuilder.normalize_condition(type, params))
      @must << entry
      self
    end

    def ann_retriever(name : String, column_id : Int32, query : Array(Float64), k : Int32 = 64, weight : Float64 = 1.0) : SearchBuilder
      ann = {} of String => JSON::Any
      ann["column_id"] = JSON::Any.new(column_id.to_i64)
      ann["query"] = JSON::Any.new(query.map { |f| JSON::Any.new(f) })
      ann["k"] = JSON::Any.new(k.to_i64)
      r = {} of String => JSON::Any
      r["name"] = JSON::Any.new(name)
      r["weight"] = JSON::Any.new(weight)
      r["ann"] = JSON::Any.new(ann)
      @retrievers << r
      self
    end

    def sparse_retriever(name : String, column_id : Int32, terms : Array(Array(Number)), k : Int32 = 64, weight : Float64 = 1.0) : SearchBuilder
      pairs = terms.map do |t|
        JSON::Any.new([JSON::Any.new(t[0].to_i64), JSON::Any.new(t[1].to_f64)])
      end
      sparse = {} of String => JSON::Any
      sparse["column_id"] = JSON::Any.new(column_id.to_i64)
      sparse["query"] = JSON::Any.new(pairs)
      sparse["k"] = JSON::Any.new(k.to_i64)
      r = {} of String => JSON::Any
      r["name"] = JSON::Any.new(name)
      r["weight"] = JSON::Any.new(weight)
      r["sparse"] = JSON::Any.new(sparse)
      @retrievers << r
      self
    end

    def min_hash_retriever(name : String, column_id : Int32, members : Array(String), k : Int32 = 64, weight : Float64 = 1.0) : SearchBuilder
      mh = {} of String => JSON::Any
      mh["column_id"] = JSON::Any.new(column_id.to_i64)
      mh["members"] = JSON::Any.new(members.map { |m| JSON::Any.new(m) })
      mh["k"] = JSON::Any.new(k.to_i64)
      r = {} of String => JSON::Any
      r["name"] = JSON::Any.new(name)
      r["weight"] = JSON::Any.new(weight)
      r["min_hash"] = JSON::Any.new(mh)
      @retrievers << r
      self
    end

    def fusion(constant : Int32 = 60) : SearchBuilder
      rr = {} of String => JSON::Any
      rr["constant"] = JSON::Any.new([constant, 1].max.to_i64)
      @fusion = {"reciprocal_rank" => JSON::Any.new(rr)}
      self
    end

    def exact_rerank(embedding_column : Int32, query : Array(Float64), metric : String = "cosine", candidate_limit : Int32 = 64, weight : Float64 = 1.0) : SearchBuilder
      ev = {} of String => JSON::Any
      ev["embedding_column"] = JSON::Any.new(embedding_column.to_i64)
      ev["query"] = JSON::Any.new(query.map { |f| JSON::Any.new(f) })
      ev["metric"] = JSON::Any.new(metric)
      ev["candidate_limit"] = JSON::Any.new(candidate_limit.to_i64)
      ev["weight"] = JSON::Any.new(weight)
      @rerank = {"exact_vector" => JSON::Any.new(ev)}
      self
    end

    def limit(limit : Int32) : SearchBuilder
      @limit = limit
      self
    end

    def projection(column_ids : Array(Int32)?) : SearchBuilder
      @projection = column_ids
      self
    end

    def explain(on : Bool = true) : SearchBuilder
      @explain = on
      self
    end

    def cursor(cursor : String?) : SearchBuilder
      @cursor = cursor
      self
    end

    def build : Hash(String, JSON::Any)
      raise ArgumentError.new("search requires at least one retriever") if @retrievers.empty?
      raise ArgumentError.new("search limit must be positive") if @limit <= 0

      payload = {} of String => JSON::Any
      payload["table"] = JSON::Any.new(@table)
      payload["retrievers"] = JSON::Any.new(@retrievers.map { |r| JSON::Any.new(r) })
      payload["fusion"] = JSON::Any.new(@fusion)
      payload["limit"] = JSON::Any.new(@limit.to_i64)
      unless @must.empty?
        payload["must"] = JSON::Any.new(@must.map { |m| JSON::Any.new(m) })
      end
      if rr = @rerank
        payload["rerank"] = JSON::Any.new(rr)
      end
      if proj = @projection
        payload["projection"] = JSON::Any.new(proj.map { |i| JSON::Any.new(i.to_i64) })
      end
      payload["explain"] = JSON::Any.new(true) if @explain
      if c = @cursor
        payload["cursor"] = JSON::Any.new(c) unless c.empty?
      end
      payload
    end

    def execute : Hash(String, JSON::Any)
      data = @client.post("/kit/search", build).json
      h = data.is_a?(JSON::Any) ? data.as_h? : nil
      h || {} of String => JSON::Any
    end
  end

  # Transaction stages operations locally and commits them atomically in a
  # single `/kit/txn` request. The engine enforces unique, foreign-key,
  # check, and trigger constraints at commit time; on any violation all
  # operations roll back and `#commit` raises a `ConflictError`.
  #
  # A Transaction is single-use -- call `#commit` or `#rollback` once, then
  # create a new one with `Client#begin_transaction`.
  class Transaction
    @ops : Array(Hash(String, JSON::Any)) = [] of Hash(String, JSON::Any)
    @committed = false

    # Initialize a new Transaction. Normally created via
    # `Client#begin_transaction`.
    def initialize(@client : Client)
    end

    # Stage a put (insert) operation.
    def put(table : String, cells : Cells, returning : Bool = false) : Transaction
      op = {
        "table"    => JSON::Any.new(table),
        "cells"    => JSON::Any.new(Client.flatten_cells(cells)),
        "returning" => JSON::Any.new(returning),
      } of String => JSON::Any
      @ops << {"put" => JSON::Any.new(op)}
      self
    end

    # Stage an upsert (insert-or-update) operation.
    def upsert(table : String, cells : Cells, update_cells : Cells? = nil,
               returning : Bool = false) : Transaction
      op = {
        "table"    => JSON::Any.new(table),
        "cells"    => JSON::Any.new(Client.flatten_cells(cells)),
        "returning" => JSON::Any.new(returning),
      } of String => JSON::Any
      if uc = update_cells
        op["update_cells"] = JSON::Any.new(Client.flatten_cells(uc))
      end
      @ops << {"upsert" => JSON::Any.new(op)}
      self
    end

    # Stage a delete by the internal row id.
    def delete(table : String, row_id : Int64) : Transaction
      op = {
        "table"  => JSON::Any.new(table),
        "row_id" => JSON::Any.new(row_id),
      } of String => JSON::Any
      @ops << {"delete" => JSON::Any.new(op)}
      self
    end

    # Stage a delete by primary-key value.
    def delete_by_pk(table : String, pk : CellValue) : Transaction
      op = {
        "table" => JSON::Any.new(table),
        "pk"    => Client.to_any(pk),
      } of String => JSON::Any
      @ops << {"delete_by_pk" => JSON::Any.new(op)}
      self
    end

    # The number of staged operations.
    def count : Int32
      @ops.size
    end

    # Commit all staged operations atomically.
    #
    # - `idempotency_key` - optional idempotency key for safe retries -- the
    #   daemon returns the original response on duplicate commits, even after
    #   a crash.
    def commit(idempotency_key : String? = nil) : Array(Hash(String, JSON::Any))
      raise "transaction already committed" if @committed

      @committed = true
      return [] of Hash(String, JSON::Any) if @ops.empty?

      @client.commit_txn(@ops, idempotency_key)
    end

    # Rollback (discard all staged operations).
    def rollback : Nil
      raise "cannot rollback a committed transaction" if @committed
      @ops.clear
      nil
    end
  end
end

# Extend UInt8 with an RFC 3986 unreserved check, used by url_path_escape.
struct UInt8
  # True for RFC 3986 unreserved characters: ALPHA / DIGIT / "-" / "." / "_" / "~".
  def unreserved? : Bool
    case self
    when 65..90, 97..122, 48..57, 45, 46, 95, 126
      true
    else
      false
    end
  end
end

require "./mongreldb/*"
