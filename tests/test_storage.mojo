from std.testing import assert_equal, assert_raises, assert_true, TestSuite
from std.memory import ArcPointer
from pyroquet.storage import BufferBuilder, FrozenBuffer


@fieldwise_init
struct TrackedValue(Copyable, Movable):
    var drops: ArcPointer[Int]

    def __deinit__(deinit self):
        self.drops[] += 1


def make_tracked_slice(
    drops: ArcPointer[Int],
) raises -> FrozenBuffer[TrackedValue]:
    var builder = BufferBuilder[TrackedValue]()
    builder.append(TrackedValue(drops))
    var frozen = builder^.freeze()
    return frozen.slice(0, 1)


def release_last_handles(drops: ArcPointer[Int]) raises:
    var retained = make_tracked_slice(drops)
    var shared = retained.copy()
    assert_equal(drops[], 0)
    assert_equal(len(shared), 1)


def test_destroy_elements_once_after_last_owner() raises:
    var drops = ArcPointer(0)
    release_last_handles(drops)
    assert_equal(drops[], 1)


def retained_slice() raises -> FrozenBuffer[UInt32]:
    var builder = BufferBuilder[UInt32](128)
    builder.append(0)
    builder.append(UInt32.MAX)
    builder.append(2147483648)
    var frozen = builder^.freeze()
    return frozen.slice(1, 2)


def test_retained_owner_and_borrow() raises:
    # Builder and original handle have both been destroyed on return.
    var values = retained_slice()
    assert_equal(len(values), 2)
    assert_equal(values[0], UInt32.MAX)
    assert_equal(values[1], UInt32(2147483648))
    var shared = values.copy()
    var borrowed = values.view()
    var shared_view = shared.view()
    assert_equal(Int(borrowed.unsafe_ptr()), Int(shared_view.unsafe_ptr()))
    assert_equal(borrowed[1], UInt32(2147483648))
    var cloned = values.clone()
    var cloned_view = cloned.view()
    assert_true(Int(borrowed.unsafe_ptr()) != Int(cloned_view.unsafe_ptr()))
    assert_equal(cloned[0], values[0])
    assert_equal(cloned[1], values[1])


def test_freeze_moves_list_allocation() raises:
    var values: List[UInt32] = [0, 2147483648, UInt32.MAX]
    var address = Int(values.unsafe_ptr())
    var frozen = FrozenBuffer(values^)
    assert_equal(Int(frozen.view().unsafe_ptr()), address)


def test_initialized_length_and_ranges() raises:
    var builder = BufferBuilder[UInt32](128)
    assert_equal(len(builder), 0)
    builder.append(42)
    var frozen = builder^.freeze()
    assert_equal(len(frozen), 1)
    assert_equal(len(frozen.view()), 1)
    assert_equal(len(frozen.slice(1, 0)), 0)
    with assert_raises():
        _ = frozen[1]
    with assert_raises():
        _ = frozen[-1]
    with assert_raises():
        _ = frozen.slice(0, 2)
    with assert_raises():
        _ = frozen.slice(Int.MAX, 1)
    with assert_raises():
        _ = frozen.slice(1, Int.MAX)
    with assert_raises():
        _ = frozen.slice(0, -1)
    with assert_raises():
        _ = frozen.slice(-1, 0)
    with assert_raises():
        _ = BufferBuilder[UInt32](-1)


def test_empty_freeze() raises:
    var builder = BufferBuilder[UInt32]()
    var frozen = builder^.freeze()
    assert_equal(len(frozen), 0)
    assert_equal(len(frozen.view()), 0)
    assert_equal(len(frozen.slice(0, 0).clone()), 0)
    with assert_raises():
        _ = frozen[0]


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
