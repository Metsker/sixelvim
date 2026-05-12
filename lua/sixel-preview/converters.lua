local config = require("sixel-preview.config")

local M = {}

--- Build the shell command to convert a file to sixel output.
--- Returns the command as a string list suitable for vim.fn.jobstart().
---@param filepath string Absolute path to the source file
---@param filetype string "image" or "pdf"
---@param size? { max_width: number, max_height: number } Override sixel size
---@return string[] cmd, string|nil error
function M.build_cmd(filepath, filetype, size)
  local opts = config.options
  local sixel = size or opts.sixel

  if filetype == "image" then
    return M._image_cmd(filepath, sixel)
  elseif filetype == "pdf" then
    return M._pdf_cmd(filepath, sixel, opts.pdf)
  end

  return {}, "Unsupported filetype"
end

--- Build command for image → sixel conversion.
---@param filepath string
---@param sixel table
---@return string[] cmd, string|nil error
function M._image_cmd(filepath, sixel)
  local opts = config.options
  local backend = opts.converters.image

  if backend == "magick" then
    local geometry = sixel.max_width .. "x" .. sixel.max_height .. ">"
    return {
      opts.bin.magick,
      filepath,
      "-resize", geometry,
      "sixel:-",
    }, nil

  elseif backend == "chafa" then
    -- chafa's --size is in *cells*, not pixels — convert before passing.
    -- chafa writes sixel to stdout by default; render.lua captures it.
    local cell_w = sixel.cell_w
      or (sixel.cell_size and sixel.cell_size[1])
      or 8
    local cell_h = sixel.cell_h
      or (sixel.cell_size and sixel.cell_size[2])
      or 16
    local cols = math.max(1, math.floor(sixel.max_width / cell_w))
    local rows = math.max(1, math.floor(sixel.max_height / cell_h))
    return {
      opts.bin.chafa,
      "--format", "sixels",
      "--size", cols .. "x" .. rows,
      -- Cap the palette to sixel's native max (256) instead of chafa's
      -- truecolor default, which roughly halves the payload at the same
      -- preview dimensions. Configurable via `sixel.chafa_colors`.
      "--colors", tostring((opts.sixel and opts.sixel.chafa_colors) or 256),
      -- Fill the view consistently regardless of source pixel dimensions,
      -- so small images upscale to the requested cell area instead of
      -- rendering tiny at their native size.
      "--scale", "max",
      filepath,
    }, nil
  end

  return {}, "Unknown image backend: " .. backend
end

--- Build command for PDF → sixel conversion (two-step: PDF → PNG → sixel).
---@param filepath string
---@param sixel table
---@param pdf_opts table
---@return string[] cmd, string|nil error
function M._pdf_cmd(filepath, sixel, pdf_opts)
  local opts = config.options
  local backend = opts.converters.pdf
  local geometry = sixel.max_width .. "x" .. sixel.max_height .. ">"

  if backend == "pdftoppm" then
    -- Two-step: pdftoppm → temp PNG → magick → sixel output
    local page = tostring(pdf_opts.page)
    local dpi = tostring(pdf_opts.dpi)
    local tmp_base = os.tmpname()
    local tmp_png = tmp_base .. ".png"

    return {
      "cmd", "/c",
      opts.bin.pdftoppm,
      "-png", "-f", page, "-l", page,
      "-r", dpi, "-singlefile",
      '"' .. filepath .. '"',
      '"' .. tmp_base .. '"',
      "&&",
      opts.bin.magick,
      '"' .. tmp_png .. '"',
      "-resize", '"' .. geometry .. '"',
      "sixel:-",
      "&",
      "del", '"' .. tmp_png .. '"',
      "2>nul",
    }, nil

  elseif backend == "magick" then
    local page_index = tostring(pdf_opts.page - 1)
    return {
      opts.bin.magick,
      "-density", tostring(pdf_opts.dpi),
      filepath .. "[" .. page_index .. "]",
      "-resize", geometry,
      "sixel:-",
    }, nil
  end

  return {}, "Unknown PDF backend: " .. backend
end

--- Detect whether a file extension maps to a known converter type.
---@param filepath string
---@return string|nil filetype "image", "pdf", or nil
function M.detect(filepath)
  local ext = filepath:match("%.(%w+)$")
  if not ext then return nil end
  ext = ext:lower()

  local ft_map = config.options.filetypes
  for category, extensions in pairs(ft_map) do
    for _, e in ipairs(extensions) do
      if e == ext then return category end
    end
  end

  return nil
end

return M
