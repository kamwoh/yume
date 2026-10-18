"""Tests for tools/yume_urdf (ADR 0091 importer). Run:
python -m tools.yume_urdf.tests.test_urdf
"""
from __future__ import annotations

import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / "tools" / "validators"))
from content import articulation_problems  # noqa: E402

from tools.yume_urdf import URDFError, convert  # noqa: E402

EXAMPLE = (REPO / "tools" / "yume_urdf" / "examples" / "diffbot.urdf").read_text(encoding="utf-8")

failures = 0


def check(cond: bool, msg: str) -> None:
    global failures
    print(f"  [{'ok' if cond else 'FAIL'}] {msg}")
    failures += 0 if cond else 1


def robot(body: str) -> str:
    return f'<robot name="t"><link name="base"/>{body}</robot>'


def joint(jtype: str, child: str, rpy: str = "0 0 0", extra: str = "") -> str:
    return (f'<joint name="j_{child}" type="{jtype}"><parent link="base"/><child link="{child}"/>'
            f'<origin xyz="1 2 3" rpy="{rpy}"/>{extra}</joint>')


def main() -> int:
    d, warnings = convert(EXAMPLE, friction={"caster": 0.0})
    phys = d["physics"]
    check(articulation_problems(phys) == [], "the example converts to a valid articulated block")
    check(warnings == [], "the example gives no warnings")
    j = {x["child"]: x for x in phys["joints"]}
    check(j["left_wheel"]["at"] == [-0.19, -0.05, -0.1], "ROS (0.1, 0.19, -0.05) becomes Yume (-0.19, -0.05, -0.1)")
    check(j["left_wheel"]["axis"] == [-1.0, 0.0, 0.0], "the rolled wheel turns about -X (forward is positive)")
    check(phys["links"]["left_wheel"]["shape"]["axis"] == "x", "the rolled cylinder lies along x")
    check(phys["links"]["base_link"]["shape"]["size"] == [0.3, 0.08, 0.4], "the box size follows the axis change")
    check(j["base_link"]["at"] == [0.0, 0.15, 0.0], "ROS up (z) becomes Yume up (y)")
    check(j["left_wheel"]["motor"] == {"target_velocity": "self.state.left_wheel_joint_cmd", "max_torque": 3.0},
          "a continuous joint gets a motor from <limit effort>")
    check(d["state_init"] == {"left_wheel_joint_cmd": 0.0, "right_wheel_joint_cmd": 0.0}, "state_init holds each command")
    check(phys["links"]["caster"]["friction"] == 0.0, "--friction sets one link")
    check(phys["links"]["base_link"]["visual"] == {"color": "#3373d9"}, "a named material gives the link color")
    check(phys["root"] == "base_footprint" and phys["links"]["base_footprint"]["mass"] == 0.001,
          "the root is the link with no parent, and a link with no inertial gets a tiny mass")

    # A rotated joint folds into the child position below it.
    d2, _ = convert(robot('<link name="a"/><link name="b"/>' + joint("fixed", "a", "0 0 1.5707963")
                          + '<joint name="jb" type="fixed"><parent link="a"/><child link="b"/>'
                            '<origin xyz="1 0 0"/></joint>'))
    jb = [x for x in d2["physics"]["joints"] if x["child"] == "b"][0]
    check(abs(jb["at"][0] + 1.0) < 1e-6 and abs(jb["at"][2]) < 1e-6,
          "ROS +x after a +90 yaw is ROS +y, which is Yume -x")

    d3, _ = convert(robot('<link name="arm"/>' + joint("revolute", "arm", extra='<axis xyz="0 1 0"/><limit lower="-1" upper="1" effort="5"/>')))
    a = d3["physics"]["joints"][0]
    check(a["type"] == "hinge" and a["limit"] == [-1.0, 1.0], "a revolute joint becomes a hinge with a limit")
    check(a["axis"] == [-1.0, 0.0, 0.0], "ROS +y becomes Yume -x")

    for body, what in [
        ('<link name="s"/>' + joint("prismatic", "s"), "a prismatic joint"),
        ('<link name="c"><collision><geometry><cylinder radius="0.1" length="1"/></geometry></collision></link>'
         + joint("fixed", "c", "0.5 0 0"), "a cylinder that is not along an axis"),
        ('<link name="b"><collision><geometry><box size="1 1 1"/></geometry></collision></link>'
         + joint("fixed", "b", "0 0 0.3"), "a box that is not axis-aligned"),
        ('<link name="x"/>', "two roots"),
    ]:
        try:
            convert(robot(body))
            check(False, f"{what} is an error")
        except URDFError:
            check(True, f"{what} is an error")

    _, w = convert(robot('<link name="m"><collision><geometry><mesh filename="m.stl"/></geometry></collision></link>'
                         + joint("fixed", "m")))
    check(len(w) == 1 and "mesh" in w[0], "a mesh geometry gives a warning")

    print(f"\n{'PASS' if failures == 0 else 'FAIL'}: {failures} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
