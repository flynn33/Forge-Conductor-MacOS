#!/usr/bin/env python3
"""Adversarial fixture tests for the reviewed installed CLI acceptance boundary."""
from __future__ import annotations
import contextlib
import copy
import hashlib
import io
import json
import os
import pathlib
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import p10_native_cli_scenario as native
import p10_cli_version_help as cli
import p10_feature_evidence as reader
import p10_feature_baseline as baseline
import qualify_p10_features as qualifier
from evidence_support import EvidenceSupportError, source_manifest
import test_p10_cli_version_help as supporting_tests

REPO = pathlib.Path(__file__).resolve().parents[2]
BUILD = 'EVID-native-build-fixture'
INSTALL = 'EVID-native-install-fixture'
EVIDENCE = 'EVID-native-selected-fixture'
NONCE = 'a' * 64
HEAD = 'a' * 40


class NativeCLIScenarioTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name).resolve()
        self.helper = supporting_tests.CLIHelpSupportingTests()
        original = self.helper.fixture_app(self.root)
        self.source = self.root / 'DerivedData/Build/Products/Release/Forge Conductor.app'
        self.source.parent.mkdir(parents=True)
        original.rename(self.source)
        with (self.root / cli.SOURCE_VERSION_PATH).open('a') as stream:
            stream.write('public static let productBuildVersion = "1"\n')
        for path in native.BUILD_FILES:
            target = self.source / path
            if not target.exists():
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(b'fixture artifact')
        self.home = self.root / 'retained-home'
        self.home.mkdir()
        self.app = self.home / 'Forge Conductor.app'
        shutil.copytree(self.source, self.app)
        self.identities = {str(app): {'path':str(app), 'version':'0.9.0', 'build':'1', 'signing_authority':'Apple Development: Fixture'} for app in (self.source, self.app)}
        self.build = self.make_record(BUILD, 'p10-native-cli-build', 0)
        argv = ['xcodebuild','-workspace','ForgeConductor.xcworkspace','-scheme','ForgeConductor','-configuration','Release','-destination','platform=macOS,arch=arm64','-derivedDataPath',str(self.source.parents[3])]
        argv += [flag for key in ('Address','Thread','UndefinedBehavior') for flag in ('-enable'+key+'Sanitizer','NO')]
        argv += ['DEVELOPMENT_TEAM=9AQ2C2838M','CODE_SIGN_IDENTITY=Apple Development','SWIFT_ACTIVE_COMPILATION_CONDITIONS=FORGE_DEVELOPMENT_SIGNING','SWIFT_TREAT_WARNINGS_AS_ERRORS=YES','GCC_TREAT_WARNINGS_AS_ERRORS=YES','build']
        self.build['command'] = shlex.join(argv)
        for relative in native.BUILD_FILES:
            path = self.source / relative
            self.build['artifacts'].append({'path':str(path),'storage':'external-hash-only','portability':'origin-host-required',**{key:value for key,value in cli.file_binding(path).items() if key != 'mode'}})
        self.report = {'schema_version':1,'kind':'signed-shell-installed-manager-qualification','mode':'execute','overall_status':'partial','source_application':self.identities[str(self.source)],'scenario':{'install':{'status':'passed','exit_code':0,'command':native.sandboxed_install_command(self.source/'Contents/Helpers/forge-conductor',self.home)},'staged_artifacts':{'application':self.identities[str(self.app)]}},'cleanup':{'status':'restored','residuals':[],'final_canonical_job':'absent','final_canonical_plist':'absent','qualification_home_retained':str(self.home)}}
        self.installer = self.make_record(INSTALL,'p10-native-cli-installation',4)
        self.installer['started_at']='2026-09-04T00:02:00+00:00'
        self.installer['ended_at']='2026-09-04T00:03:00+00:00'
        self.installer['command'] = shlex.join(['python3','.forge-codex/scripts/qualify_signed_shell_manager.py','--app',str(self.source),'--execute','--qualification-home',str(self.home),'--output',native.INSTALL_REPORT])
        self.write_report()
        self.persist()
        self.signatures = mock.patch.object(native,'checked_bundle',side_effect=lambda repo,app:copy.deepcopy(self.identities[str(app)]))
        self.signatures.start(); self.addCleanup(self.signatures.stop)
        self.head = mock.patch.object(native,'current_git_head',return_value=HEAD)
        self.head.start(); self.addCleanup(self.head.stop)
        self.candidate_check = mock.patch.object(native,'validate_source_candidate',side_effect=self.fixture_candidate)
        self.candidate_check.start();self.addCleanup(self.candidate_check.stop)
        self.pid=4320

    def fixture_candidate(self,repository,candidate,delivery,recorded,current):
        # Actual Git ancestry/cleanliness is covered by test_p10_source_candidate.
        if candidate != HEAD or delivery not in {HEAD,'b'*40} or recorded != current:
            raise EvidenceSupportError('fixture source candidate differs')

    def make_record(self,evidence_id,kind,exit_code):
        result={'schema_version':2,'id':evidence_id,'kind':kind,'exit_code':exit_code,'timed_out':False,'stream_limit_exceeded':False,'maximum_stream_bytes':67108864,'started_at':'2026-09-04T00:00:00+00:00','ended_at':'2026-09-04T00:01:00+00:00','execution_provenance':{'repository':{'head_sha':HEAD}},'environment':{'cwd':str(self.root)},'artifacts':[],'artifact_capture_errors':[],'ledger_reference':{'status':'recorded','exit_code':0},'related_gates':['G10']}
        for suffix in ('stdout','stderr'):
            relative=f'.forge-codex/evidence/{evidence_id}.{suffix}.txt'
            path=self.root/relative;path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(b'')
            result['artifacts'].append({'path':relative,'bytes':0,'sha256':hashlib.sha256(b'').hexdigest(),'storage':'evidence-id-specific-stream'})
        return result

    def write_report(self):
        relative=f'.forge-codex/evidence/{INSTALL}.artifact-000-P10-cli-installation.json'
        raw=json.dumps(self.report).encode();(self.root/relative).write_bytes(raw)
        self.installer['artifacts']=[a for a in self.installer['artifacts'] if a.get('source_path') != native.INSTALL_REPORT]
        self.installer['artifacts'].append({'path':relative,'source_path':native.INSTALL_REPORT,'storage':'evidence-id-specific-copy','bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest()})

    def persist(self):
        state=self.root/'.forge-codex/state/run-state.json';state.parent.mkdir(exist_ok=True)
        state.write_text(json.dumps({'evidence':[f'.forge-codex/evidence/{BUILD}.json',f'.forge-codex/evidence/{INSTALL}.json']}))
        manifest=source_manifest(self.root)
        for row in (self.build,self.installer):
            row.update(source_manifest=manifest,source_manifest_after=manifest,source_manifest_changed=False)
            (self.root/f'.forge-codex/evidence/{row["id"]}.json').write_text(json.dumps(row))

    def command(self,*args,**kwargs):
        result=self.helper.simulated_command(*args,**kwargs)
        self.pid+=1;kwargs['process_metadata']['pid']=self.pid
        return result

    def capture(self):
        with mock.patch.object(cli,'execute_command',side_effect=self.command):
            return native.capture_result(self.root,build_id=BUILD,installation_id=INSTALL,evidence_id=EVIDENCE,nonce=NONCE)

    def test_actual_install_pass_may_coexist_with_honest_partial_qualification(self):
        proof=native.provenance(self.root,BUILD,INSTALL)
        self.assertEqual(proof['installed_app'],str(self.app))
        self.assertFalse(proof['distribution_qualified'])
        self.assertEqual(proof['scope'],'development-installed-release')
        probe,result,process=self.capture()
        self.assertTrue(native.validate_result(self.root,result,evidence_id=EVIDENCE,nonce=NONCE,process=process))
        self.assertEqual(probe['installation']['root'],str(self.app))
        self.assertEqual(len(result['transcript']['cases']),7)
        self.assertEqual(result['transcript']['accepted_p10_assertions'],[])

    def test_partial_report_cannot_hide_failed_installation_or_cleanup(self):
        original=copy.deepcopy(self.report)
        mutations=[lambda r:r['scenario']['install'].__setitem__('exit_code',1),lambda r:r['scenario']['install'].__setitem__('status','failed'),lambda r:r['cleanup'].__setitem__('residuals',['fixture']),lambda r:r.__setitem__('overall_status','failed'),lambda r:r['source_application'].__setitem__('build','2')]
        for mutate in mutations:
            with self.subTest(mutate=mutate):
                self.report=copy.deepcopy(original);mutate(self.report);self.write_report();self.persist()
                with self.assertRaises(EvidenceSupportError): native.provenance(self.root,BUILD,INSTALL)
        self.report=original;self.write_report();self.installer['exit_code']=2;self.persist()
        with self.assertRaises(EvidenceSupportError): native.provenance(self.root,BUILD,INSTALL)

    def test_stale_or_failed_build_and_substituted_artifacts_are_rejected(self):
        for mutation in ('source','head','failure','configuration','no-artifact','copied-cli','framework','signature'):
            with self.subTest(mutation=mutation):
                original=copy.deepcopy(self.build);identity=copy.deepcopy(self.identities);changed=None
                if mutation=='source': self.build['source_manifest']={'stale':True}
                elif mutation=='head': self.build['execution_provenance']['repository']['head_sha']='b'*40
                elif mutation=='failure': self.build['exit_code']=1
                elif mutation=='configuration': self.build['command']=self.build['command'].replace('-configuration Release','-configuration Debug')
                elif mutation=='no-artifact': self.build['artifacts'].pop()
                elif mutation=='signature': self.identities[str(self.app)]['build']='2'
                else:
                    changed=self.app/(native.BUILD_FILES[1] if mutation=='copied-cli' else native.BUILD_FILES[4]);saved=changed.read_bytes();changed.write_bytes(b'alternate')
                (self.root/f'.forge-codex/evidence/{BUILD}.json').write_text(json.dumps(self.build))
                with self.assertRaises(EvidenceSupportError): native.provenance(self.root,BUILD,INSTALL)
                self.build=original;self.identities=identity
                if changed is not None: changed.write_bytes(saved)
                self.persist()

    def test_transcript_pid_argv_output_framework_and_identity_bindings_fail_closed(self):
        probe,result,process=self.capture()
        mutations={
          'pid':lambda r,p:p.__setitem__('pid',p['pid']+1),
          'duplicate-pid':lambda r,p:r['transcript']['cases'][1].__setitem__('pid',p['pid']),
          'argv':lambda r,p:r['transcript']['cases'][0]['argv'].__setitem__(0,'/tmp/copied-cli'),
          'output':lambda r,p:r['transcript']['cases'][4].__setitem__('stdout',cli.stream_binding(b'0.8.0\n')),
          'scope':lambda r,p:r['provenance'].__setitem__('distribution_qualified',True),
          'build-id':lambda r,p:r['provenance'].__setitem__('build_evidence_id',INSTALL),
          'framework':lambda r,p:r['transcript']['bundle_before'].pop(),
          'nonce':lambda r,p:r.__setitem__('challenge_nonce','b'*64),
          'identity':lambda r,p:r['transcript'].__setitem__('bundle_build','2'),
          'capture-credit':lambda r,p:r['transcript'].__setitem__('signing_assessed',True),
          'interposition':lambda r,p:r['transcript']['cases'][0]['environment'].__setitem__('DYLD_LIBRARY_PATH','/tmp/other'),
          'timing':lambda r,p:r['transcript']['cases'][0].__setitem__('started_at','2020-01-01T00:00:00+00:00'),
        }
        for label,mutate in mutations.items():
            with self.subTest(label=label):
                altered=copy.deepcopy(result);child=copy.deepcopy(process);mutate(altered,child)
                self.assertFalse(native.validate_result(self.root,altered,evidence_id=EVIDENCE,nonce=NONCE,process=child))

    def test_source_bundle_without_recorded_installation_cannot_qualify(self):
        (self.root/f'.forge-codex/evidence/{INSTALL}.json').unlink()
        with self.assertRaises(EvidenceSupportError): self.capture()

    def test_exact_registry_maps_only_two_assertions_and_preserves_all_other_blockers(self):
        registry=json.loads((REPO/baseline.FEATURE_REGISTRY_PATH).read_bytes())
        raw=(REPO/baseline.PRODUCTION_PROBE_REGISTRY_PATH).read_bytes();probes=json.loads(raw)
        qualifier_raw=(REPO/baseline.FEATURE_QUALIFIER_PATH).read_bytes()
        failures,mappings,missing=reader._validate_probe_registry(REPO,probes,probe_registry_artifact={'path':baseline.PRODUCTION_PROBE_REGISTRY_PATH,'sha256':hashlib.sha256(raw).hexdigest(),'bytes':len(raw)},qualifier_artifact={'path':baseline.FEATURE_QUALIFIER_PATH,'sha256':hashlib.sha256(qualifier_raw).hexdigest(),'bytes':len(qualifier_raw)},registry_features={f['id']:f for f in registry['features']},canonical_feature_registry=True)
        self.assertEqual(set(mappings),{b['assertion_id'] for b in native.SCENARIO['assertions']})
        self.assertEqual(len(missing),257)
        self.assertEqual(len(failures),2,failures)
        self.assertTrue(any('257 authoritative' in item for item in failures))
        for mutate in (lambda p:p['assertions'][0]['expected'].__setitem__('contract','fixture'),lambda p:p['installation'].__setitem__('root',str(self.source)),lambda p:p['assertions'].pop()):
            altered=copy.deepcopy(native.SCENARIO);mutate(altered)
            self.assertFalse(native.scenario_valid(altered))

    def test_selected_capture_and_strict_reader_accept_two_assertions_but_never_full_matrix(self):
        import check_p10_selected_cli as selected
        for relative in (baseline.FEATURE_REGISTRY_PATH, baseline.PRODUCTION_PROBE_REGISTRY_PATH, baseline.FEATURE_QUALIFIER_PATH, baseline.FEATURE_QUALIFICATION_SCHEMA_PATH):
            target=self.root/relative;target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(REPO/relative,target)
        (self.root/baseline.FEATURE_BASELINE_PATH).write_text('{}')
        self.persist()
        environment={'FORGE_EVIDENCE_ID':EVIDENCE,'FORGE_EVIDENCE_PLATFORM':'macOS-fixture','FORGE_EVIDENCE_ARCHITECTURE':'arm64','FORGE_EVIDENCE_MACOS_BUILD':'25A1','FORGE_EVIDENCE_MACHINE_IDENTIFIER':'MacFixture1,1'}
        def signature(binding,installation):
            artifact=next(item for item in installation['artifacts'] if item['artifact_id']=='forge-conductor-cli')
            return {'applicable':True,'artifact_id':artifact['artifact_id'],'path':artifact['path'],'artifact_sha256':artifact['sha256'],'artifact_bytes':artifact['bytes'],'team_id':'9AQ2C2838M','identifier':'com.forge-conductor.cli','cdhash':'a'*40,'designated_requirement_sha256':'b'*64,'hardened_runtime':True}
        arguments=['qualify_p10_features.py','--repo',str(self.root),'--report',qualifier.REPORT_PATH,'--feature',native.FEATURE_ID,'--build-evidence',BUILD,'--installation-evidence',INSTALL]
        captured=io.StringIO()
        started=qualifier.now()
        with mock.patch.object(qualifier,'__file__',str(self.root/baseline.FEATURE_QUALIFIER_PATH)),mock.patch.object(sys,'argv',arguments),mock.patch.dict(os.environ,environment),mock.patch.object(qualifier,'current_git_head',return_value=HEAD),mock.patch.object(cli,'execute_command',side_effect=self.command),mock.patch.object(qualifier,'derive_signing_fact',side_effect=signature),contextlib.redirect_stdout(captured):
            self.assertEqual(qualifier.main(),0)
        ended=qualifier.now()
        report=json.loads((self.root/qualifier.REPORT_PATH).read_bytes())
        self.assertEqual(report['execution']['passed_assertion_count'],2)
        self.assertEqual(report['selection']['global_required_assertion_count'],259)
        self.assertEqual(len(report['selection']['global_missing_assertion_ids']),257)
        self.assertEqual([row['feature_id'] for row in report['results']],[native.FEATURE_ID])
        record=self.make_record(EVIDENCE,'p10-feature-production-qualification',0)
        record.update(command=shlex.join(report['command']['argv']),started_at=started,ended_at=ended,related_findings=[])
        manifest=source_manifest(self.root)
        machine={'platform':'macOS-fixture','architecture':'arm64','macos_build':'25A1','machine_identifier':'MacFixture1,1'}
        repo={'branch':'fixture','head_sha':HEAD,'base_branch':'main','base_sha':HEAD,'repository_path':str(self.root)}
        record.update(environment={**machine,'cwd':str(self.root)},execution_provenance={'repository':repo,'test_environment':machine},child_evidence_context={'schema_version':1,'binding_schema_version':1,'evidence_id':EVIDENCE,'source_manifest':manifest,'repository':repo,'test_environment':machine},source_manifest=manifest,source_manifest_after=manifest,source_manifest_changed=False)
        raw=captured.getvalue().encode();path=self.root/f'.forge-codex/evidence/{EVIDENCE}.stdout.txt';path.write_bytes(raw);record['artifacts'][0].update(bytes=len(raw),sha256=hashlib.sha256(raw).hexdigest())
        for index,relative in enumerate((qualifier.REPORT_PATH,qualifier.OBSERVATION_PATH)):
            raw=(self.root/relative).read_bytes();path=f'.forge-codex/evidence/{EVIDENCE}.artifact-{index:03d}-{pathlib.Path(relative).name}'
            (self.root/path).write_bytes(raw);record['artifacts'].append({'path':path,'source_path':relative,'bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest(),'storage':'evidence-id-specific-copy'})
        record_path=self.root/f'.forge-codex/evidence/{EVIDENCE}.json';record_path.write_text(json.dumps(record))
        state_path=self.root/'.forge-codex/state/run-state.json';state=json.loads(state_path.read_bytes());state['evidence'].append(f'.forge-codex/evidence/{EVIDENCE}.json');state_path.write_text(json.dumps(state))
        with mock.patch.object(selected,'current_git_head',return_value='b'*40),mock.patch.object(reader,'validate_source_candidate',side_effect=self.fixture_candidate),mock.patch.object(reader,'derive_signing_fact',side_effect=signature):
            result=selected.evaluate(self.root,EVIDENCE)
            self.assertTrue(result['accepted'],result['failures'])
            self.assertEqual(result['accepted_assertion_count'],2)
            self.assertFalse(result['full_matrix_complete'])
            self.assertEqual(len(result['missing_assertion_ids']),257)
            # Even resealing a modified report cannot claim distribution or another scope.
            report_artifact=record['artifacts'][2]
            report_path=self.root/report_artifact['path']
            for field,value in [('distribution_qualified',True),('global_required_assertion_count',2),('build_evidence_id',INSTALL)]:
                altered=copy.deepcopy(report);altered['selection'][field]=value;raw=json.dumps(altered).encode();report_path.write_bytes(raw)
                report_artifact.update(bytes=len(raw),sha256=hashlib.sha256(raw).hexdigest());record_path.write_text(json.dumps(record))
                rejected=selected.evaluate(self.root,EVIDENCE)
                self.assertFalse(rejected['accepted'],field)

    def test_default_matrix_retains_104_features_and_rejects_missing_provenance(self):
        for relative in (baseline.FEATURE_REGISTRY_PATH,baseline.PRODUCTION_PROBE_REGISTRY_PATH):
            target=self.root/relative;target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(REPO/relative,target)
        (self.root/baseline.FEATURE_BASELINE_PATH).write_text('{}')
        args=['qualify_p10_features.py','--repo',str(self.root),'--report',qualifier.REPORT_PATH]
        with mock.patch.object(sys,'argv',args),mock.patch.dict(os.environ,{'FORGE_EVIDENCE_ID':EVIDENCE}),mock.patch.object(qualifier,'current_git_head',return_value=HEAD),mock.patch.object(cli,'execute_command') as execute,contextlib.redirect_stdout(io.StringIO()),contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(qualifier.main(),2)
        execute.assert_not_called()
        report=json.loads((self.root/qualifier.REPORT_PATH).read_bytes())
        self.assertEqual(len(report['results']),104)
        self.assertEqual(report['coverage']['required_assertion_count'],259)
        self.assertEqual(report['coverage']['missing_assertion_count'],257)
        self.assertEqual(report['execution']['passed_assertion_count'],0)
        self.assertFalse(report['environment']['installed_product'])

    def test_checked_bundle_requires_current_source_version_build_and_development_class(self):
        checked=self.signatures.temp_original
        for version,build,authority,passes in [('0.9.0','1','Apple Development: Fixture',True),('0.8.0','1','Apple Development: Fixture',False),('0.9.0','2','Apple Development: Fixture',False),('0.9.0','1','Developer ID Application: Fixture',False)]:
            signature={'version':version,'build':build,'signing_authority':authority}
            with mock.patch.object(native,'execute_command',return_value=(0,False,False)),mock.patch.object(native,'validate_application_bundle',return_value=signature):
                if passes: self.assertEqual(checked(self.root,self.app),signature)
                else:
                    with self.assertRaises(EvidenceSupportError): checked(self.root,self.app)

    def test_real_codesign_code_directory_line_is_parsed_without_runtime_downgrade(self):
        binding=native.SCENARIO['assertions'][1]
        artifact={'artifact_id':'forge-conductor-cli','path':'/fixture/cli','sha256':'a'*64,'bytes':42}
        details=b'Identifier=com.forge-conductor.cli\nTeamIdentifier=9AQ2C2838M\nCodeDirectory v=20500 size=99 flags=0x10000(runtime) hashes=2+7 location=embedded\nCDHash='+b'a'*40+b'\n'
        for flags,passes in ((details,True),(details.replace(b'0x10000(runtime)',b'0x0(none)'),False)):
            with mock.patch.object(qualifier.subprocess,'run',side_effect=[subprocess.CompletedProcess([],0,b'',flags),subprocess.CompletedProcess([],0,b'',b'designated => fixture')]):
                if passes: self.assertTrue(qualifier.derive_signing_fact(binding,{'artifacts':[artifact]})['hardened_runtime'])
                else:
                    with self.assertRaises(EvidenceSupportError): qualifier.derive_signing_fact(binding,{'artifacts':[artifact]})


if __name__=='__main__': unittest.main()
