#!/usr/bin/env python3
"""Developer-only entry point; never bundled or invoked by TaskPilot."""
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Tests/PromptRegression"))
from evaluate import main

if __name__ == "__main__":
    raise SystemExit(main())
