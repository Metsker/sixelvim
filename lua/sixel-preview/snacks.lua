local converters = require("sixel-preview.converters")
local preview = require("sixel-preview.preview")

local M = {}

M._attached = false

--- Render snacks picker image/PDF previews as sixel. Snacks' built-in image
--- preview only speaks the kitty graphics protocol, so on a sixel terminal we
--- wrap the default `file` previewer used by the file-based pickers.
---
--- Enabled via `setup({ integrations = { snacks_picker = true } })`, or call
--- `require("sixel-preview.snacks").attach()` directly after snacks is loaded.
function M.attach()
  if M._attached then
    return
  end
  local ok, Snacks = pcall(require, "snacks")
  if not ok then
    vim.notify("[sixel-preview] snacks.nvim not found; snacks_picker integration disabled", vim.log.levels.WARN)
    return
  end
  M._attached = true

  local snacks_preview = require("snacks.picker.preview")
  local picker_util = require("snacks.picker.util")
  local orig_file = snacks_preview.file

  -- The image/PDF currently shown in a picker preview (or nil for a text
  -- preview / closed picker). Tracked so window events can re-draw it.
  local current ---@type { buf: integer, path: string }?

  local function draw()
    local img = current
    if not img then
      return
    end
    -- Lazily forget the image once its scratch buffer is gone or hidden
    -- (e.g. the picker closed), so we never draw sixel into a stray window.
    if not vim.api.nvim_buf_is_valid(img.buf) or vim.fn.bufwinid(img.buf) == -1 then
      current = nil
      return
    end
    preview.open_in_buf(img.buf, img.path)
  end

  -- Sixel pixels live in the terminal's graphics layer, not nvim's cell grid,
  -- so any repaint of the preview window wipes them -- the image renders once
  -- then "blinks and disappears". Snacks repaints on its own window events, so
  -- we re-draw on the same ones (debounced past snacks' handler). This is how
  -- Snacks.image and the mini.files preview keep their images alive.
  local heal = Snacks.util.debounce(draw, { ms = 80 })
  vim.api.nvim_create_autocmd(
    { "WinScrolled", "WinResized", "VimResized", "WinEnter", "BufWinEnter", "CursorMoved", "CursorMovedI" },
    {
      group = vim.api.nvim_create_augroup("sixel-preview-snacks", { clear = true }),
      callback = function()
        if current then
          heal()
        end
      end,
    }
  )

  snacks_preview.file = function(ctx)
    local path = picker_util.path(ctx.item)
    -- Only intercept real image/PDF files on disk; already-loaded buffers
    -- and everything else fall through to snacks' default previewer.
    local is_loaded_buf = ctx.item.buf and vim.api.nvim_buf_is_loaded(ctx.item.buf)
    if path and not is_loaded_buf and converters.detect(path) then
      local buf = ctx.preview:scratch()
      ctx.preview:set_title(ctx.item.title or vim.fn.fnamemodify(path, ":t"))
      current = { buf = buf, path = path }
      -- Clear the previous image's pixels now, then draw the new one once
      -- snacks has finished repainting (debounced).
      pcall(vim.cmd, "mode")
      heal()
      return
    end
    current = nil
    return orig_file(ctx)
  end
end

return M
