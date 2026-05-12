local M = {}

M.defaults = {
  -- Conversion backends
  converters = {
    image = "magick", -- "magick" (ImageMagick) or "chafa"
    pdf = "pdftoppm", -- "pdftoppm" (poppler) or "magick"
  },

  -- Sixel output settings
  sixel = {
    max_width = 800,
    max_height = 600,
    background = "none", -- "none", "black", "white"
    cell_size = { 8, 16 }, -- { width, height } in pixels per cell, used for positioning
  },

  -- PDF-specific
  pdf = {
    page = 1,     -- default page to render
    dpi = 150,    -- resolution for rasterization
  },

  -- Auto-preview when opening supported files (e.g. from file explorer)
  auto_preview = true,

  -- Skip rendering when a floating window overlaps the preview window. Useful
  -- to prevent sixel pixels from leaking out from behind UIs like oil's float.
  -- Set to false to draw sixel regardless of overlapping floats.
  window_overlap_clear = true,

  -- Tab behavior
  tab = {
    close_on_leave = false, -- close preview tab when you switch away
    reuse = true,           -- reuse existing preview tab if open
    title = "Preview",      -- tab title prefix
  },

  -- Supported file extensions (mapped to converter type)
  filetypes = {
    image = { "png", "jpg", "jpeg", "gif", "bmp", "webp", "tiff", "ico", "svg" },
    pdf = { "pdf" },
  },

  -- Dependency overrides (if not on PATH)
  bin = {
    magick = "magick",
    pdftoppm = "pdftoppm",
    chafa = "chafa",
  },
}

M.options = {}

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", {}, M.defaults, opts or {})
end

return M
