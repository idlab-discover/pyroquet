"""Native create-new publication, collision, and abandoned-write checks."""

from std.os import listdir, mkdir, remove, symlink
from std.os.path import exists, islink
from temp_directory import TestDirectory
from std.testing import (
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
    TestSuite,
)
from pyroquet.io import NewFile


def _abandon(path: String) raises:
    var output = NewFile(path)
    output.write_all([UInt8(99)])


def _collision(path: String) raises:
    var output = NewFile(path)
    output.write_all([UInt8(99)])
    output.finish()


def test_publish_complete_bytes() raises:
    with TestDirectory() as directory:
        var target = directory + "/result"
        var output = NewFile(target)
        output.write_all([UInt8(1), 2])
        output.write_all([UInt8(3), 4])
        assert_false(exists(target))
        output.finish()
        assert_true(exists(target))
        var file = open(target, "r")
        assert_equal(file.read_bytes(), [UInt8(1), 2, 3, 4])
        file.close()
        assert_equal(len(listdir(directory)), 1)
        with assert_raises():
            output.write_all([UInt8(5)])
        with assert_raises():
            output.finish()


def test_abandoned_write_cleanup() raises:
    with TestDirectory() as directory:
        _abandon(directory + "/result")
        assert_equal(len(listdir(directory)), 0)


def test_existing_file_unchanged() raises:
    with TestDirectory() as directory:
        var target = directory + "/result"
        var file = open(target, "w")
        var bytes: List[UInt8] = [7, 8]
        file.write_all(bytes[:])
        file.close()
        with assert_raises():
            _collision(target)
        var check = open(target, "r")
        assert_equal(check.read_bytes(), [UInt8(7), 8])
        check.close()
        assert_equal(len(listdir(directory)), 1)


def test_symlink_and_directory_collisions() raises:
    with TestDirectory() as directory:
        var target = directory + "/result"
        symlink(directory + "/missing", target)
        with assert_raises():
            _collision(target)
        assert_true(islink(target))
        assert_false(exists(directory + "/missing"))
        assert_equal(len(listdir(directory)), 1)
        remove(target)
        mkdir(target)
        with assert_raises():
            _collision(target)
        assert_equal(len(listdir(directory)), 1)
        assert_equal(len(listdir(target)), 0)


def test_competing_publications() raises:
    with TestDirectory() as directory:
        var target = directory + "/result"
        var first = NewFile(target)
        var second = NewFile(target)
        first.write_all([UInt8(1)])
        second.write_all([UInt8(2)])
        first.finish()
        with assert_raises():
            second.finish()
        var check = open(target, "r")
        assert_equal(check.read_bytes(), [UInt8(1)])
        check.close()


def _raise_during_write(path: String) raises:
    var output = NewFile(path)
    output.write_all([UInt8(1)])
    raise Error("injected encoding failure")


def test_exception_unwinds_and_cleans() raises:
    with TestDirectory() as directory:
        with assert_raises():
            _raise_during_write(directory + "/result")
        assert_equal(len(listdir(directory)), 0)


def test_publish_empty_file() raises:
    with TestDirectory() as directory:
        var target = directory + "/empty"
        var output = NewFile(target)
        output.write_all(List[UInt8]())
        output.finish()
        var file = open(target, "r")
        assert_equal(len(file.read_bytes()), 0)
        file.close()
        assert_equal(len(listdir(directory)), 1)


def test_invalid_paths() raises:
    with TestDirectory() as directory:
        with assert_raises():
            var output = NewFile("")
        with assert_raises():
            var output = NewFile(directory + "/missing/file")
        with assert_raises():
            var output = NewFile(directory + "/bad\0suffix")
        assert_equal(len(listdir(directory)), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
