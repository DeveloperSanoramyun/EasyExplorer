"""Generate tiny hostile archives in a temporary test directory."""
from pathlib import Path
import sys
import zipfile
import tarfile
import stat

root = Path(sys.argv[1])
root.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(root / 'safe.zip', 'w') as archive:
    archive.writestr('existing.txt', 'archive data')
    archive.writestr('nested/한자.txt', 'hello')
    archive.writestr('omit.txt', 'omitted')
for filename, member in [('traversal.zip', '../outside.txt'), ('absolute.zip', '/tmp/outside.txt')]:
    with zipfile.ZipFile(root / filename, 'w') as archive:
        archive.writestr(member, 'bad')
with zipfile.ZipFile(root / 'symlink.zip', 'w') as archive:
    entry = zipfile.ZipInfo('evil')
    entry.create_system = 3
    entry.external_attr = (stat.S_IFLNK | 0o777) << 16
    archive.writestr(entry, '../outside')
for filename, kind in [('hardlink.tar', tarfile.LNKTYPE), ('special.tar', tarfile.FIFOTYPE)]:
    with tarfile.open(root / filename, 'w') as archive:
        entry = tarfile.TarInfo('evil')
        entry.type = kind
        if kind == tarfile.LNKTYPE:
            entry.linkname = '../outside'
        archive.addfile(entry)
(root / 'broken.zip').write_bytes(b'not an archive')
