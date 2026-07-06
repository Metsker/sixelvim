# sixel-preview.nvim

Preview images and PDFs directly inside Neovim using [Sixel](https://en.wikipedia.org/wiki/Sixel) graphics.

Built for **Windows Terminal 1.22+**, but works on any sixel-capable terminal (WezTerm, foot, mlterm, etc.).

![Neovim](https://img.shields.io/badge/Neovim-%3E%3D0.9-green?logo=neovim)
![License](https://img.shields.io/badge/License-MIT-blue)
![Platform](https://img.shields.io/badge/Platform-Windows%20%7C%20Linux%20%7C%20macOS-lightgrey)

### Image Preview
![Image preview](assets/image_preview.png)

### PDF Preview
![PDF preview](assets/pdf_preview.png)

## Features

- **Image preview** — PNG, JPG, GIF, SVG, WebP, BMP, TIFF, ICO
- **PDF preview** with page-by-page navigation (`n`/`p`/`J`/`K`)
- **File explorer integration** — auto-previews when you open an image/PDF from Snacks explorer, neo-tree, oil.nvim, etc.
- **Picker integrations** — opt-in sixel previews inside the snacks.nvim picker, the mini.files preview pane, and telescope
- **Dynamic sizing** — detects your terminal's pixel dimensions and scales images to fit
- **Render caching** — in-memory cache with mtime-based invalidation
- **Clean tab switching** — sixel artifacts are cleared when you switch tabs, re-rendered when you return
- **`:checkhealth`** — verifies all dependencies and terminal support

## Requirements

| Dependency | Required | Notes |
|---|---|---|
| **Neovim** >= 0.9 | Yes | 0.10+ recommended |
| **Sixel-capable terminal** | Yes | Windows Terminal 1.22+, WezTerm, foot, mlterm |
| **[ImageMagick](https://imagemagick.org/script/download.php)** 7+ | Yes | Must have sixel delegate (check with `:checkhealth`) |
| **[poppler-utils](https://poppler.freedesktop.org/)** | For PDFs | Provides `pdftoppm` for fast PDF rasterization |

### Quick install (Windows)

```powershell
# Using scoop
scoop install imagemagick
scoop install poppler

# Or using winget
winget install ImageMagick.ImageMagick
```

### Quick install (Linux/macOS)

```bash
# Ubuntu/Debian
sudo apt install imagemagick poppler-utils

# macOS
brew install imagemagick poppler
```

## Installation

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
-- lua/plugins/sixel-preview.lua
return {
  "truashamu/sixel-preview.nvim",
  event = "VeryLazy",
  cmd = { "SixelPreview", "SixelPreviewToggle", "SixelPreviewClose", "SixelPreviewPage" },
  keys = {
    { "<leader>sp", "<cmd>SixelPreviewToggle<cr>", desc = "Toggle sixel preview" },
    { "<leader>sP", "<cmd>SixelPreviewClose<cr>", desc = "Close sixel preview" },
  },
  opts = {},
}
```

### Manual

Clone into your Neovim packages directory:

```bash
git clone https://github.com/truashamu/sixel-preview.nvim \
  ~/.local/share/nvim/site/pack/plugins/start/sixel-preview.nvim
```

## Usage

### Commands

| Command | Description |
|---|---|
| `:SixelPreview [file]` | Preview a file (defaults to current buffer's file) |
| `:SixelPreviewToggle` | Toggle preview for current file |
| `:SixelPreviewClose` | Close the preview tab |
| `:SixelPreviewPage 3` | Jump to a specific PDF page |
| `:SixelClearCache` | Clear the render cache |

### PDF Navigation

When previewing a PDF, these buffer-local keybindings are active:

| Key | Action |
|---|---|
| `n` / `J` | Next page |
| `p` / `K` | Previous page |
| `q` | Close preview |

### Auto-Preview

When `auto_preview` is enabled (the default), opening any supported file from a file explorer will automatically render it as sixel. Works out of the box with:

- [Snacks explorer](https://github.com/folke/snacks.nvim)
- [neo-tree](https://github.com/nvim-neo-tree/neo-tree.nvim)
- [oil.nvim](https://github.com/stevearc/oil.nvim)
- Any plugin that triggers `BufReadCmd`

### Picker / Explorer Integrations

Some plugins draw previews in their own scratch windows instead of loading the
file through `BufReadCmd`. Opt-in hooks are available for those:

```lua
require("sixel-preview").setup({
  integrations = {
    snacks_picker = true, -- snacks.nvim picker: image/PDF previews render as sixel
    mini_files = true,    -- mini.files: preview pane renders images/PDFs as sixel
    telescope = true,     -- telescope: default buffer previewer renders as sixel
  },
})
```

All integrations are fully optional: they default to off, their code is only
loaded when enabled, and a missing target plugin just logs a warning.

- **snacks_picker** wraps the picker's default `file` previewer and re-draws
  the image after snacks' own repaints (sixel pixels live in the terminal's
  graphics layer, so any window repaint wipes them).
- **mini_files** requires `windows.preview = true` in mini.files' own setup.
- **telescope** routes telescope's default `buffer_previewer_maker` through
  the sixel previewer, regardless of whether telescope's setup runs before or
  after this plugin's. A user-supplied maker in telescope's setup wins.

For finer control of telescope you can skip the flag and wire it manually -
globally or per picker:

```lua
require("telescope").setup({
  defaults = {
    buffer_previewer_maker = require("sixel-preview.telescope").previewer_maker,
  },
})

require("telescope.builtin").find_files({
  previewer = require("sixel-preview.telescope").previewer(),
})
```

## Configuration

These are the defaults — you only need to set what you want to change:

```lua
require("sixel-preview").setup({
  -- Conversion backends
  converters = {
    image = "magick",   -- "magick" (ImageMagick) or "chafa"
    pdf = "pdftoppm",   -- "pdftoppm" (poppler) or "magick"
  },

  -- Sixel output sizing (used as fallback when dynamic detection fails)
  sixel = {
    max_width = 800,
    max_height = 600,
    background = "none",  -- "none", "black", "white"
    cell_size = { 8, 16 }, -- fallback { width, height } in pixels per cell
  },

  -- PDF-specific
  pdf = {
    page = 1,     -- default starting page
    dpi = 150,    -- rasterization resolution
  },

  -- Auto-preview when opening supported files
  auto_preview = true,

  -- Opt-in picker/explorer integrations
  integrations = {
    snacks_picker = false, -- wrap the snacks.nvim picker `file` previewer
    mini_files = false,    -- render the mini.files explorer preview pane
    telescope = false,     -- route telescope's default buffer previewer
  },

  -- Tab behavior
  tab = {
    close_on_leave = false, -- close preview tab when switching away
    reuse = true,           -- reuse existing preview tab
    title = "Preview",      -- tab title prefix
  },

  -- Supported file types
  filetypes = {
    image = { "png", "jpg", "jpeg", "gif", "bmp", "webp", "tiff", "ico", "svg" },
    pdf = { "pdf" },
  },

  -- Binary overrides (if not on PATH)
  bin = {
    magick = "magick",
    pdftoppm = "pdftoppm",
    chafa = "chafa",
  },
})
```

## Health Check

Run `:checkhealth sixel-preview` to verify your setup:

```
sixel-preview.nvim
- OK Neovim >= 0.9
- OK Running inside Windows Terminal (WT_SESSION detected)
- OK ImageMagick found: ImageMagick 7.1.2-Q16-HDRI
- OK ImageMagick has sixel support
- OK pdftoppm found (poppler-utils)
```

## How It Works

1. **File detection** — extension mapped to converter type (image or PDF)
2. **Conversion** — ImageMagick converts to sixel format, writing to a temp file
3. **Display** — raw sixel escape sequences sent to the terminal via `nvim_chan_send`
4. **Positioning** — ANSI cursor positioning places the image inside the correct Neovim window
5. **Caching** — rendered sixel data cached in memory, keyed on filepath + mtime + dimensions

For PDFs: `pdftoppm` rasterizes a page to PNG → ImageMagick converts to sixel.

### Dynamic Sizing

On Windows, the plugin detects terminal pixel dimensions via the Win32 `GetForegroundWindow` + `GetClientRect` API (through LuaJIT FFI). On Unix, it uses the standard `TIOCGWINSZ` ioctl. This means images and PDFs scale properly to your window size — no hardcoded dimensions.
