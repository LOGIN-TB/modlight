# dmgbuild settings for Podlight's disk image. Writes the window layout directly (no Finder
# scripting), so it works headless. Called from tools/mac-release.sh:
#   dmgbuild -s tools/dmg/settings.py -D app=<Podlight.app> -D background=<background.tiff> "Podlight" <out.dmg>
import os.path

app = defines["app"]  # noqa: F821  (provided by dmgbuild)
background = defines["background"]  # noqa: F821

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon_locations = {os.path.basename(app): (165, 210), "Applications": (495, 210)}
window_rect = ((200, 160), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 112
text_size = 13
include_icon_view_settings = True
arrange_by = None
