#!/usr/bin/env python3
"""Build isolated Release and reject DEBUG catalogue fixture symbols and credentials."""
import argparse
import signal
from doctor import Doctor, ROOT, RUNS, SIMULATOR, exclusive_run, ios_command, local_ui_info_ok, new_run_path

MARKERS = ('CatalogueUIFixture', 'CatalogueFixtureServer', 'fixture-only-', 'X-Catalogue-Fixture-Namespace', 'NaratCatalogueUIFixtures')

def fixture_guard_ok(source):
    source = source.strip()
    return source.startswith('#if DEBUG\n') and source.endswith('#endif')

def release_markers(text):
    return [marker for marker in MARKERS if marker in text]

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
            source = (ROOT / 'ios/Plants/Features/Catalogue/CatalogueUIFixtures.swift').read_text().strip()
            guarded = fixture_guard_ok(source)
            runner.add('fixture-source-debug-guard', 'PASS' if guarded else 'FAIL')
            if not guarded:
                return runner.finish(False)
            command = ios_command(args)
            command[command.index('-derivedDataPath') + 1] = str(ROOT / 'DerivedData/ReleaseAutomation')
            built = runner.command('release-build', [*command, '-configuration', 'Release', 'build'], 1200)
            if built['status'] != 'PASS':
                return runner.finish(False)
            app = ROOT / 'DerivedData/ReleaseAutomation/Build/Products/Release-iphonesimulator/Plants.app'
            runner.add('release-live-isolation', 'PASS' if local_ui_info_ok(app / 'Info.plist') else 'FAIL')
            binary = app / 'Plants'
            if not binary.is_file() or binary.stat().st_size < 1024:
                runner.add('release-binary', 'FAIL', reason='Missing actual built executable')
                return runner.finish(False)
            extracted = runner.command('release-strings', ['/usr/bin/strings', '-a', str(binary)], 60)
            if extracted['status'] != 'PASS':
                return runner.finish(False)
            found = release_markers(runner.read_stdout(extracted))
            runner.add('release-fixture-exclusion', 'FAIL' if found else 'PASS', found=found,
                       scope='Actual isolated Release executable contains no catalogue DEBUG fixture markers; not live acceptance')
            return runner.finish(True)
        except (KeyboardInterrupt, InterruptedError):
            runner.add('release', 'FAIL', reason='interrupted')
            runner.finish(False)
            return 130
        except (OSError, ValueError, KeyError) as error:
            runner.add('release', 'FAIL', reason=str(error))
            return runner.finish(False)

if __name__ == '__main__':
    raise SystemExit(main())
