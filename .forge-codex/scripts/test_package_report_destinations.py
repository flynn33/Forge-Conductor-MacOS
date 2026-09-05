#!/usr/bin/env python3
"""Keep current package checks in state while preserving the tracked report."""
from __future__ import annotations

import contextlib
import hashlib
import io
import json
import os
import pathlib
import subprocess
import tempfile
import unittest
from unittest import mock

import validate_package
import verify_completion

REPOSITORY = pathlib.Path(__file__).resolve().parents[2]
HISTORICAL = b'{"validated_at":"historical-fixture","valid":true}\n'


class PackageReportDestinationTests(unittest.TestCase):
    def make_fixture(self, root):
        package = root / '.forge-codex'
        scripts = package / 'scripts';scripts.mkdir(parents=True)
        (package / 'PACKAGE_VALIDATION.json').write_bytes(HISTORICAL)
        (package / 'state').mkdir()
        (package / 'state/run-state.json').write_text('{}')
        doctor = scripts / 'doctor.sh'
        doctor.write_text('#!/usr/bin/env python3\nimport os,pathlib\np=pathlib.Path(os.environ["FORGE_GATE_REPOSITORY_ROOT"])/".forge-codex/state/environment.json"\np.write_text("{}")\n')
        state = scripts / 'statectl.py';state.write_text('#!/usr/bin/env python3\nraise SystemExit(0)\n')
        validator = scripts / 'validate_package.py'
        validator.write_text(
            '#!/usr/bin/env python3\nimport os,sys\n'
            f'sys.path.insert(0,{str(REPOSITORY / ".forge-codex/scripts")!r})\n'
            'import validate_package as implementation\n'
            'valid=os.environ["PACKAGE_FIXTURE_VALID"]=="true"\n'
            'implementation.validate=lambda root:{"schema_version":1,"validated_at":"current-fixture","valid":valid,"checks":[],"errors":[] if valid else ["fixture invalid package"]}\n'
            'raise SystemExit(implementation.main())\n'
        )
        for path in (doctor,state,validator):path.chmod(0o755)
        build = root / 'script/build_and_run.sh';build.parent.mkdir();build.write_text('#!/bin/sh\nexit 0\n')
        return package

    def test_both_g00_handlers_preserve_report_and_capture_current_evidence(self):
        for directory in ('state','templates'):
            for valid in (True,False):
                with self.subTest(directory=directory,valid=valid),tempfile.TemporaryDirectory() as temporary:
                    root=pathlib.Path(temporary);package=self.make_fixture(root)
                    result=subprocess.run(['/bin/bash',str(REPOSITORY/f'.forge-codex/{directory}/gate-handlers/G00.sh')],cwd=root,env={**os.environ,'FORGE_GATE_REPOSITORY_ROOT':str(root),'PACKAGE_FIXTURE_VALID':str(valid).lower(),'PYTHONDONTWRITEBYTECODE':'1'},capture_output=True,text=True,timeout=20)
                    self.assertEqual(result.returncode,0 if valid else 1,result.stdout+result.stderr)
                    self.assertEqual((package/'PACKAGE_VALIDATION.json').read_bytes(),HISTORICAL)
                    report=package/'state/gate-results/G00.package-validation.json'
                    raw=report.read_bytes();self.assertIs(json.loads(raw)['valid'],valid)
                    criteria=package/'state/gate-results/G00.criteria.json'
                    if valid:
                        row=next(row for row in json.loads(criteria.read_bytes())['criteria_results'] if row['criterion']=='package validation passes')
                        self.assertIs(row['passed'],True)
                        self.assertIn({'path':str(report),'sha256':hashlib.sha256(raw).hexdigest()},row['evidence'])
                        self.assertNotIn(str(package/'PACKAGE_VALIDATION.json'),json.dumps(row))
                    else:self.assertFalse(criteria.exists())

    def test_completion_evaluation_preserves_historical_report_and_failed_result(self):
        for valid in (True,False):
            with self.subTest(valid=valid),tempfile.TemporaryDirectory() as temporary:
                root=pathlib.Path(temporary);package=self.make_fixture(root)
                commands=[]
                def execute(repository,label,command,**kwargs):
                    commands.append(command)
                    if label!='package-valid':return 0,b'',b''
                    output=io.StringIO()
                    document={'schema_version':1,'validated_at':'current-fixture','valid':valid,'checks':[],'errors':[] if valid else ['fixture invalid package']}
                    with mock.patch.object(validate_package,'validate',return_value=document),contextlib.redirect_stdout(output):
                        code=validate_package.main(command[2:])
                    return code,output.getvalue().encode(),b''
                evaluation=verify_completion.CompletionEvaluation(root)
                with mock.patch.object(evaluation,'load_required_controls',return_value=False),mock.patch.object(verify_completion,'run_bounded_readonly_command',side_effect=execute):
                    result=evaluation.evaluate()
                self.assertEqual((package/'PACKAGE_VALIDATION.json').read_bytes(),HISTORICAL)
                report=package/'state/completion-package-validation.json'
                self.assertIs(json.loads(report.read_bytes())['valid'],valid)
                self.assertEqual(commands[0][-2:],['--report',str(report)])
                package_check=next(row for row in result['checks'] if row['name']=='package-valid')
                self.assertIs(package_check['passed'],valid)
                self.assertIs(result['passed'],valid)


if __name__=='__main__':unittest.main()
