local render = require("sixel-preview.render")
local converters = require("sixel-preview.converters")
local config = require("sixel-preview.config")

local M = {}

-- Track the preview tab/buffer so we can reuse it
M._state = {
  tabpage = nil,
  bufnr = nil,
}

-- Track PDF page state per buffer: buf -> { filepath, page, total_pages }
M._pdf_state = {}

-- Cached terminal pixel size (cleared on VimResized)
M._terminal_size = nil

--- Detect terminal window pixel dimensions.
--- On Windows, uses Win32 GetForegroundWindow + GetClientRect.
--- On Unix, uses TIOCGWINSZ ioctl.
--- Falls back to cell_size * columns/lines.
---@return { width: number, height: number, cell_w: number, cell_h: number }
function M._terminal_pixels()
  if M._terminal_size then
    return M._terminal_size
  end

  local cols = vim.o.columns
  local rows = vim.o.lines

  if jit.os == "Windows" then
    local ok, ffi = pcall(require, "ffi")
    if ok then
      pcall(function()
        ffi.cdef([[
          typedef struct { long left; long top; long right; long bottom; } RECT;
          void* GetForegroundWindow();
          int GetClientRect(void* hWnd, RECT* lpRect);
        ]])
      end)

      pcall(function()
        local hwnd = ffi.C.GetForegroundWindow()
        if hwnd ~= nil then
          local rect = ffi.new("RECT")
          if ffi.C.GetClientRect(hwnd, rect) ~= 0 then
            local w = rect.right - rect.left
            local h = rect.bottom - rect.top
            if w > 0 and h > 0 then
              M._terminal_size = {
                width = w,
                height = h,
                cell_w = math.floor(w / cols),
                cell_h = math.floor(h / rows),
              }
              return
            end
          end
        end
      end)
    end
  else
    -- Unix: TIOCGWINSZ
    local ok, ffi = pcall(require, "ffi")
    if ok then
      pcall(function()
        ffi.cdef([[
          typedef struct {
            unsigned short row;
            unsigned short col;
            unsigned short xpixel;
            unsigned short ypixel;
          } winsize_t;
          int ioctl(int fd, unsigned long request, ...);
        ]])
      end)

      pcall(function()
        local ws = ffi.new("winsize_t")
        local TIOCGWINSZ = jit.os == "Linux" and 0x5413 or 0x40087468
        if ffi.C.ioctl(1, TIOCGWINSZ, ws) == 0 and ws.xpixel > 0 and ws.ypixel > 0 then
          M._terminal_size = {
            width = ws.xpixel,
            height = ws.ypixel,
            cell_w = math.floor(ws.xpixel / ws.col),
            cell_h = math.floor(ws.ypixel / ws.row),
          }
          return
        end
      end)
    end
  end

  -- Fallback
  if not M._terminal_size then
    local cell = config.options.sixel.cell_size or { 8, 16 }
    M._terminal_size = {
      width = cols * cell[1],
      height = rows * cell[2],
      cell_w = cell[1],
      cell_h = cell[2],
    }
  end

  return M._terminal_size
end

-- Invalidate cache on resize
vim.api.nvim_create_autocmd("VimResized", {
  callback = function()
    M._terminal_size = nil
  end,
})

--- Estimate terminal cell size in pixels.
---@return { cell_w: number, cell_h: number }
function M._cell_size()
  local t = M._terminal_pixels()
  return { cell_w = t.cell_w, cell_h = t.cell_h }
end

--- Find the best window currently showing a buffer.
--- Prefers an oil-style preview window (previewwindow=true) so that when the
--- same image is open in a regular buffer AND selected in oil, sixel goes to
--- the preview pane instead of the regular buffer's window (which oil's float
--- typically covers).
---@param buf number
---@return number|nil
function M._find_buf_win(buf)
  local fallback
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      if vim.wo[win].previewwindow then
        return win
      end
      fallback = fallback or win
    end
  end
  return fallback
end

--- Whether the given (non-floating) window is overlapped by any floating
--- window in the same tab. Sixel pixels are drawn in the terminal's graphics
--- layer and would leak through anything nvim layers on top — so when something
--- like oil's UI is covering the buffer, we skip the render entirely.
---@param win number
---@return boolean
function M._is_win_covered(win)
  local cfg = vim.api.nvim_win_get_config(win)
  if cfg.relative ~= "" then
    return false
  end
  local pos = vim.api.nvim_win_get_position(win)
  local r, c = pos[1], pos[2]
  local h = vim.api.nvim_win_get_height(win)
  local w = vim.api.nvim_win_get_width(win)

  local tab = vim.api.nvim_win_get_tabpage(win)
  for _, other in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if other ~= win then
      local ocfg = vim.api.nvim_win_get_config(other)
      if ocfg.relative ~= "" then
        local orow = tonumber(ocfg.row) or 0
        local ocol = tonumber(ocfg.col) or 0
        local oh = ocfg.height or 0
        local ow = ocfg.width or 0
        if r < orow + oh and r + h > orow
          and c < ocol + ow and c + w > ocol then
          return true
        end
      end
    end
  end
  return false
end

--- Calculate the window's screen position and pixel dimensions.
---@param win number Window handle
---@return { row: number, col: number, width_px: number, height_px: number, width_cells: number, height_cells: number }
function M._win_geometry(win)
  local pos = vim.api.nvim_win_get_position(win)  -- (row, col) 0-indexed
  local width = vim.api.nvim_win_get_width(win)
  local height = vim.api.nvim_win_get_height(win)
  local cell = M._cell_size()
  return {
    row = pos[1],        -- 0-indexed screen row
    col = pos[2],        -- 0-indexed screen col
    width_cells = width,
    height_cells = height,
    width_px = width * cell.cell_w,
    height_px = height * cell.cell_h,
    cell_w = cell.cell_w,
    cell_h = cell.cell_h,
  }
end

--- Apply clean window options for preview display.
---@param win number
local function clean_win(win)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].statuscolumn = ""
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].cursorline = false
end

--- Build ANSI escape to position cursor at a specific terminal cell.
--- Row and col are 1-indexed for ANSI.
---@param row number 1-indexed
---@param col number 1-indexed
---@return string
local function ansi_goto(row, col)
  return string.format("\27[%d;%dH", row, col)
end

--- Render sixel positioned inside a specific window.
---@param win number Window handle
---@param buf number Buffer handle
---@param sixel_data string Raw sixel output
---@param geom table Window geometry from _win_geometry
---@param filetype? string "image" or "pdf"
function M._render_in_win(win, buf, sixel_data, geom, filetype)
  if not sixel_data or #sixel_data == 0 then return end
  if M._is_win_covered(win) then return end

  local pad_rows, pad_cols
  if filetype == "pdf" then
    -- PDFs fill the tab — minimal padding (1 row for statusline)
    pad_rows = 1
    pad_cols = 0
  else
    -- Images get centered with some breathing room
    pad_rows = math.max(1, math.floor(geom.height_cells * 0.05))
    pad_cols = math.max(1, math.floor(geom.width_cells * 0.05))
  end

  -- ANSI row/col are 1-indexed; win position is 0-indexed
  local target_row = geom.row + 1 + pad_rows
  local target_col = geom.col + 1 + pad_cols

  -- Save cursor, move to target position, emit sixel, restore cursor
  local seq = "\27[s"                            -- save cursor
    .. ansi_goto(target_row, target_col)         -- position in window
    .. sixel_data                                -- sixel payload
    .. "\27[u"                                   -- restore cursor

  vim.api.nvim_chan_send(2, seq)
end

--- Open a preview of the given file in a new tab.
---@param filepath string Absolute path to preview
---@param opts? { page?: number } Override options per-call
function M.open(filepath, opts)
  opts = opts or {}

  local filetype = converters.detect(filepath)
  if not filetype then
    vim.notify("[sixel-preview] Unsupported file: " .. filepath, vim.log.levels.WARN)
    return
  end

  local restore_page
  if opts.page and filetype == "pdf" then
    restore_page = config.options.pdf.page
    config.options.pdf.page = opts.page
  end

  local fname = vim.fn.fnamemodify(filepath, ":t")
  local title = config.options.tab.title .. ": " .. fname
  local buf = M._get_or_create_buf(title)
  -- Record the actual file being previewed; the buffer name is the tab title,
  -- not a real path, so BufEnter re-render must use this instead.
  vim.b[buf].sixel_preview_filepath = filepath
  local win = vim.api.nvim_get_current_win()
  local geom = M._win_geometry(win)

  -- Use actual terminal pixel dimensions for sizing
  local term = M._terminal_pixels()

  local render_size
  if filetype == "pdf" then
    -- PDFs: fill the window area (use window cell count * actual cell pixels)
    render_size = {
      max_width = geom.width_cells * term.cell_w,
      max_height = (geom.height_cells - 2) * term.cell_h,  -- reserve 2 rows for statusline
      cell_w = term.cell_w,
      cell_h = term.cell_h,
    }
  else
    -- Images: fit in window with padding
    local padding = 4
    render_size = {
      max_width = math.max(100, geom.width_cells * term.cell_w - (term.cell_w * padding)),
      max_height = math.max(100, geom.height_cells * term.cell_h - (term.cell_h * padding)),
      cell_w = term.cell_w,
      cell_h = term.cell_h,
    }
  end

  if not render.is_cached(filepath, render_size) then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Rendering " .. fname .. "..." })
  end

  render.render(filepath, function(sixel_data, err)
    if restore_page then
      config.options.pdf.page = restore_page
    end

    if err then
      vim.schedule(function()
        vim.bo[buf].modifiable = true
        local clean = ("Error rendering preview: " .. err):gsub("\r\n", "\n"):gsub("\r", "\n")
        local lines = vim.split(clean, "\n", { plain = true })
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      end)
      return
    end

    vim.schedule(function()
      local first = vim.api.nvim_buf_get_lines(buf, 0, 1, false)
      if first[1] and first[1] ~= "" then
        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
        vim.bo[buf].modifiable = false
      end
      clean_win(win)
      vim.cmd("redraw")
      M._render_in_win(win, buf, sixel_data, geom, filetype)
      if filetype == "pdf" and not M._pdf_state[buf] then
        local page = opts.page or config.options.pdf.page
        M._setup_pdf_keys(buf, filepath, page)
      end
    end)
  end, render_size)
end

--- Close the preview tab if it exists.
function M.close()
  local state = M._state
  if state.tabpage and vim.api.nvim_tabpage_is_valid(state.tabpage) then
    local tabnr = vim.api.nvim_tabpage_get_number(state.tabpage)
    vim.cmd("tabclose " .. tabnr)
  end
  M._state = { tabpage = nil, bufnr = nil }
end

--- Toggle the preview for the file under cursor.
function M.toggle()
  local state = M._state
  if state.tabpage and vim.api.nvim_tabpage_is_valid(state.tabpage) then
    M.close()
    return
  end

  local filepath = vim.fn.expand("%:p")
  if filepath == "" then
    vim.notify("[sixel-preview] No file under cursor", vim.log.levels.WARN)
    return
  end
  M.open(filepath)
end

--- Render a sixel preview directly into an existing buffer.
--- Used by BufReadCmd autocmd when opening image/PDF from explorer.
---@param buf number Buffer handle
---@param filepath string Absolute path to preview
---@param opts? { page?: number }
function M.open_in_buf(buf, filepath, opts)
  opts = opts or {}

  local filetype = converters.detect(filepath)
  if not filetype then return end

  -- Determine the page to render
  local current_page = opts.page or (M._pdf_state[buf] and M._pdf_state[buf].page) or 1

  local restore_page
  if filetype == "pdf" then
    restore_page = config.options.pdf.page
    config.options.pdf.page = current_page
  end

  -- Configure as scratch buffer
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "sixel-preview"
  vim.bo[buf].modifiable = true
  vim.b[buf].sixel_preview_filepath = filepath

  -- If the buffer isn't visible, don't render: BufEnter schedules can fire
  -- after oil swapped the buffer out, and rendering to "the current window"
  -- would draw sixel in the wrong place.
  local target_win = M._find_buf_win(buf)
  if not target_win then return end

  local geom = M._win_geometry(target_win)
  local term = M._terminal_pixels()

  local render_size
  if filetype == "pdf" then
    render_size = {
      max_width = geom.width_cells * term.cell_w,
      max_height = (geom.height_cells - 2) * term.cell_h,
      cell_w = term.cell_w,
      cell_h = term.cell_h,
    }
  else
    local padding = 4
    render_size = {
      max_width = math.max(100, geom.width_cells * term.cell_w - (term.cell_w * padding)),
      max_height = math.max(100, geom.height_cells * term.cell_h - (term.cell_h * padding)),
      cell_w = term.cell_w,
      cell_h = term.cell_h,
    }
  end

  -- Only paint a "Rendering..." placeholder when the converter actually has
  -- to run. On a cache hit we leave the buffer untouched here; the schedule
  -- below clears any leftover content and forces a redraw before sending sixel.
  if not render.is_cached(filepath, render_size) then
    local fname = vim.fn.fnamemodify(filepath, ":t")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Rendering " .. fname .. "..." })
  end

  render.render(filepath, function(sixel_data, err)
    if restore_page then
      config.options.pdf.page = restore_page
    end

    if err then
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(buf) then
          vim.bo[buf].modifiable = true
          local clean = ("Error: " .. err):gsub("\r\n", "\n"):gsub("\r", "\n")
          local lines = vim.split(clean, "\n", { plain = true })
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        end
      end)
      return
    end

    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(buf) then return end

      -- Clear any non-empty buffer content (placeholder, stale text from an
      -- aborted prior render, etc.). The redraw below flushes the resulting
      -- cell updates BEFORE the sixel is sent, so the pixels survive.
      local first = vim.api.nvim_buf_get_lines(buf, 0, 1, false)
      if first[1] and first[1] ~= "" then
        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
        vim.bo[buf].modifiable = false
      end

      local win = M._find_buf_win(buf)
      if not win then return end

      clean_win(win)
      local fresh_geom = M._win_geometry(win)
      -- Force a redraw so any pending cell updates (the buffer clear above, or
      -- the buffer swap that brought us here from a text file) hit the
      -- terminal *before* we send sixel. Otherwise nvim emits cell clears
      -- AFTER our pixels, wiping them in tmux.
      vim.cmd("redraw")
      M._render_in_win(win, buf, sixel_data, fresh_geom, filetype)

      -- Set up PDF page navigation keybindings
      if filetype == "pdf" and not M._pdf_state[buf] then
        M._setup_pdf_keys(buf, filepath, current_page)
      elseif filetype == "pdf" and M._pdf_state[buf] then
        -- Update page indicator
        local state = M._pdf_state[buf]
        local page_info = "Page " .. state.page
        if state.total_pages then
          page_info = page_info .. " / " .. state.total_pages
        end
        vim.notify("[sixel-preview] " .. page_info, vim.log.levels.INFO)
      end
    end)
  end, render_size)
end

--- Get or create the scratch buffer and tab for preview.
---@param title string
---@return number bufnr
function M._get_or_create_buf(title)
  local state = M._state

  -- Reuse if configured and still valid
  if config.options.tab.reuse
    and state.bufnr
    and vim.api.nvim_buf_is_valid(state.bufnr)
    and state.tabpage
    and vim.api.nvim_tabpage_is_valid(state.tabpage)
  then
    -- Switch to the existing preview tab
    local tabnr = vim.api.nvim_tabpage_get_number(state.tabpage)
    vim.cmd("tabn " .. tabnr)
    vim.bo[state.bufnr].modifiable = true
    return state.bufnr
  end

  -- Open a new tab with a scratch buffer
  vim.cmd("tabnew")
  local buf = vim.api.nvim_get_current_buf()
  local tabpage = vim.api.nvim_get_current_tabpage()

  -- Configure as scratch buffer
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "sixel-preview"

  -- Set tab title via buffer name
  vim.api.nvim_buf_set_name(buf, title)

  -- Track state
  M._state = {
    tabpage = tabpage,
    bufnr = buf,
  }

  -- Auto-close on leave if configured
  if config.options.tab.close_on_leave then
    vim.api.nvim_create_autocmd("TabLeave", {
      buffer = buf,
      once = true,
      callback = function()
        vim.schedule(function() M.close() end)
      end,
    })
  end

  return buf
end

--- Get total page count of a PDF file.
---@param filepath string
---@return number|nil
function M._pdf_page_count(filepath)
  local opts = config.options
  -- Try pdftoppm first (fast, just errors if page out of range)
  -- Use pdfinfo if available
  local handle = io.popen('magick identify -format "%%n" "' .. filepath .. '[0]" 2>nul')
  if handle then
    local result = handle:read("*a")
    handle:close()
    local count = tonumber(result)
    if count and count > 0 then return count end
  end

  -- Fallback: try pdfinfo
  handle = io.popen('pdfinfo "' .. filepath .. '" 2>nul')
  if handle then
    local result = handle:read("*a")
    handle:close()
    local pages = result:match("Pages:%s+(%d+)")
    if pages then return tonumber(pages) end
  end

  return nil
end

--- Set up PDF navigation keybindings on a buffer.
---@param buf number
---@param filepath string
---@param current_page number
function M._setup_pdf_keys(buf, filepath, current_page)
  local total = M._pdf_page_count(filepath)

  M._pdf_state[buf] = {
    filepath = filepath,
    page = current_page,
    total_pages = total,
  }

  local function navigate(delta)
    return function()
      local state = M._pdf_state[buf]
      if not state then return end

      local new_page = state.page + delta
      if new_page < 1 then
        vim.notify("[sixel-preview] Already on first page", vim.log.levels.INFO)
        return
      end
      if state.total_pages and new_page > state.total_pages then
        vim.notify("[sixel-preview] Already on last page", vim.log.levels.INFO)
        return
      end

      state.page = new_page
      M.open_in_buf(buf, state.filepath, { page = new_page })
    end
  end

  local map_opts = { buffer = buf, nowait = true, silent = true }

  vim.keymap.set("n", "n", navigate(1), vim.tbl_extend("force", map_opts, { desc = "Next page" }))
  vim.keymap.set("n", "p", navigate(-1), vim.tbl_extend("force", map_opts, { desc = "Previous page" }))
  vim.keymap.set("n", "J", navigate(1), vim.tbl_extend("force", map_opts, { desc = "Next page" }))
  vim.keymap.set("n", "K", navigate(-1), vim.tbl_extend("force", map_opts, { desc = "Previous page" }))
  vim.keymap.set("n", "q", function()
    local wins = vim.fn.win_findbuf(buf)
    if #wins > 0 then
      vim.api.nvim_win_close(wins[1], true)
    end
  end, vim.tbl_extend("force", map_opts, { desc = "Close preview" }))

  -- Show page indicator
  local page_info = "Page " .. current_page
  if total then
    page_info = page_info .. " / " .. total
  end
  page_info = page_info .. "  (n/p to navigate, q to close)"
  vim.notify("[sixel-preview] " .. page_info, vim.log.levels.INFO)

  -- Clean up state when buffer is deleted
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      M._pdf_state[buf] = nil
    end,
  })
end

return M
