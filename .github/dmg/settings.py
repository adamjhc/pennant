# dmgbuild settings for the installer disk image.
# Run from the repo root: dmgbuild -s .github/dmg/settings.py -D app=path/to/Pennant.app Pennant Pennant.dmg
# Icon positions must match background.swift.

import os.path

app = defines["app"]  # noqa: F821
name = os.path.basename(app)

format = "ULFO"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(app, "Contents/Resources/AppIcon.icns")
if not os.path.exists(icon):
    icon = None

background = ".github/dmg/background.png"  # background@2x.png is picked up too.
window_rect = ((200, 200), (640, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 13
icon_locations = {
    name: (160, 200),
    "Applications": (480, 200),
}
hide_extensions = [name]
