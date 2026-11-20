# dmgbuild settings for LocalFlow.dmg (see build.sh). Defines passed in: app, background, icon.
import os.path

application = defines["app"]
appname = os.path.basename(application)

format = "UDZO"
files = [application]
symlinks = {"Applications": "/Applications"}
icon = defines["icon"]
hide_extensions = [appname]

background = defines["background"]
window_rect = ((200, 120), (640, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
icon_size = 128
text_size = 13
# Icon centers; scripts/make-dmg-background.swift draws the arrow between them.
icon_locations = {appname: (160, 190), "Applications": (480, 190)}
