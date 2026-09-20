"""Test-only temporary directories whose cleanup never suppresses test errors."""

from std.os import listdir, remove, rmdir
from std.os.path import isdir, islink
from std.tempfile import mkdtemp


def _remove_tree(path: String) raises:
    for entry in listdir(path):
        var child = path + "/" + entry
        if isdir(child) and not islink(child):
            _remove_tree(child)
        else:
            remove(child)
    rmdir(path)


struct TestDirectory(Movable):
    var path: String

    def __init__(out self) raises:
        self.path = mkdtemp(prefix="pyroquet-test-")

    def __enter__(self) -> String:
        return self.path

    def __exit__(self) raises:
        _remove_tree(self.path)

    def __exit__(self, error: Error) raises -> Bool:
        _remove_tree(self.path)
        return False
