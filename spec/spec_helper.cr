require "spec"

# Shared spec helper for the MongrelDB Crystal client.
#
# The offline unit tests run without a daemon. The live integration suite
# (spec/live_spec.cr) self-skips when no mongreldb-server binary is found.
module MongrelDBSpec
  # Resolve the server binary, or nil to skip the live suite.
  def self.resolve_server_binary : String?
    env = ENV["MONGRELDB_SERVER"]?
    if env && !env.empty? && File.executable?(env)
      return env
    end

    local = File.expand_path("bin/mongreldb-server", Dir.current)
    return local if File.executable?(local)

    ENV["PATH"]?.try &.split(File::SEPARATOR) do |dir|
      candidate = File.join(dir, "mongreldb-server")
      return candidate if File.executable?(candidate)
    end

    nil
  end
end
