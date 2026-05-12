local converters = require("sixel-preview.converters")
local preview = require("sixel-preview.preview")

local M = {}

--- Drop-in replacement for telescope's `buffer_previewer_maker`. For image
--- and PDF entries, renders sixel into the preview window. For everything
--- else, delegates to telescope's default `file_maker`.
---
--- Usage:
---   require("telescope").setup({
---     defaults = {
---       buffer_previewer_maker = require("sixel-preview.telescope").previewer_maker,
---     },
---   })
---
---@param filepath string
---@param bufnr number telescope's preview buffer
---@param opts table telescope previewer opts ({ bufname, winid, preview, file_encoding })
function M.previewer_maker(filepath, bufnr, opts)
  if converters.detect(filepath) then
    -- Clear any leftover text content immediately (synchronously) so we don't
    -- briefly show the previous entry's text under the new image.
    pcall(function()
      vim.bo[bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
    end)
    -- Defer the actual render. Telescope's preview_fn schedules a
    -- `win_set_buf_noautocmd` to put fresh buffers into the preview window,
    -- and `define_preview` (which calls us) runs BEFORE that schedule. If we
    -- ran open_in_buf synchronously, `_find_buf_win` would return nil and the
    -- render would silently abort — which is why first visits to an entry
    -- show an empty preview while revisits (where telescope uses the sync
    -- buffer-reuse branch) work.
    -- The mode call also goes inside the defer, so the full-screen clear that
    -- wipes the previous entry's sixel pixels happens right before the new
    -- render — no race against telescope's intervening redraws.
    vim.schedule(function()
      pcall(vim.cmd, "mode")
      preview.open_in_buf(bufnr, filepath)
    end)
  else
    require("telescope.previewers").buffer_previewer_maker(filepath, bufnr, opts)
  end
end

--- Build a standalone telescope previewer (for users who don't want to override
--- the global default). Pass it to a specific picker:
---
---   require("telescope.builtin").find_files({
---     previewer = require("sixel-preview.telescope").previewer(),
---   })
---@param opts? table forwarded to telescope.previewers.new_buffer_previewer
---@return table
function M.previewer(opts)
  opts = opts or {}
  local previewers = require("telescope.previewers")
  local from_entry = require("telescope.from_entry")
  return previewers.new_buffer_previewer(vim.tbl_extend("force", {
    title = "Sixel Preview",
    define_preview = function(self, entry)
      local p = from_entry.path(entry, true, false)
      if not p or p == "" then return end
      M.previewer_maker(p, self.state.bufnr, {
        bufname = self.state.bufname,
        winid = self.state.winid,
      })
    end,
  }, opts))
end

return M
