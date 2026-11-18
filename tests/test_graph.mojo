"""The graph drawing (`morca._internal.graph`): cycles found, and the layout top to
bottom, two boxes wide at most."""

from std.testing import TestSuite, assert_false, assert_true

from morca._internal.graph import Edge, Node, back_edges, graph_svg


def _nodes(n: Int) -> List[Node]:
    var out = List[Node]()
    for i in range(n):
        out.append(Node(String("n", i), "dataset", "dataset", "", ""))
    return out^


def test_back_edges() raises:
    # 0 -> 1 -> 2 -> 0 closes a cycle with its last edge; 1 -> 1 too.
    var edges: List[Edge] = [Edge(0, 1), Edge(1, 2), Edge(2, 0), Edge(1, 1)]
    var back = back_edges(3, edges)
    assert_false(back[0])
    assert_false(back[1])
    assert_true(back[2])
    assert_true(back[3])
    var one: List[Edge] = [Edge(0, 1)]
    assert_false(back_edges(2, one)[0])


def test_tall_not_wide() raises:
    # A chain of 10 is one box wide and ten tall.
    var edges = List[Edge]()
    for i in range(9):
        edges.append(Edge(i, i + 1))
    var svg = graph_svg(_nodes(10), edges, "chain")
    assert_true('viewBox="0 0 194 ' in svg, String(svg[byte=:160]))
    # Six sources of one sink: two to a row, three rows, then the sink.
    var fan = List[Edge]()
    for i in range(6):
        fan.append(Edge(i, 6))
    var wide = graph_svg(_nodes(7), fan, "fan")
    assert_true('viewBox="0 0 388 ' in wide, String(wide[byte=:120]))


def test_a_cycle_doesnt_grow() raises:
    # A pipeline that reads what it writes: two levels, not n.
    var loop: List[Edge] = [Edge(0, 1), Edge(1, 0)]
    var svg = graph_svg(_nodes(2), loop, "loop")
    assert_true('height="156"' in svg, String(svg[byte=:160]))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
