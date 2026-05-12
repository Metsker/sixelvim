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
    -- Telescope reuses the preview buffer across entries — clear any leftover
    -- text content first so the sixel doesn't sit on top of the previous
    -- entry's content while the converter runs.
    pcall(function()
      vim.bo[bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
    end)
    -- Force a full screen redraw to wipe the previous entry's sixel pixels.
    -- Oil/:e change buffers so nvim's redraw naturally clears the whole
    -- window's cells (which clears the pixels in tmux). Telescope reuses one
    -- preview buffer, so only the rows containing text get redrawn — pixels
    -- in other rows persist and the new image draws on top of the old one.
    pcall(vim.cmd, "mode")
    preview.open_in_buf(bufnr, filepath)
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
