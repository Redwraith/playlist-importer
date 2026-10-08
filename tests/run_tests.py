"""Runs the tests without pytest: python3 tests/run_tests.py"""
import importlib.util, inspect, os, sys, traceback
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
spec = importlib.util.spec_from_file_location("t", os.path.join(HERE, "test_matcher.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
passed, failed = 0, 0
for name, fn in inspect.getmembers(module, inspect.isfunction):
    if name.startswith("test_"):
        try:
            fn(); passed += 1
        except Exception:
            failed += 1; print("FAIL", name); traceback.print_exc(limit=2)
print(f"{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
