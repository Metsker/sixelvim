local M = {}

function M.setup(opts)
  require("sixel-preview.config").setup(opts)

  local config = require("sixel-preview.config")
  local preview = require("sixel-preview.preview")
  local converters = require("sixel-preview.converters")
  local render = require("sixel-preview.render")

  -- Propagate configurable cache budget into the render module.
  if config.options.cache and config.options.cache.max_bytes then
    render._cache_max_bytes = config.options.cache.max_bytes
  end

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

        local buf = ev.buf
        -- Clear any leftover content the explorer may have written into the
        -- buffer before BufReadCmd fired, so we never briefly show stale text
        -- under the new image.
        pcall(function()
          vim.bo[buf].modifiable = true
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
        end)
        -- Defer the render and run `mode` first. Mirrors the telescope path:
        -- the deferral lets nvim's post-read autocmds finish before we touch
        -- buffer/window state, and `mode` wipes any prior sixel pixels so the
        -- new image isn't drawn on top of the previous one.
        vim.schedule(function()
          pcall(vim.cmd, "mode")
          preview.open_in_buf(buf, filepath)
        end)
      end,
    })

    -- Clear sixel artifacts when leaving a preview buffer
    vim.api.nvim_create_autocmd({ "BufLeave", "TabLeave" }, {
      group = group,
      callback = function(ev)
        if vim.bo[ev.buf].filetype == "sixel-preview" then
          local buf = ev.buf
          vim.schedule(function()
            -- Oil's preview briefly focuses the preview window and switches
            -- back to oil, firing BufLeave even though the preview buffer is
            -- still on-screen. Clearing then would wipe a freshly-rendered
            -- sixel (the cache-hit path schedules render-to-screen *before*
            -- this BufLeave runs), causing a one-frame blink.
            for _, win in ipairs(vim.api.nvim_list_wins()) do
              if vim.api.nvim_win_get_buf(win) == buf then
                return
              end
            end
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
            local buf = ev.buf
            -- Same pattern as BufReadCmd / telescope: clear stale text sync,
            -- then defer the render with a `mode` call to wipe the previous
            -- sixel pixels before drawing the new image.
            pcall(function()
              vim.bo[buf].modifiable = true
              vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
            end)
            vim.schedule(function()
              pcall(vim.cmd, "mode")
              preview.open_in_buf(buf, filepath)
            end)
          end
        end
      end,
    })
  end
end

return M
