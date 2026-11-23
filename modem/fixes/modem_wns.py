#!/usr/bin/env python3
"""modem_wns.py -- compatibility wrapper: the Gate 2 timing reader lives in modem/gates/modem_wns.py."""
import os, runpy, sys
sys.argv[0] = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "gates", "modem_wns.py")
runpy.run_path(sys.argv[0], run_name="__main__")
