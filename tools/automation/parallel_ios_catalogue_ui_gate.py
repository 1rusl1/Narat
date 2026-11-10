#!/usr/bin/env python3
"""Controller gate for actual catalogue save UI fixtures, not live integrations."""
import argparse
import json
import re
import signal
from doctor import Doctor, ROOT, RUNS, SIMULATOR, exclusive_run, ios_command, local_ui_info_ok, new_run_path
from simulator_smoke import MCPError, png_evidence


REQUIRED_METHODS = {'testServerLimitEnglish', 'testNativeSuccessEnglish', 'testServerUnavailableEnglish', 'testLostResponseRestartEnglish', 'testPreflightLimitPolish', 'testNativeCancellationRestartEnglish', 'testFreeSaveEnglish', 'testNativeCancellationRestartPolish', 'testServerUnavailablePolish', 'testPaidSaveEnglish', 'testServerLimitPolish', 'testPreflightLimitEnglish', 'testFreeSavePolish', 'testPaidSavePolish', 'testNativeSuccessPolish', 'testLostResponseRestartPolish'}

def coverage(summary, log, source):
    expected = set(re.findall(r'\bfunc\s+(test\w+)\s*\(', source))
    passed = set(re.findall(r"Test Case '-\[PlantsUITests\.CatalogueSaveUITests (test\w+)\]' passed", log))
    return {
        'status': 'PASS' if (REQUIRED_METHODS <= expected and len(expected) >= 16 and summary.get('result') == 'Passed'
            and summary.get('totalTestCount') == len(expected)
            and summary.get('passedTests') == len(expected) and summary.get('failedTests') == 0
            and summary.get('skippedTests') == 0 and summary.get('expectedFailures', 0) == 0 and expected == passed) else 'FAIL',
        'required_methods': sorted(REQUIRED_METHODS), 'expected_methods': sorted(expected), 'passed_methods': sorted(passed),
        'missing_methods': sorted(expected - passed), 'mode': 'local_fixture_ui_not_live'
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-id', required=True)
    parser.add_argument('--simulator', default=SIMULATOR)
    args = parser.parse_args()
    def interrupted(signum, frame):
        raise InterruptedError(f'signal {signum}')
    signal.signal(signal.SIGTERM, interrupted)
    with exclusive_run(RUNS):
        runner = Doctor(new_run_path(RUNS, args.run_id))
        try:
            info = ROOT / 'DerivedData/Automation/Build/Products/Debug-iphonesimulator/Plants.app/Info.plist'
            isolated = local_ui_info_ok(info)
            runner.add('isolated-build', 'PASS' if isolated else 'FAIL', info_plist=str(info))
            if not isolated:
                return runner.finish(False)
            source = (ROOT / 'ios/PlantsUITests/CatalogueSaveUITests.swift').read_text()
            result = runner.run_dir / 'catalogue-ui.xcresult'
            test = runner.command('catalogue-ui', [*ios_command(args),
                '-only-testing:PlantsUITests/CatalogueSaveUITests', '-testLanguage', 'en', '-testRegion', 'PL',
                '-resultBundlePath', str(result), 'test-without-building'], 1200)
            if test['status'] != 'PASS':
                if result.exists():
                    runner.command('catalogue-ui-failure-result', ['xcrun', 'xcresulttool', 'get', 'test-results',
                        'summary', '--path', str(result), '--compact'])
                    runner.command('failure-attachments-export', ['xcrun', 'xcresulttool', 'export',
                        'attachments', '--path', str(result), '--output-path', str(runner.run_dir / 'failure-attachments'),
                        '--only-failures'], 90)
                return runner.finish(False)
            check = runner.command('catalogue-ui-result', ['xcrun', 'xcresulttool', 'get', 'test-results',
                'summary', '--path', str(result), '--compact'])
            if check['status'] != 'PASS':
                return runner.finish(False)
            accepted = coverage(json.loads(runner.read_stdout(check)), runner.read_stdout(test), source)
            runner.add('catalogue-ui-source-coverage', **accepted)
            if accepted['status'] != 'PASS':
                return runner.finish(False)
            attachments = runner.run_dir / 'attachments'
            exported = runner.command('attachments-export', ['xcrun', 'xcresulttool', 'export',
                'attachments', '--path', str(result), '--output-path', str(attachments)], 90)
            if exported['status'] != 'PASS':
                return runner.finish(False)
            evidence = []
            for path in sorted(attachments.rglob('*.png')):
                item = png_evidence(path)
                item['path'] = str(path.relative_to(runner.run_dir))
                evidence.append(item)
            runner.add('catalogue-ui-screenshots', 'PASS' if len(evidence) >= len(accepted['expected_methods']) else 'FAIL',
                       images=evidence)
            return runner.finish(True)
        except (KeyboardInterrupt, InterruptedError):
            runner.add('catalogue-ui', 'FAIL', reason='interrupted')
            runner.finish(False)
            return 130
        except (OSError, ValueError, KeyError, MCPError) as error:
            runner.add('catalogue-ui', 'FAIL', reason=str(error))
            return runner.finish(False)

if __name__ == '__main__':
    raise SystemExit(main())
