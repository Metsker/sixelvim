local converters = require("sixel-preview.converters")
local config = require("sixel-preview.config")

local M = {}

-- LRU cache: key -> raw sixel bytes. Ordered list tracks recency so we can
-- evict the oldest entries once we exceed the byte budget.
M._cache = {}
M._cache_order = {}                     -- oldest at index 1, newest at end
M._cache_bytes = 0
M._cache_max_bytes = 100 * 1024 * 1024  -- 100 MB

-- In-flight render jobs: key -> list of pending callbacks. Lets concurrent
-- requests for the same image share one converter run.
M._inflight = {}

local function lru_touch(key)
  for i = #M._cache_order, 1, -1 do
    if M._cache_order[i] == key then
      table.remove(M._cache_order, i)
      break
    end
  end
  table.insert(M._cache_order, key)
end

local function cache_set(key, data)
  local old = M._cache[key]
  if old then
    M._cache_bytes = M._cache_bytes - #old
  end
  M._cache[key] = data
  M._cache_bytes = M._cache_bytes + #data
  lru_touch(key)

  -- Evict oldest until under budget. The just-inserted key sits at the tail
  -- so it's the last candidate; #order > 1 keeps us from evicting it alone.
  while M._cache_bytes > M._cache_max_bytes and #M._cache_order > 1 do
    local oldest = table.remove(M._cache_order, 1)
    if oldest == key then
      -- Don't evict the entry we just inserted; put it back and stop.
      table.insert(M._cache_order, 1, oldest)
      break
    end
    local victim = M._cache[oldest]
    if victim then
      M._cache_bytes = M._cache_bytes - #victim
      M._cache[oldest] = nil
    end
  end
end

local function fan_out(key, data, err)
  local callbacks = M._inflight[key]
  M._inflight[key] = nil
  if not callbacks then return end
  for _, cb in ipairs(callbacks) do
    cb(data, err)
  end
end

--- Build a cache key from render parameters.
---@param filepath string
---@param size? table
---@return string
function M._cache_key(filepath, size)
  local page = config.options.pdf.page or 1
  local w = size and size.max_width or config.options.sixel.max_width
  local h = size and size.max_height or config.options.sixel.max_height

  -- Include file mtime so cache invalidates if file changes
  local stat = vim.uv.fs_stat(filepath)
  local mtime = stat and stat.mtime.sec or 0

  return string.format("%s:%d:%dx%d", filepath, mtime, w, h)
    .. (converters.detect(filepath) == "pdf" and (":p" .. page) or "")
end

--- Check whether the result is already cached.
---@param filepath string
---@param size? table
---@return boolean
function M.is_cached(filepath, size)
  return M._cache[M._cache_key(filepath, size)] ~= nil
end

--- Clear the entire cache or a specific file's entries.
---@param filepath? string If given, only clear entries for this file
function M.clear_cache(filepath)
  if filepath then
    local prefix = filepath .. ":"
    for k in pairs(M._cache) do
      if k:sub(1, #prefix) == prefix then
        local data = M._cache[k]
        if data then
          M._cache_bytes = M._cache_bytes - #data
        end
        M._cache[k] = nil
        for i = #M._cache_order, 1, -1 do
          if M._cache_order[i] == k then
            table.remove(M._cache_order, i)
            break
          end
        end
      end
    end
  else
    M._cache = {}
    M._cache_order = {}
    M._cache_bytes = 0
  end
end

--- Render a file to sixel and return the raw sixel bytes via callback.
--- Uses caching to avoid re-rendering the same file/size/page, and deduplicates
--- concurrent requests for the same key so we don't spawn duplicate converters.
---@param filepath string Absolute path to the file
---@param callback fun(sixel_data: string|nil, err: string|nil)
---@param size? { max_width: number, max_height: number } Override render size
function M.render(filepath, callback, size)
  local filetype = converters.detect(filepath)
  if not filetype then
    callback(nil, "Unsupported file type: " .. filepath)
    return
  end

  local key = M._cache_key(filepath, size)
  local cached = M._cache[key]
  if cached then
    lru_touch(key)
    callback(cached, nil)
    return
  end

  -- If a render is already in flight for this key, just attach to it. Avoids
  -- redundant converter invocations when BufReadCmd + BufEnter both trigger
  -- renders for the same buffer concurrently.
  if M._inflight[key] then
    table.insert(M._inflight[key], callback)
    return
  end
  M._inflight[key] = { callback }

  local cmd, err = converters.build_cmd(filepath, filetype, size)
  if err then
    fan_out(key, nil, err)
    return
  end

  -- The PDF flow chains pdftoppm and magick via "&&"/"&", so it has to run
  -- through a shell. Single-binary flows (magick, chafa) run argv-style.
  local use_shell = filetype == "pdf"
    and config.options.converters.pdf == "pdftoppm"

  local job_cmd = use_shell and table.concat(cmd, " ") or cmd

  local sixel_data = ""
  local stderr_chunks = {}

  vim.fn.jobstart(job_cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if not data or #data == 0 then return end
      -- jobstart appends an empty string when the stream ended with a newline.
      -- For binary sixel capture we drop it so concat doesn't add a stray \n.
      if data[#data] == "" then data[#data] = nil end
      -- Sixel never contains '\n' bytes; with stdout_buffered=true we usually
      -- receive a single-element list, so concat is a no-op. The join-with-\n
      -- is there to round-trip in the (rare) case nvim splits anyway.
      sixel_data = table.concat(data, "\n")
    end,
    on_stderr = function(_, data)
      if data then
        for _, chunk in ipairs(data) do
          table.insert(stderr_chunks, chunk)
        end
      end
    end,
    on_exit = function(_, exit_code)
      if exit_code ~= 0 then
        local errmsg = table.concat(stderr_chunks, "\n")
        fan_out(key, nil, "Converter exited with code " .. exit_code .. ": " .. errmsg)
        return
      end

      if not sixel_data or #sixel_data == 0 then
        fan_out(key, nil, "Converter produced no output")
        return
      end

      cache_set(key, sixel_data)
      fan_out(key, sixel_data, nil)
    end,
  })
end

return M
