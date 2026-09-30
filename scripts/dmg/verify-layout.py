"""Verify the actual Finder layout stored inside the finished disk image."""
import pathlib
import sys
from ds_store import DSStore

root = pathlib.Path(sys.argv[1])
with DSStore.open(str(root / '.DS_Store'), 'r') as store:
    assert store['Omil.app']['Iloc'] == (175, 210), 'App icon misplaced'
    assert store['Applications']['Iloc'] == (465, 210), 'Applications icon misplaced'
    view = store['.']['icvp']
    assert view['iconSize'] == 100, 'Unexpected icon size'
    assert view['backgroundType'] == 2, 'Installer background missing'
    assert view.get('backgroundImageAlias'), 'Background image reference missing'
    window = store['.']['bwsp']
    assert not window['ShowToolbar'] and not window['ShowSidebar'], 'Installer window cluttered'
assert (root / 'Applications').is_symlink(), 'Applications shortcut missing'
assert (root / 'Applications').readlink() == pathlib.Path('/Applications')
assert (root / 'Omil.app').is_dir()
print('DMG install layout verified.')
