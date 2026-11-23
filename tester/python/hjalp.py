"""Gemensamt för Python-testerna: sökvägar och en färsk kopia av testprojektet (byggt av tester/testa.sh)."""
import os
import shutil
import sys
import tempfile
from pathlib import Path

HEM = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(HEM / "cad"))
FIXTUR = Path(os.environ.get("SKANNA_TESTFIXTUR", HEM / "tester" / ".bygg" / "Testlåda"))


def kopia():
    """(tempdir, projekt) – en färsk kopia av det byggda testprojektet."""
    if not (FIXTUR / "cad" / "delar.json").exists():
        raise unittest_skip("testprojektet är inte byggt – kör tester/testa.sh")
    t = Path(tempfile.mkdtemp(prefix="skanna-test-"))
    p = t / "Testlåda"
    shutil.copytree(FIXTUR, p)
    return t, p


def unittest_skip(msg):
    import unittest
    return unittest.SkipTest(msg)


def stada(t):
    shutil.rmtree(t, ignore_errors=True)
