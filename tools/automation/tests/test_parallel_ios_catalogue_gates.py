"""Negative controls for catalogue UI acceptance; never launch Xcode or Simulator."""
import unittest
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from parallel_ios_catalogue_ui_gate import coverage, REQUIRED_METHODS
from parallel_ios_catalogue_release_gate import fixture_guard_ok, release_markers

class CatalogueGateTests(unittest.TestCase):
    def setUp(self):
        self.methods = sorted(REQUIRED_METHODS)
        self.source = '\n'.join(f'func {method}() {{}}' for method in self.methods)
        self.log = '\n'.join(f"Test Case '-[PlantsUITests.CatalogueSaveUITests {method}]' passed" for method in self.methods)
        self.summary = dict(result='Passed', totalTestCount=16, passedTests=16, failedTests=0, skippedTests=0)

    def testExactActualUISetPasses(self):
        self.assertEqual(coverage(self.summary,self.log,self.source)['status'],'PASS')

    def testMissingCompiledMethodRejects(self):
        self.assertEqual(coverage(self.summary,self.log,self.source+'\nfunc testNotCompiled() {}')['status'],'FAIL')

    def testUnexpectedStaleBinaryMethodRejects(self):
        log = self.log.replace(self.methods[-1],'testStale')
        self.assertEqual(coverage(self.summary,log,self.source)['status'],'FAIL')

    def testSkippedFailedOrIncorrectCountRejects(self):
        for delta in [dict(skippedTests=1),dict(expectedFailures=1),dict(failedTests=1),dict(totalTestCount=15),dict(passedTests=15),dict(result='Failed')]:
            with self.subTest(delta=delta):
                self.assertEqual(coverage({**self.summary,**delta},self.log,self.source)['status'],'FAIL')

    def testFewerThanSixteenScenariosRejects(self):
        source='\n'.join(f'func {method}() {{}}'for method in self.methods[:-1])
        log='\n'.join(self.log.splitlines()[:15])
        self.assertEqual(coverage({**self.summary,'totalTestCount':15,'passedTests':15},log,source)['status'],'FAIL')

    def testPassingGenericCaseCannotReplaceRequiredScenario(self):
        method=self.methods[-1]
        self.assertEqual(coverage(self.summary,self.log.replace(method,'testGeneric'),self.source.replace(method,'testGeneric'))['status'],'FAIL')

    def testReleaseRequiresActualDebugGuard(self):
        self.assertTrue(fixture_guard_ok('#if DEBUG\nstruct Fake {}\n#endif\n'))
        self.assertFalse(fixture_guard_ok('struct Fake {}'))
        self.assertFalse(fixture_guard_ok('#if DEBUG\nstruct Fake {}'))
        self.assertFalse(fixture_guard_ok('struct Fake {}\n#if DEBUG\n#endif'))

    def testEveryFixtureMarkerRejectsRelease(self):
        self.assertEqual(release_markers('normal app executable'),[])
        for marker in ('CatalogueUIFixture','CatalogueFixtureServer','fixture-only-','X-Catalogue-Fixture-Namespace','NaratCatalogueUIFixtures'):
            with self.subTest(marker=marker):
                self.assertIn(marker,release_markers('prefix '+marker+' suffix'))

if __name__ == '__main__':
    unittest.main()
