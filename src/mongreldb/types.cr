# MongrelDB Crystal client - type aliases shared across the client.
#
# Loaded by `src/mongreldb.cr` via `require "./mongreldb/*"`.

module MongrelDB
  # A column descriptor passed to `Client#create_table`. Keys are the server's
  # on-wire column keys: `id`, `name`, `ty`, `primary_key`, `nullable`, and
  # optional constraints (`enum_variants`, `default_value`, ...).
  alias Column = Hash(String, CellValue)

  # A cell value: any JSON-encodable scalar the server accepts for a column.
  alias CellValue = Int64 | Int32 | Float64 | Float32 | Bool | String | Nil | Array(CellValue) | Hash(String, CellValue)

  # Cells map column id -> value. Internally flattened to
  # `[col_id, value, col_id, value, ...]` before sending.
  alias Cells = Hash(Int32, CellValue) | Hash(Int64, CellValue)
end
