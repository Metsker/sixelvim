local converters = require("sixel-preview.converters")
local preview = require("sixel-preview.preview")

local M = {}

M._attached = false

local render_timer = nil

local function pad_buffer_for_image(buf)
  -- Mini.files sizes the preview window height to buf_line_count. The
  -- "-Non-text-file---" placeholder is one line, leaving the window too
  -- short for a real image. Fill the buffer with empty lines so the
  -- subsequent height calc gives us a tall preview pane.
  local target_lines = math.max(20, vim.o.lines - 6)
  pcall(function()
    vim.bo[buf].modifiable = true
    local empty = {}
    for i = 1, target_lines do
      empty[i] = ""
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, empty)
  end)
end

local function render_preview(buf, path)
  if render_timer then
    pcall(function()
      render_timer:stop()
      render_timer:close()
    end)
  end
  render_timer = vim.defer_fn(function()
    render_timer = nil
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    pcall(vim.cmd, "mode")
    preview.open_in_buf(buf, path)
  end, 30)
end

local function expand_preview_window(win_id)
  if not (win_id and vim.api.nvim_win_is_valid(win_id)) then
    return
  end
  pcall(function()
    local cfg = vim.api.nvim_win_get_config(win_id)
    cfg.height = math.max(20, vim.o.lines - 6)
    vim.api.nvim_win_set_config(win_id, cfg)
  end)
end

--- Render image/PDF previews in the mini.files explorer preview pane as
--- sixel (requires `windows.preview = true` in mini.files' own setup).
---
--- Enabled via `setup({ integrations = { mini_files = true } })`, or call
--- `require("sixel-preview.minifiles").attach()` directly.
function M.attach()
  if M._attached then
    return
  end
  M._attached = true

  vim.api.nvim_create_autocmd("User", {
    pattern = { "MiniFilesBufferUpdate", "MiniFilesWindowUpdate" },
    group = vim.api.nvim_create_augroup("sixel-preview-minifiles", { clear = true }),
    callback = function(args)
      local buf = args.data.buf_id
      local path = vim.api.nvim_buf_get_name(buf):match("^minifiles://%d+/(.*)$")
      if not path or vim.fn.filereadable(path) ~= 1 then
        return
      end
      if not converters.detect(path) then
        return
      end
      pad_buffer_for_image(buf)
      expand_preview_window(args.data.win_id)
      render_preview(buf, path)
    end,
  })
end

return M
