#!/usr/bin/env python3
"""Run four T152 unavailable-flow UI cases against the isolated ios_gate build."""

import argparse
import json
import signal

from doctor import (Doctor, ROOT, RUNS, SIMULATOR, exclusive_run, ios_command,
                    local_ui_info_ok, new_run_path)
from simulator_smoke import MCPError, png_evidence


def ui_summary_ok(summary):
    return (summary.get('result') == 'Passed' and summary.get('totalTestCount') == 4
            and summary.get('passedTests') == 4 and summary.get('failedTests') == 0
            and summary.get('skippedTests') == 0)


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
            result = runner.run_dir / 't152-ui.xcresult'
            check = runner.command('t152-ui', [*ios_command(args),
                '-only-testing:PlantsUITests/FirstHelpTests', '-testLanguage', 'en', '-testRegion', 'PL',
                '-resultBundlePath', str(result), 'test-without-building'], 600)
            if check['status'] != 'PASS':
                return runner.finish(False)
            check = runner.command('t152-ui-result', ['xcrun', 'xcresulttool', 'get', 'test-results',
                'summary', '--path', str(result), '--compact'])
            valid = check['status'] == 'PASS' and ui_summary_ok(json.loads(runner.read_stdout(check)))
            runner.add('t152-ui-acceptance', 'PASS' if valid else 'FAIL', mode='local',
                       scope='Four EN/PL care/scan and problem/scan unavailable flows; no live backend')
            if not valid:
                return runner.finish(False)
            attachments = runner.run_dir / 'attachments'
            exported = runner.command('attachments-export', ['xcrun', 'xcresulttool', 'export',
                'attachments', '--path', str(result), '--output-path', str(attachments)], 60)
            if exported['status'] != 'PASS':
                return runner.finish(False)
            evidence = []
            for path in sorted(attachments.rglob('*.png')):
                item = png_evidence(path)
                item['path'] = str(path.relative_to(runner.run_dir))
                evidence.append(item)
            runner.add('screenshots', 'PASS' if len(evidence) >= 4 else 'FAIL', images=evidence)
            return runner.finish(True)
        except (KeyboardInterrupt, InterruptedError):
            runner.add('t152-ui', 'FAIL', reason='interrupted')
            runner.finish(False)
            return 130
        except (OSError, ValueError, KeyError, MCPError) as error:
            runner.add('t152-ui', 'FAIL', reason=str(error))
            return runner.finish(False)


if __name__ == '__main__':
    raise SystemExit(main())
