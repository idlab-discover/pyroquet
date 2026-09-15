"""Publish complete files without replacing an existing destination."""

from std.io.file import FileHandle
from std.os import link, remove, rmdir
from std.os.path import dirname, isdir
from std.tempfile import mkdtemp


struct NewFile(Movable):
    """Stage writes beside a destination, then atomically create its name.

    A private temporary directory keeps the staging file on the destination
    filesystem. ``finish`` closes the file before creating a hard link; an
    existing destination (including a symlink) causes an error without changing
    it. The filesystem must support hard links. This provides atomic visibility,
    not crash durability: no file or directory fsync is performed.

    Abandoned writes and errors trigger best-effort staging cleanup. Cleanup
    errors after a successful link do not change publication's success; the
    destructor retries cleanup. Process termination can leave staging artifacts.
    """

    var _file: FileHandle
    var _destination: String
    var _directory: String
    var _source: String
    var _finished: Bool

    def __init__(out self, path: String) raises:
        self._file = FileHandle()
        self._destination = path
        self._directory = ""
        self._source = ""
        self._finished = False
        if path.byte_length() == 0 or "\0" in path:
            raise Error("output path must be nonempty and contain no NUL")
        var parent = String(dirname(path))
        if parent.byte_length() == 0:
            parent = "."
        if not isdir(parent):
            raise Error("output parent is not an existing directory: " + parent)
        self._directory = mkdtemp(prefix=".pyroquet-", dir=parent)
        self._source = self._directory + "/payload"
        try:
            self._file = open(self._source, "w")
        except err:
            self._cleanup()
            raise err^

    def __deinit__(deinit self):
        self._cleanup()

    def _cleanup(mut self):
        try:
            self._file.close()
        except:
            pass
        if self._source.byte_length() != 0:
            try:
                remove(self._source)
                self._source = ""
            except:
                pass
        if self._directory.byte_length() != 0:
            try:
                rmdir(self._directory)
                self._directory = ""
            except:
                pass

    def write_all(mut self, data: List[UInt8]) raises:
        """Write a complete byte buffer; propagate short-write and I/O errors.
        """
        if self._finished:
            raise Error("cannot write after publication")
        self._file.write_all(data[:])

    def finish(mut self) raises:
        """Close the staged file and atomically create the destination name."""
        if self._finished:
            raise Error("file already published")
        self._file.close()
        link(self._source, self._destination)
        self._finished = True
        self._cleanup()
