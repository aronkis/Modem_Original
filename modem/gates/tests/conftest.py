import pathlib, sys

FIXES = pathlib.Path(__file__).resolve().parent.parent
if str(FIXES) not in sys.path:
    sys.path.insert(0, str(FIXES))
