import os

application = defines['app']
format = 'UDZO'
filesystem = 'HFS+'
files = [application]
symlinks = {'Applications': '/Applications'}
background = defines['background']
icon_locations = {'Omil.app': (175, 210), 'Applications': (465, 210)}
window_rect = ((200, 200), (640, 420))
default_view = 'icon-view'
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
include_icon_view_settings = True
arrange_by = None
icon_size = 100
text_size = 14
label_pos = 'bottom'
# Setting FinderInfo on the signed app would invalidate its signature.
hide_extensions = []
app_icon = os.path.join(application, 'Contents', 'Resources', 'AppIcon.icns')
if os.path.isfile(app_icon):
    icon = app_icon
