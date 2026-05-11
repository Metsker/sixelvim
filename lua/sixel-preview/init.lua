local M = {}

function M.setup(opts)
  require("sixel-preview.config").setup(opts)

  local config = require("sixel-preview.config")
  local preview = require("sixel-preview.preview")
  local converters = require("sixel-preview.converters")

  -- User commands
  vim.api.nvim_create_user_command("SixelPreview", function(cmd_opts)
    local filepath = cmd_opts.args ~= "" and cmd_opts.args or vim.fn.expand("%:p")
    filepath = vim.fn.fnamemodify(filepath, ":p")
    preview.open(filepath)
  end, {
    nargs = "?",
    complete = "file",
    desc = "Preview file as sixel in a new tab",
  })

  vim.api.nvim_create_user_command("SixelPreviewClose", function()
    preview.close()
  end, {
    desc = "Close the sixel preview tab",
  })

  vim.api.nvim_create_user_command("SixelPreviewToggle", function()
    preview.toggle()
  end, {
    desc = "Toggle sixel preview for current file",
  })

  vim.api.nvim_create_user_command("SixelPreviewPage", function(cmd_opts)
    local page = tonumber(cmd_opts.args)
    if not page or page < 1 then
      vim.notify("[sixel-preview] Usage: :SixelPreviewPage <number>", vim.log.levels.ERROR)
      return
    end
    local filepath = vim.fn.expand("%:p")
    preview.open(filepath, { page = page })
  end, {
    nargs = 1,
    desc = "Preview a specific PDF page",
  })

  vim.api.nvim_create_user_command("SixelClearCache", function()
    require("sixel-preview.render").clear_cache()
    vim.notify("[sixel-preview] Cache cleared", vim.log.levels.INFO)
  end, {
    desc = "Clear sixel render cache",
  })

  -- Auto-preview: intercept BufReadCmd for supported file types
  -- This fires when any buffer tries to load an image/PDF (e.g. from Snacks explorer)
  if config.options.auto_preview ~= false then
    local patterns = {}
    for _, exts in pairs(config.options.filetypes) do
      for _, ext in ipairs(exts) do
        table.insert(patterns, "*." .. ext)
        table.insert(patterns, "*." .. ext:upper())
      end
    end

    local group = vim.api.nvim_create_augroup("sixel-preview-auto", { clear = true })

    vim.api.nvim_create_autocmd("BufReadCmd", {
      group = group,
      pattern = patterns,
      callback = function(ev)
        local filepath = vim.api.nvim_buf_get_name(ev.buf)
        if filepath == "" then return end
        filepath = vim.fn.fnamemodify(filepath, ":p")

        -- Only handle files that actually exist on disk
        if vim.fn.filereadable(filepath) ~= 1 then return end

        -- Render sixel directly in this buffer (the one the explorer opened)
        preview.open_in_buf(ev.buf, filepath)
      end,
    })

    -- Clear sixel artifacts when leaving a preview buffer
    vim.api.nvim_create_autocmd({ "BufLeave", "TabLeave" }, {
      group = group,
      callback = function(ev)
        if vim.bo[ev.buf].filetype == "sixel-preview" then
          -- Force a full screen redraw to clear sixel artifacts
          vim.schedule(function()
            vim.cmd("mode")
          end)
        end
      end,
    })

    -- Re-render when returning to a preview buffer
    vim.api.nvim_create_autocmd({ "BufEnter", "TabEnter" }, {
      group = group,
      callback = function(ev)
        if vim.bo[ev.buf].filetype == "sixel-preview" then
          -- Prefer the tracked filepath: for :SixelPreview the buffer name is
          -- the tab title ("Preview: img.png"), not a real path.
          local filepath = vim.b[ev.buf].sixel_preview_filepath
          if not filepath or filepath == "" then
            filepath = vim.api.nvim_buf_get_name(ev.buf)
          end
          if not filepath or filepath == "" then return end
          filepath = vim.fn.fnamemodify(filepath, ":p")
          if vim.fn.filereadable(filepath) == 1 then
            vim.schedule(function()
              preview.open_in_buf(ev.buf, filepath)
            end)
          end
        end
      end,
    })
  end
end

return M
