-- Layer Rules
hl.layer_rule({
  match = { class = "^(quickshell-.*)$" },
  blur = true,
  ignore_alpha = 0.2,
})

-- Quickshell animates its dropdowns and tooltips itself
hl.layer_rule({
  match = {
    class = "^(quickshell-dropdown|quickshell-tooltip|quickshell-transition|quickshell-controlcenter|quickshell-appmenu)$",
  },
  no_anim = true,
})

-- Ignore maximize requests (as in Hyprland's example config): apps that
-- restore a saved maximized state (LibreOffice opening a document) would
-- otherwise cover the workspace until they're resized. SUPER+F still works.
hl.window_rule({
  name = "no-maximize",
  match = { class = ".*" },
  suppress_event = "maximize",
})

-- XWayland Settings
hl.config({
  xwayland = {
    force_zero_scaling = true,
  },
})
-- XWayland windows: opaque, no blur
hl.window_rule({
  name = "xwayland",
  match = { xwayland = true },
  no_blur = true,
  opaque = true,
})

-- The shell's windows (Settings, Keybindings) draw their own transparency
-- (Settings > Style > Shell opacity): Hyprland's window opacity is overridden to full
hl.window_rule({
  name = "quickshell-opaque",
  match = { class = "^org\\.quickshell$" },
  opacity = "1.0 override 1.0 override",
})

-- Browsers opaque: pages and video behind a see-through window don't read well
hl.window_rule({
  name = "browsers-opaque",
  match = { class = "^(brave-browser|chromium|google-chrome|firefox|zen|librewolf|vivaldi-stable|brave-.*|chrome-.*)$" },
  opacity = "1.0 override 1.0 override",
})

-- Floating windows sized to the screen they open on: fit = { width, height }, each a fraction
-- of the area below the bar within the outer gaps (1 is the height a lone tiled window has),
-- min_height in px for short screens. The rule floats and centers the window and opens it at
-- about that size (fractions of the whole screen); fit_window() below makes it exact when it
-- opens, from the bar's space, the outer gaps and the border at that moment (Settings, Work and
-- Game, Displays > Text size). The rule tags the window with its fit, so the matching is the
-- rule's alone. Dialogs a window opens itself already float, centered over it (Hyprland).
local function fit_rule(spec)
  local w, h = spec.fit[1], spec.fit[2]
  local min_h = spec.min_height or 0
  hl.window_rule({
    name = spec.name,
    match = spec.match,
    float = true,
    center = true,
    size = ("monitor_w*%g max(%d,monitor_h*%g)"):format(w, min_h, h),
    tag = ("+fit:%g:%g:%d"):format(w, h, min_h),
  })
end

local function fit_window(window)
  if not window.floating then
    return
  end
  local tags = window.tags
  local list = type(tags) == "table" and tags or { tags }
  for _, tag in ipairs(list) do
    local fw, fh, fmin = tostring(tag):match("^fit:([%d.]+):([%d.]+):(%d+)")
    if fw then
      local w, h, min_h = tonumber(fw) or 0, tonumber(fh) or 0, tonumber(fmin) or 0
      local monitor = window.monitor
      if not monitor then
        return
      end
      local reserved = monitor.reserved
      local gaps = hl.get_config("general.gaps_out")
      if type(gaps) ~= "table" then
        gaps = { top = gaps, right = gaps, bottom = gaps, left = gaps }
      end
      local border = hl.get_config("general.border_size") or 0
      local area_w = monitor.width / monitor.scale - reserved.left - reserved.right - gaps.left - gaps.right
      local area_h = monitor.height / monitor.scale - reserved.top - reserved.bottom - gaps.top - gaps.bottom
      local width = math.floor(area_w * w - 2 * border)
      local height = math.floor(math.max(min_h, area_h * h - 2 * border))
      height = math.min(height, math.floor(area_h - 2 * border))
      hl.dispatch(hl.dsp.window.resize({ x = width, y = height, window = window }))
      hl.dispatch(hl.dsp.window.center({ window = window }))
      return
    end
  end
end

-- After the window is placed: resizing it in window.open_early crashes Hyprland 0.57
hl.on("window.open", fit_window)

-- Quickshell's Settings and Keybindings: floating and centered (the shell reopens one that gets tiled)
hl.window_rule({
  name = "quickshell-windows",
  match = { class = "^org\\.quickshell$", title = "^(Settings|Keybindings)$" },
  float = true,
  center = true,
})

-- System Information (hyprdori-sysinfo): fastfetch in kitty, at the size kitty opens with
hl.window_rule({
  name = "sysinfo",
  match = { class = "^hyprdori-sysinfo$" },
  float = true,
  center = true,
})

-- System monitor (hyprdori-sysmon): btop in kitty, one at a time
fit_rule({ name = "sysmon", match = { class = "^hyprdori-sysmon$" }, fit = { 0.6, 0.65 } })

-- File chooser and other portal windows (they open without a parent window)
hl.window_rule({
  name = "xdg-desktop-portal-gtk",
  match = { class = ".*xdg-desktop-portal-gtk.*" },
  pin = true,
})
fit_rule({ name = "xdg-desktop-portal-gtk-size", match = { class = ".*xdg-desktop-portal-gtk.*" }, fit = { 0.5, 0.6 } })

-- hyprdori-present windows: the boot screens' and the system's updates (hyprdori-theme-boot
-- --window, hyprdori-update --window); hyprdori-ui grows them to fit what they show
hl.window_rule({
  name = "hyprdori-window",
  match = { class = "^(hyprdori-window)$" },
  float = true,
  center = true,
  size = "900 600",
})

-- Qt settings
fit_rule({ name = "qt-settings", match = { class = "^(qt5ct|qt6ct|kvantummanager)$" }, fit = { 0.4, 0.55 } })

-- Modal windows without a parent window (one with a parent is already floated and centered)
hl.window_rule({
  name = "modal",
  match = { modal = true },
  float = true,
  center = true,
})

-- Thunderbird: the main window tiles; writing, replying and forwarding float. Those windows open
-- titled "Write: ..."; the main window's first title varies ("Mozilla Thunderbird", "Home - ...").
hl.window_rule({
  name = "thunderbird",
  match = { class = "^org\\.mozilla\\.Thunderbird$" },
  opaque = true,
})
fit_rule({
  name = "thunderbird-write",
  match = { class = "^org\\.mozilla\\.Thunderbird$", initial_title = "^Write: .*" },
  fit = { 0.5, 0.8 },
})

-- X11 apps' own floating windows (LibreOffice's loading window, palettes) open where the app
-- places them, often in a corner: centered as they open. Left out: apps whose menus are floating
-- X11 windows this rule would center too (DaVinci Resolve's, Remmina's ⋮ menu), and Steam, whose
-- menus are of that kind and whose titled windows have their own rule. More such apps go in both
-- lists below.
hl.window_rule({
  name = "xwayland-floating-center",
  match = { xwayland = true, float = true, class = "negative:^(vlc|steam|resolve|org\\.remmina\\.Remmina)$" },
  center = true,
})

-- Those apps' loading windows: a rule can't tell one from the app's menus (Resolve's have the same
-- title and class), but it is the app's only window when it opens, and a menu opens beside the
-- main window. So a floating window of theirs is centered when no other window of its process is
-- open. That happens once it is shown (a window can't be moved before: Hyprland 0.57 crashes),
-- so it is seen moving to the center.
local center_lone = { resolve = true, ["org.remmina.Remmina"] = true }

local function center_lone_x11(window)
  if not (window.xwayland and window.floating and center_lone[window.class]) then
    return
  end
  for _, other in ipairs(hl.get_windows()) do
    if other.pid == window.pid and other.address ~= window.address and other.mapped then
      return
    end
  end
  hl.dispatch(hl.dsp.window.center({ window = window }))
end

hl.on("window.open", center_lone_x11)

-- Bitwarden (the browser extension's window): its own fixed layout
hl.window_rule({
  name = "bitwarden",
  match = { initial_title = "_crx_.*" },
  float = true,
  center = true,
  min_size = { 370, 565 },
  max_size = { 370, 565 },
})

-- Steam: the main window ("Steam") tiles; news, friends, settings and the rest float at the size
-- Steam gives them, centered. Its menus are untitled windows of the same class: floating, where
-- Steam puts them.
hl.window_rule({
  name = "steam",
  match = { class = "^steam$" },
  no_blur = true,
  opaque = true,
})
-- No border: Steam clears a window's content a moment before it closes it, which left the
-- border drawn around nothing; Steam draws its own frame on these windows
hl.window_rule({
  name = "steam-windows",
  match = { class = "^steam$", title = "negative:^Steam$" },
  float = true,
  border_size = 0,
})
hl.window_rule({
  name = "steam-center",
  match = { class = "^steam$", title = "negative:^(Steam)?$" },
  center = true,
})

-- Apps floating at a size relative to the screen
local fitted = {
  { name = "zathura", class = "^org\\.pwmt\\.zathura$", fit = { 0.5, 1 } },
  { name = "qBittorrent", class = "^org\\.qbittorrent\\.qBittorrent$", title = ".*qBittorrent v.*", fit = { 0.65, 0.7 }, min_height = 560 },
  { name = "coolercontrol", class = "^org\\.coolercontrol\\.CoolerControl$", fit = { 0.65, 0.5 }, min_height = 560 },
  { name = "swayimg", class = "^swayimg$", fit = { 0.7, 0.8 } },
  { name = "openrgb", class = "^org\\.openrgb\\.OpenRGB$", fit = { 0.6, 0.6 } },
  { name = "rog-control-center", class = "^org..*rog-control-center$", fit = { 0.6, 0.6 } },
  { name = "whatsapp", class = "^(brave|chrome)-web\\.whatsapp\\.com__.*", fit = { 0.6, 0.7 } },
  { name = "cliamp", class = "^cliamp$", fit = { 0.5, 0.55 } },
  { name = "localsend", class = "^org\\.localsend\\.localsend_app$", fit = { 0.45, 0.5 } },
  { name = "virt-manager", class = "^virt-manager$", title = "^Virtual Machine Manager$", fit = { 0.6, 0.7 } },
  -- a virtual machine's window ("NAME on QEMU/KVM") and the rest
  { name = "virt-manager-windows", class = "^virt-manager$", title = "negative:^Virtual Machine Manager$", fit = { 0.5, 0.6 } },
  { name = "nvidia-settings", class = "^nvidia-settings$", fit = { 0.5, 0.6 } },
  { name = "nm-connection-editor", class = "^nm-connection-editor$", fit = { 0.5, 0.6 } },
  { name = "pavucontrol", class = "^org\\.pulseaudio\\.pavucontrol$", fit = { 0.4, 0.55 } },
  { name = "blueman-manager", class = "^blueman-manager$", fit = { 0.4, 0.55 } },
  { name = "protonqt", class = "^net\\.davidotek\\.pupgui2$", fit = { 0.4, 0.55 } },
  { name = "cameractrls", class = "^hu\\.irl\\.cameractrls$", fit = { 0.4, 0.55 } },
}

for _, app in ipairs(fitted) do
  fit_rule({ name = app.name, match = { class = app.class, title = app.title }, fit = app.fit, min_height = app.min_height })
end

-- Apps floating at their own size, centered
local floating = {
  { name = "brasero", class = "^brasero$" },
  { name = "timeshift", class = "^timeshift-gtk$" },
  { name = "frame-checker", class = "^Frame Checker$" },
  { name = "ubisoft-connect", title = "^Ubisoft Connect$" },
  { name = "rockstar", title = "^Rockstar Games.*" },
}

for _, app in ipairs(floating) do
  hl.window_rule({
    name = app.name,
    match = { class = app.class, title = app.title },
    float = true,
    center = true,
  })
end

-- Apps drawn opaque and without blur: video, games, remote desktops, editors
local opaque = {
  { name = "vlc", class = "^vlc$" },
  { name = "lutris", class = "^net\\.lutris\\.Lutris$" },
  { name = "heroic", class = ".*heroic.*" },
  { name = "gimp", class = "^gimp" },
  { name = "remmina", class = "^org\\.remmina\\.Remmina$" },
  { name = "davinci", class = "^resolve$" },
  { name = "netflix", class = "^(brave|chrome)-netflix.*" },
  { name = "eontv", class = "^(brave|chrome)-eon.*" },
}

for _, app in ipairs(opaque) do
  hl.window_rule({
    name = app.name,
    match = { class = app.class },
    no_blur = true,
    opaque = true,
  })
end

-- DaVinci Resolve asks again and again for its open dialog to be focused. Granting it
-- (misc.focus_on_activate) moves the cursor back onto the dialog each time the cursor leaves it,
-- so the cursor seemed held inside until the dialog closed. Its requests are ignored.
hl.window_rule({
  name = "davinci-activate",
  match = { class = "^resolve$" },
  focus_on_activate = false,
})

-- Remmina's main window floats; its sessions tile
hl.window_rule({
  name = "remmina-main",
  match = { class = "^org\\.remmina\\.Remmina$", title = "^Remmina Remote Desktop Client$" },
  float = true,
  center = true,
})

-- Games: idle held off while one runs, and no vsync for lower input latency (general.allow_tearing)
hl.window_rule({
  name = "games",
  match = { class = "^steam_app.*" },
  idle_inhibit = "always",
})
hl.window_rule({
  name = "games-tearing",
  match = { class = "^(steam_app_.*|gamescope)$" },
  immediate = true,
})
