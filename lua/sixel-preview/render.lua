local converters = require("sixel-preview.converters")
local config = require("sixel-preview.config")

local M = {}

-- In-memory cache: key -> sixel_data
-- Key is filepath + size + page (for PDFs)
M._cache = {}

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
        M._cache[k] = nil
      end
    end
  else
    M._cache = {}
  end
end

--- Render a file to sixel and return the raw sixel bytes via callback.
--- Uses caching to avoid re-rendering the same file/size/page.
---@param filepath string Absolute path to the file
---@param callback fun(sixel_data: string|nil, err: string|nil)
---@param size? { max_width: number, max_height: number } Override render size
function M.render(filepath, callback, size)
  local filetype = converters.detect(filepath)
  if not filetype then
    callback(nil, "Unsupported file type: " .. filepath)
    return
  end

  -- Check cache first
  local key = M._cache_key(filepath, size)
  local cached = M._cache[key]
  if cached then
    callback(cached, nil)
    return
  end

  local cmd, err = converters.build_cmd(filepath, filetype, size)
  if err then
    callback(nil, err)
    return
  end

  -- Write sixel to a temp file instead of stdout to preserve binary data
  local tmp_sixel = os.tmpname() .. ".six"

  -- Replace "sixel:-" with the temp file path in the command
  local patched = false
  for i, arg in ipairs(cmd) do
    if arg == "sixel:-" then
      cmd[i] = tmp_sixel
      patched = true
      break
    end
  end

  if not patched then
    callback(nil, "Could not patch command for temp file output")
    return
  end

  -- For PDF pipeline, join into shell command string
  local use_shell = filetype == "pdf"
    and config.options.converters.pdf == "pdftoppm"

  local job_cmd = use_shell and table.concat(cmd, " ") or cmd

  local stderr_chunks = {}

  vim.fn.jobstart(job_cmd, {
    stderr_buffered = true,
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
        os.remove(tmp_sixel)
        callback(nil, "Converter exited with code " .. exit_code .. ": " .. errmsg)
        return
      end

      -- Read the sixel data from the temp file
      local f = io.open(tmp_sixel, "rb")
      if not f then
        callback(nil, "Failed to read sixel output from temp file")
        return
      end
      local sixel_data = f:read("*a")
      f:close()
      os.remove(tmp_sixel)

      if not sixel_data or #sixel_data == 0 then
        callback(nil, "Converter produced no output")
        return
      end

      -- Store in cache
      M._cache[key] = sixel_data

      callback(sixel_data, nil)
    end,
  })
end

return M
