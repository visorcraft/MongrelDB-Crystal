require "./spec_helper"
require "http/client"
require "process"
require "io/memory"
require "random"
require "file_utils"

# Shared daemon lifecycle for the live test suite. Boots a real
# mongreldb-server (or reuses one at MONGRELDB_URL) and exposes the connected
# `MongrelDB::Client` via `MongrelDBDaemon.client`.
module MongrelDBDaemon
  class_property! client : MongrelDB::Client
  class_property log_path : String?
  @@process : Process?
  @@data_dir : String?

  # Boot the daemon once for the whole suite. Sets `@@client` on success,
  # leaves it nil (so tests self-skip) when no binary is available.
  def self.boot : Void
    existing = ENV["MONGRELDB_URL"]?
    unless existing.nil? || existing.empty?
      if reachable?(existing)
        @@client = MongrelDB::Client.new(url: existing, token: ENV["MONGRELDB_TOKEN"]?)
        return
      end
      STDERR.puts "mongreldb: MONGRELDB_URL=#{existing} is not reachable"
      exit 1
    end

    bin = MongrelDBSpec.resolve_server_binary
    if bin.nil?
      STDERR.puts "--- no mongreldb-server binary: live tests will skip"
      return
    end

    port = free_port
    data_dir = File.join(Dir.tempdir, "mongreldb-crystal-test-#{Random::Secure.hex(6)}")
    FileUtils.mkdir_p(data_dir)
    @@data_dir = data_dir
    url = "http://127.0.0.1:#{port}"
    log_path = File.join(Dir.tempdir, "mongreldb-crystal-server-#{Random::Secure.hex(6)}.log")
    @@log_path = log_path

    output = File.open(log_path, "w")
    @@process = Process.new(bin, [data_dir, "--port", port.to_s],
                            output: output, error: output)

    unless wait_for_health(url, 40)
      dump_log
      STDERR.puts "mongreldb: server did not become healthy"
      exit 1
    end

    @@client = MongrelDB::Client.new(url: url)
  end

  # Tear the daemon down (called at suite exit).
  def self.shutdown : Void
    if p = @@process
      p.terminate rescue nil
      p.wait rescue nil
      @@process = nil
    end
    if d = @@data_dir
      FileUtils.rm_r(d) rescue nil
    end
  end

  def self.dump_log : Void
    if path = @@log_path
      if File.exists?(path)
        STDERR.puts "--- mongreldb-server log (#{path}) ---"
        STDERR.puts File.read(path)
      end
    end
  end

  # ── Internal ────────────────────────────────────────────────────────────

  private def self.reachable?(url : String) : Bool
    client = MongrelDB::Client.new(url: url, token: ENV["MONGRELDB_TOKEN"]?, read_timeout: 2.0)
    client.health
  rescue
    false
  end

  private def self.wait_for_health(url : String, max_seconds : Int32) : Bool
    deadline = Time.utc + max_seconds.seconds
    while Time.utc < deadline
      return true if reachable?(url)
      sleep 0.5.seconds
    end
    false
  end

  private def self.free_port : Int32
    server = TCPServer.new("127.0.0.1", 0)
    port = server.local_address.port
    server.close
    port
  end
end

# Test helpers shared by every live test.
module MongrelDBTestHelpers
  # A unique table name per call to isolate each test's data.
  def unique_table(prefix : String = "cr_tbl") : String
    "#{prefix}_#{Time.utc.to_unix}_#{Random::Secure.hex(4)}"
  end

  # A typed int64 column descriptor.
  def int_col(id : Int32, name : String, primary_key : Bool = false) : MongrelDB::Column
    {
      "id"          => id, "name" => name, "ty" => "int64",
      "primary_key" => primary_key, "nullable" => false,
    }
  end

  # A typed float64 column descriptor.
  def float_col(id : Int32, name : String) : MongrelDB::Column
    {
      "id"          => id, "name" => name, "ty" => "float64",
      "primary_key" => false, "nullable" => false,
    }
  end

  # Drop +name+ if present then create it with the given columns.
  def fresh_table(client : MongrelDB::Client, name : String, columns : Array(MongrelDB::Column)) : Nil
    begin
      client.drop_table(name)
    rescue MongrelDB::MongrelDBError
    end
    client.create_table(name, columns)
  end

  def cleanup(client : MongrelDB::Client, name : String) : Nil
    begin
      client.drop_table(name)
    rescue MongrelDB::MongrelDBError
    end
  end

  # Skip the test when the suite was unable to boot a daemon.
  def skip_if_no_client!
    if MongrelDBDaemon.client.nil?
      pending!("no mongreldb-server available")
    end
  end
end
