"""
`python3 -m tools.yume_codegen` — runs the smoke test suite.

Useful as a sanity check after editing any builder in this package.
"""
import sys
from .tests.test_smoke import main

sys.exit(main())
