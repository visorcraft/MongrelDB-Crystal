# Authentication & Authorization

A `mongreldb-server` daemon runs in one of three modes:

1. **Open** (default) - no auth required.
2. **Bearer token** (`--auth-token <TOKEN>`) - every request must carry an
   `Authorization: Bearer <TOKEN>` header.
3. **HTTP Basic** (`--auth-users`) - every request must carry an
   `Authorization: Basic <base64(user:pass)>` header.

The Crystal client supports all three through `Client.new` arguments. This
guide shows each mode, how to inspect what was sent, and how to manage users
and roles via SQL when the server is in Basic mode.

---

## Bearer token mode

Start the daemon with a token:

```sh
mongreldb-server --auth-token s3cret-token
```

Connect with `token:`. The token is sent as `Authorization: Bearer ...` on
every request.

```crystal
db = MongrelDB::Client.new(url: "http://127.0.0.1:8453", token: "s3cret-token")

begin
  ok = db.health
  puts "healthy: #{ok}"
rescue ex : MongrelDB::AuthError
  abort "bad or missing token"
end
```

A missing or wrong token surfaces as `MongrelDB::AuthError` (HTTP 401/403).

### Where the token comes from

Hard-coding secrets in source is bad practice. Read it from the environment:

```crystal
token = ENV["MONGRELDB_TOKEN"]?
abort "MONGRELDB_TOKEN not set" if token.nil? || token.empty?

db = MongrelDB::Client.new(token: token)
```

## Basic auth mode

Start the daemon with a users file or inline users:

```sh
mongreldb-server --auth-users
```

Connect with `username:` / `password:`:

```crystal
db = MongrelDB::Client.new(
  url: "http://127.0.0.1:8453",
  username: "admin",
  password: "s3cret",
)
```

The client base64-encodes `username:password` and sets
`Authorization: Basic ...` on every request.

## Token takes precedence

If you supply both, `token:` wins and Basic credentials are ignored. This lets
you layer an override without branching:

```crystal
db = MongrelDB::Client.new(
  url: url,
  username: "fallback",
  password: "user",
  token: "overrides-everything",
)
```

## Timeouts

The client takes `connect_timeout:` and `read_timeout:` (both in seconds),
passed straight through to the underlying `HTTP::Client`.

```crystal
db = MongrelDB::Client.new(
  url: url,
  token: token,
  connect_timeout: 10.0,
  read_timeout: 60.0,
)
```

## User and role management via SQL

When the daemon is in Basic auth mode, users and roles live in the catalog and
are managed with SQL. Run these statements through `Client#sql`.

### Create a user

```crystal
db.sql("CREATE USER alice WITH PASSWORD 'hunter2'")
```

### Alter a user

Change a password:

```crystal
db.sql("ALTER USER alice WITH PASSWORD 'new-password'")
```

Grant the admin role:

```crystal
db.sql("ALTER USER alice ADMIN")
```

`ALTER USER ... ADMIN` is how you promote a user to full administrative
privileges (table creation/drop, compaction, user management). Use it
sparingly.

### Drop a user

```crystal
db.sql("DROP USER alice")
```

### Roles and grants

```crystal
db.sql("CREATE ROLE analyst")
db.sql("GRANT SELECT ON orders TO analyst")
db.sql("GRANT analyst TO alice")
db.sql("REVOKE SELECT ON orders FROM analyst")
db.sql("DROP ROLE analyst")
```

Exact grant syntax mirrors the server's SQL flavor; consult the server's SQL
reference for the full `GRANT`/`REVOKE` grammar available in your build.

## Common pitfalls

**Auth errors look like other errors without a specific rescue.** A 401/403
raises `MongrelDB::AuthError`; a 404 raises `MongrelDB::NotFoundError`. Always
discriminate by class rather than string-matching `ex.message`.

**Forgetting to set auth in production.** A client built with
`MongrelDB::Client.new` and no credentials sends no credentials. Against an
auth-enabled daemon, every call raises `AuthError`. Centralize client
construction so the auth option is never accidentally dropped.

**Sharing one client across fibers is fine; sharing credentials across users
is not.** A `Client` is safe for concurrent use, but it carries one identity.
If you serve multiple authenticated users, build a client per user (or per
request) with that user's token.

**Token in version control.** Put secrets in the environment, a secret
manager, or a file outside the repo. Never commit a real token.

## Next steps

- [errors.md](errors.md) - `AuthError` and the rest of the error hierarchy
- [quickstart.md](quickstart.md) - the full end-to-end walkthrough
