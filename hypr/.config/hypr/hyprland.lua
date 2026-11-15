-- Monitors (written by ~/.local/bin/hyprdori-monitors; missing on a fresh install)
if not pcall(require, "configs.generated.monitors") then
  hl.monitor({ output = "", mode = "preferred", position = "auto", scale = "auto", supports_hdr = -1 })
end

-- Input
require("configs.input")

-- Environment and autostart
require("configs.environment")
-- No cursor until the shell is up (a cold start only)
require("configs.startup-cursor")
require("configs.autostart")

-- Configuration
require("configs.general")
require("configs.decoration")
require("configs.animations")
require("configs.rules")

-- Single window (SUPER+SHIFT+S, ~/.local/bin/hyprdori-single-window): on while the flag exists
local single = io.open(os.getenv("HOME") .. "/.local/state/hyprdori/single-window")
if single then
  single:close()
  require("configs.single-window")
end
require("configs.bindings")

-- This machine's own settings, last so they win over everything above: bindings, rules, input,
-- monitors. The file is outside the repo (~/.config/hyprdori/hypr.lua) and missing unless made
-- by hand. A mistake in it leaves everything above as it is and is said in a notification.
-- After changing it: hyprctl reload. Bindings in it aren't listed in the Keybindings window
-- (it reads bindings.lua).
local own = os.getenv("HOME") .. "/.config/hyprdori/hypr.lua"
local own_file = io.open(own)
if own_file then
  own_file:close()
  local ok, problem = pcall(dofile, own)
  if not ok then
    -- in single quotes for the shell
    local text = tostring(problem):gsub("'", "'\\''")
    hl.exec_cmd("~/.local/bin/hyprdori-notify hyprland 'hypr.lua was not loaded' '" .. text .. "'")
  end
end
