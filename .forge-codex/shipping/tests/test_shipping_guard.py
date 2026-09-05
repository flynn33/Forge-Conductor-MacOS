"""Synthetic regression tests for integrity tooling, not Forge application tests."""
import argparse
import contextlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts' / 'shipping_guard.py'
spec = importlib.util.spec_from_file_location('shipping_guard', SCRIPT)
g = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = g
spec.loader.exec_module(g)
SHA = 'a' * 40
OTHER_SHA = 'b' * 40
SOURCE = 'public static let productVersion = "0.9.0"\npublic static let productBuildVersion = "2"\n'
PROJECT = '\n'.join(['MARKETING_VERSION = 0.9.0;', 'CURRENT_PROJECT_VERSION = 2;'] * 2)

def review(updated=()):
    return {'schema_version':1, 'reviewed_base':SHA, 'documents':[
        {'path':p, 'status':'updated' if p in updated else 'not_applicable',
         'reason':'Reviewed against the actual change; this explanation is intentionally explicit.'}
        for p in g.REQUIRED_DOCS]}

def settings(version='0.9.0', build='2'):
    return [{'target':'ForgeConductor', 'buildSettings':{
        'PRODUCT_BUNDLE_IDENTIFIER':'com.forge-conductor.app',
        'MARKETING_VERSION':version,'CURRENT_PROJECT_VERSION':build}}]

class VersionTests(unittest.TestCase):
    def test_canonical_pair(self):
        self.assertEqual(g.canonical_version(SOURCE), ('0.9.0','2'))
    def test_duplicate_constant_rejected(self):
        with self.assertRaises(g.IntegrityError): g.canonical_version(SOURCE + SOURCE)
    def test_missing_constant_rejected(self):
        with self.assertRaises(g.IntegrityError): g.canonical_version('')
    def test_leading_zero_marketing_rejected(self):
        with self.assertRaises(g.IntegrityError): g.canonical_version(SOURCE.replace('0.9.0','0.09.0'))
    def test_zero_build_rejected(self):
        with self.assertRaises(g.IntegrityError): g.canonical_version(SOURCE.replace('"2"','"0"'))
    def test_xcode_literals_match(self):
        self.assertEqual(g.check_project_versions(PROJECT,'0.9.0','2')['MARKETING_VERSION'], 2)
    def test_xcode_stale_release_rejected(self):
        with self.assertRaises(g.IntegrityError):
            g.check_project_versions(PROJECT.replace('CURRENT_PROJECT_VERSION = 2','CURRENT_PROJECT_VERSION = 1',1),'0.9.0','2')
    def test_xcode_unresolved_generation_rejected(self):
        with self.assertRaises(g.IntegrityError):
            g.check_project_versions(PROJECT.replace('0.9.0','$(SOME_VERSION)'),'0.9.0','2')
    def test_xcode_absent_configuration_rejected(self):
        with self.assertRaises(g.IntegrityError): g.check_project_versions('','0.9.0','2')
    def test_resolved_settings_match(self):
        self.assertEqual(g.check_resolved_settings(settings(),'0.9.0','2'), 2)
    def test_resolved_settings_need_app(self):
        data=settings(); data[0]['buildSettings']['PRODUCT_BUNDLE_IDENTIFIER']='com.forge-conductor.tests'
        with self.assertRaises(g.IntegrityError): g.check_resolved_settings(data,'0.9.0','2')
    def test_resolved_settings_mismatch(self):
        with self.assertRaises(g.IntegrityError): g.check_resolved_settings(settings(build='1'),'0.9.0','2')
    def test_resolved_settings_placeholder_rejected(self):
        with self.assertRaises(g.IntegrityError): g.check_resolved_settings(settings(build='$(CURRENT_PROJECT_VERSION)'),'0.9.0','2')
    def test_resolved_settings_empty_rejected(self):
        with self.assertRaises(g.IntegrityError): g.check_resolved_settings([],'0.9.0','2')
    def test_built_plist_match(self):
        g.check_plist_versions({'CFBundleShortVersionString':'0.9.0','CFBundleVersion':'2'},'0.9.0','2')
    def test_source_placeholders_allowed(self):
        g.check_plist_versions({'CFBundleShortVersionString':'$(MARKETING_VERSION)','CFBundleVersion':'$(CURRENT_PROJECT_VERSION)'},'0.9.0','2',source=True)
    def test_built_placeholder_rejected(self):
        with self.assertRaises(g.IntegrityError):
            g.check_plist_versions({'CFBundleShortVersionString':'0.9.0','CFBundleVersion':'$(CURRENT_PROJECT_VERSION)'},'0.9.0','2')
    def test_built_stale_version_rejected(self):
        with self.assertRaises(g.IntegrityError):
            g.check_plist_versions({'CFBundleShortVersionString':'0.8.0','CFBundleVersion':'2'},'0.9.0','2')

class DocumentationTests(unittest.TestCase):
    def test_product_change_and_changelog_pass(self):
        g.validate_doc_review({'Sources/x.swift','CHANGELOG.md'},review(['CHANGELOG.md']),SHA,False)
    def test_wrong_base_rejected(self):
        with self.assertRaises(g.IntegrityError): g.validate_doc_review(set(),review(),OTHER_SHA,False)
    def test_missing_review_rejected(self):
        r=review(); r['documents'].pop()
        with self.assertRaises(g.IntegrityError): g.validate_doc_review(set(),r,SHA,False)
    def test_not_reviewed_rejected(self):
        r=review(); r['documents'][0]['status']='not_reviewed'
        with self.assertRaises(g.IntegrityError): g.validate_doc_review(set(),r,SHA,False)
    def test_fake_updated_without_diff_rejected(self):
        with self.assertRaises(g.IntegrityError): g.validate_doc_review(set(),review(['README.md']),SHA,False)
    def test_product_change_without_changelog_rejected(self):
        with self.assertRaises(g.IntegrityError): g.validate_doc_review({'Package.swift'},review(),SHA,False)
    def test_release_requires_all_four_updates(self):
        with self.assertRaises(g.IntegrityError):
            g.validate_doc_review({'CHANGELOG.md'},review(['CHANGELOG.md']),SHA,True)
    def test_release_review_passes(self):
        g.validate_doc_review(set(g.REQUIRED_DOCS),review(g.REQUIRED_DOCS),SHA,True)
    def test_trivial_reason_rejected(self):
        r=review(); r['documents'][0]['reason']='N/A'
        with self.assertRaises(g.IntegrityError): g.validate_doc_review(set(),r,SHA,False)
    def test_duplicate_review_rejected(self):
        r=review(); r['documents'].append(copy.deepcopy(r['documents'][0]))
        with self.assertRaises(g.IntegrityError): g.validate_doc_review(set(),r,SHA,False)
    def test_changed_topical_doc_requires_review(self):
        with self.assertRaises(g.IntegrityError):
            g.validate_doc_review({'docs/LM-STUDIO-CONNECTION.md'},review(),SHA,False)
    def test_unsafe_review_path_rejected(self):
        r=review(); r['documents'].append({'path':'../private','status':'not_applicable','reason':'A sufficiently long explanation but the path remains unsafe.'})
        with self.assertRaises(g.IntegrityError): g.validate_doc_review(set(),r,SHA,False)

class RemoteTests(unittest.TestCase):
    def test_standard_urls(self):
        for url in ['https://github.com/flynn33/Forge-Conductor-MacOS.git',
                    'git@github.com:flynn33/Forge-Conductor-MacOS.git',
                    'ssh://git@github.com/flynn33/Forge-Conductor-MacOS.git']:
            self.assertEqual(g.normalize_remote(url),g.EXPECTED_REPOSITORY)
    def test_wrong_repository(self):
        with self.assertRaises(g.IntegrityError): g.normalize_remote('https://github.com/flynn33/another.git')
    def test_wrong_host(self):
        with self.assertRaises(g.IntegrityError): g.normalize_remote('https://github.example/flynn33/Forge-Conductor-MacOS.git')
    def test_credential_url(self):
        with self.assertRaises(g.IntegrityError): g.normalize_remote('https://token@github.com/flynn33/Forge-Conductor-MacOS.git')
    def test_live_branch_parse(self):
        self.assertEqual(g.parse_remote_head(SHA+'\trefs/heads/release/ship\n','release/ship'),SHA)
    def test_live_branch_absent(self):
        with self.assertRaises(g.IntegrityError): g.parse_remote_head('','main')
    def test_live_branch_ambiguous(self):
        with self.assertRaises(g.IntegrityError):
            g.parse_remote_head((SHA+' refs/heads/main\n')*2,'main')
    def test_clean_equal_snapshot(self):
        g.verify_sync_snapshot('main','main','',SHA,SHA,SHA,SHA)
    def test_dirty_snapshot(self):
        with self.assertRaises(g.IntegrityError): g.verify_sync_snapshot('main','main','?? new.swift',SHA,SHA,SHA)
    def test_detached_checkout(self):
        with self.assertRaises(g.IntegrityError): g.verify_sync_snapshot('HEAD','main','',SHA,SHA,SHA)
    def test_local_remote_divergence(self):
        with self.assertRaises(g.IntegrityError): g.verify_sync_snapshot('main','main','',SHA,OTHER_SHA,SHA)
    def test_push_fetch_divergence(self):
        with self.assertRaises(g.IntegrityError): g.verify_sync_snapshot('main','main','',SHA,SHA,OTHER_SHA)
    def test_expected_delivery_identity(self):
        with self.assertRaises(g.IntegrityError): g.verify_sync_snapshot('main','main','',SHA,SHA,SHA,OTHER_SHA)

class XcodeTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        path=self.root/'Sources/ForgeConductorApp/Main.swift'; path.parent.mkdir(parents=True); path.write_text('')
        self.doc={'objects':{
            'ROOT':{'isa':'PBXGroup','sourceTree':'<group>','children':['GROUP']},
            'GROUP':{'isa':'PBXGroup','sourceTree':'<group>','path':'Sources/ForgeConductorApp','children':['FILE']},
            'FILE':{'isa':'PBXFileReference','sourceTree':'<group>','path':'Main.swift'},
            'BUILD':{'isa':'PBXBuildFile','fileRef':'FILE'},
            'PHASE':{'isa':'PBXSourcesBuildPhase','files':['BUILD']},
            'TARGET':{'isa':'PBXNativeTarget','name':'ForgeConductor','buildPhases':['PHASE']}}}
    def memberships(self):
        return g.XcodeProject(self.doc,self.root).source_memberships()
    def test_real_group_and_target_resolution(self):
        self.assertEqual(self.memberships(),{'ForgeConductor':{'Sources/ForgeConductorApp/Main.swift'}})
    def test_missing_compiled_file(self):
        self.doc['objects']['FILE']['path']='Missing.swift'
        with self.assertRaises(g.IntegrityError): self.memberships()
    def test_duplicate_compile_entry(self):
        self.doc['objects']['PHASE']['files'].append('BUILD')
        with self.assertRaises(g.IntegrityError): self.memberships()
    def test_dangling_file_reference(self):
        self.doc['objects']['BUILD']['fileRef']='ABSENT'
        with self.assertRaises(g.IntegrityError): self.memberships()
    def test_synchronized_group_not_silent_pass(self):
        self.doc['objects']['GROUP']['isa']='PBXFileSystemSynchronizedRootGroup'
        with self.assertRaises(g.ExecutionError): self.memberships()
    def test_cycle_rejected(self):
        self.doc['objects']['GROUP']['children'].append('ROOT')
        with self.assertRaises(g.ExecutionError): self.memberships()
    def test_production_membership_checked(self):
        count, notes=g.check_memberships(['Sources/ForgeConductorApp/Main.swift'],self.memberships())
        self.assertEqual(count,1); self.assertEqual(notes,[])
    def test_unwired_new_file_rejected(self):
        with self.assertRaises(g.IntegrityError):
            g.check_memberships(['Sources/ForgeConductorApp/Unwired.swift'],self.memberships())
    def test_plugin_expected_in_xcode_core(self):
        path='Sources/ForgeNativeSessionHostPlugin/Plugin.swift'
        g.check_memberships([path],{'ForgeConductorCore':{path}})
    def test_unknown_module_requires_review(self):
        with self.assertRaises(g.ExecutionError):
            g.check_memberships(['Sources/NewModule/A.swift'],{'NewModule':{'Sources/NewModule/A.swift'}})
    def test_zero_sources_never_passes(self):
        with self.assertRaises(g.IntegrityError): g.check_memberships([],self.memberships())
    def test_test_omissions_explicit(self):
        count, notes=g.check_memberships(['Sources/ForgeConductorApp/Main.swift','Tests/OnlySPM.swift'],self.memberships())
        self.assertEqual(notes,['Tests/OnlySPM.swift'])
    def test_generated_path_needs_explicit_support(self):
        self.doc['objects']['FILE']['path']='$(DERIVED_FILE_DIR)/Generated.swift'
        with self.assertRaises(g.ExecutionError): self.memberships()

class CLIIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.repo=Path(self.temp.name)/'repo'; self.repo.mkdir()
        self.git('init','-q'); self.git('config','user.name','Test Fixture'); self.git('config','user.email','fixture@example.invalid')
        (self.repo/g.VERSION_SOURCE).parent.mkdir(parents=True)
        (self.repo/g.VERSION_SOURCE).write_text(SOURCE)
        (self.repo/g.PROJECT).parent.mkdir(parents=True)
        (self.repo/g.PROJECT).write_text(PROJECT)
        for doc in g.REQUIRED_DOCS: (self.repo/doc).write_text('# '+doc+'\n')
        self.git('add','.'); self.git('commit','-qm','fixture baseline')
        self.base=self.git('rev-parse','HEAD').strip()
    def git(self,*args):
        return subprocess.check_output(['git',*args],cwd=self.repo,text=True,stderr=subprocess.PIPE)
    def run_guard(self, args):
        stream=io.StringIO()
        with contextlib.redirect_stdout(stream):
            exit_code=g.main(args)
        return exit_code,json.loads(stream.getvalue())
    def test_versions_cli_success(self):
        code,data=self.run_guard(['versions','--repo',str(self.repo)])
        self.assertEqual(code,0); self.assertEqual(data['status'],'passed')
    def test_environment_build_override_fails(self):
        with mock.patch.dict(os.environ,{'FORGE_BUILD_NUMBER':'99'}):
            code,data=self.run_guard(['versions','--repo',str(self.repo)])
        self.assertEqual(code,1)
    def test_source_xcode_drift_cli_fails(self):
        (self.repo/g.PROJECT).write_text(PROJECT.replace('0.9.0','0.8.0'))
        code,_=self.run_guard(['versions','--repo',str(self.repo)]); self.assertEqual(code,1)
    def test_native_guard_not_run_on_linux(self):
        with mock.patch.object(g.sys,'platform','linux'):
            code,data=self.run_guard(['xcode','--repo',str(self.repo)])
        self.assertEqual(code,2); self.assertEqual(data['status'],'not_completed')
    def test_staged_release_doc_review(self):
        for doc in g.REQUIRED_DOCS: (self.repo/doc).write_text('# '+doc+'\nUpdated release.\n')
        self.git('add',*g.REQUIRED_DOCS)
        r=review(g.REQUIRED_DOCS); r['reviewed_base']=self.base
        p=Path(self.temp.name)/'review.json'; p.write_text(json.dumps(r))
        code,data=self.run_guard(['docs','--repo',str(self.repo),'--base',self.base,
                                   '--review',str(p),'--index','--release'])
        self.assertEqual(code,0); self.assertEqual(data['facts']['snapshot'],'index')
    def test_unstaged_docs_do_not_count_as_updated(self):
        for doc in g.REQUIRED_DOCS: (self.repo/doc).write_text('Changed but not staged.\n')
        r=review(g.REQUIRED_DOCS); r['reviewed_base']=self.base
        p=Path(self.temp.name)/'review.json'; p.write_text(json.dumps(r))
        code,_=self.run_guard(['docs','--repo',str(self.repo),'--base',self.base,
                              '--review',str(p),'--index','--release'])
        self.assertEqual(code,1)
    def release_review(self):
        r=review(g.REQUIRED_DOCS); r['reviewed_base']=self.base
        p=Path(self.temp.name)/'review.json'; p.write_text(json.dumps(r))
        return ['docs','--repo',str(self.repo),'--base',self.base,
                '--review',str(p),'--release']
    def test_staged_deleted_docs_cannot_pass_using_untracked_copies(self):
        self.git('rm',*g.REQUIRED_DOCS)
        for doc in g.REQUIRED_DOCS: (self.repo/doc).write_text('Untracked restored copy.\n')
        code,data=self.run_guard(self.release_review()+['--index'])
        self.assertEqual(code,1); self.assertIn('index snapshot',data['message'])
    def test_committed_deleted_docs_cannot_pass_using_untracked_copies(self):
        self.git('rm',*g.REQUIRED_DOCS); self.git('commit','-qm','fixture deletion')
        for doc in g.REQUIRED_DOCS: (self.repo/doc).write_text('Untracked restored copy.\n')
        code,data=self.run_guard(self.release_review())
        self.assertEqual(code,1); self.assertIn('HEAD snapshot',data['message'])
    def test_staged_document_symlink_is_not_a_regular_document(self):
        for doc in g.REQUIRED_DOCS: (self.repo/doc).write_text('Updated release.\n')
        (self.repo/'README.md').unlink()
        (self.repo/'README.md').symlink_to('USER-GUIDE.md')
        self.git('add',*g.REQUIRED_DOCS)
        code,_=self.run_guard(self.release_review()+['--index']); self.assertEqual(code,1)
    def test_staged_docs_are_checked_independently_of_worktree_deletions(self):
        for doc in g.REQUIRED_DOCS: (self.repo/doc).write_text('Updated release.\n')
        self.git('add',*g.REQUIRED_DOCS)
        for doc in g.REQUIRED_DOCS: (self.repo/doc).unlink()
        code,_=self.run_guard(self.release_review()+['--index']); self.assertEqual(code,0)
    def test_committed_docs_are_checked_independently_of_worktree_deletions(self):
        for doc in g.REQUIRED_DOCS: (self.repo/doc).write_text('Updated release.\n')
        self.git('add',*g.REQUIRED_DOCS); self.git('commit','-qm','fixture release')
        for doc in g.REQUIRED_DOCS: (self.repo/doc).unlink()
        code,_=self.run_guard(self.release_review()); self.assertEqual(code,0)
    def test_missing_repository_fails_execution(self):
        code,_=self.run_guard(['versions','--repo',str(self.repo/'absent')]); self.assertEqual(code,2)

if __name__=='__main__': unittest.main()
