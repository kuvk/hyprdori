import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import Quickshell.Widgets
import qs.config
import qs.components
import qs.services

// Name of the focused app, shown on the focused monitor
Row {
    id: root

    required property ShellScreen screen

    readonly property Toplevel toplevel: ToplevelManager.activeToplevel
    // The shell's own windows all have Quickshell's app id, and the script windows
    // (hyprdori-present window: kitty) all have hyprdori-window: show their title and a
    // matching icon instead of "Quickshell" or "hyprdori-window"
    readonly property bool shellWindow: toplevel?.appId === "org.quickshell" || toplevel?.appId === "hyprdori-window"
    readonly property var shellIcons: ({
            "Settings": Icons.cog,
            "Keybindings": Icons.keyboard,
            "System Information": Icons.info,
            "Update": Icons.update,
            "Manage WebApps": Icons.web,
            "Wallpaper generator": Icons.image,
            "Boot screens": Icons.reboot
        })
    readonly property var entry: toplevel && !shellWindow ? DesktopEntries.heuristicLookup(toplevel.appId) : null

    property bool shown: true

    visible: shown && toplevel !== null && toplevel.activated && Hyprland.focusedMonitor?.name === screen?.name
    spacing: 8
    leftPadding: 8

    IconImage {
        anchors.verticalCenter: parent.verticalCenter
        implicitSize: Theme.iconSize
        source: root.shellWindow ? "" : Apps.iconSource(root.entry?.icon ?? "", "")
        visible: source != ""
    }

    Icon {
        font.pixelSize: Theme.barIconSize
        anchors.verticalCenter: parent.verticalCenter
        visible: root.shellWindow
        text: root.shellIcons[root.toplevel?.title] ?? Distro.logo
        color: Theme.accent
    }

    BarText {
        anchors.verticalCenter: parent.verticalCenter
        width: Math.min(implicitWidth, 220)
        text: root.shellWindow ? (root.toplevel?.title ?? "") : (root.entry?.name || root.toplevel?.appId || root.toplevel?.title || "")
        // the clock's color
        color: Theme.foreground
    }
}
