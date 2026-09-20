"""Subprocess probe: cleanup must propagate an injected test failure."""
from temp_directory import TestDirectory
from std.testing import TestSuite


def _exercise(inject: Bool) raises:
    with TestDirectory() as directory:
        print(directory)
        with open(directory + "/sentinel", "w") as output:
            output.write("cleanup me")
        if inject:
            raise Error("injected-test-error")


def test_success() raises:
    _exercise(False)


def test_injected_failure() raises:
    _exercise(True)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
