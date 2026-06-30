"""pytest config for the yume_infinigen test dir.

`test_driver.py` is a STANDALONE script (its own main() + _check(), runs
via `python3 -m tools.yume_infinigen.tests.test_driver`), matching the
yume_assetgen convention. Excluded from pytest collection so its
ordered/return-based shape doesn't false-green or error under pytest.
"""
collect_ignore = ["test_driver.py"]
