#!/usr/bin/env python3
"""Real Git regressions for source-candidate and evidence-delivery separation."""
from __future__ import annotations

import pathlib
import hashlib
import json
import subprocess
import tempfile
import unittest

from evidence_support import EvidenceSupportError, source_manifest
from p10_source_candidate import validate_source_candidate


class SourceCandidateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name).resolve()
        self.git('init','-q','-b','fixture')
        self.git('config','user.name','Release Test Fixture')
        self.git('config','user.email','fixture@example.invalid')
        self.write('Sources/App.swift','let productVersion = "0.9.0"\n')
        self.write('Package.swift','// fixture package\n')
        self.write('.forge-codex/state/feature-baseline.json','{"fixture":true}\n')
        self.write('.gitignore','**/__pycache__/\n**/xcuserdata/\nSources/ignored.swift\n')
        self.commit('source candidate')
        self.candidate = self.git('rev-parse','HEAD')
        self.manifest = source_manifest(self.root)

    def git(self,*arguments):
        return subprocess.run(['/usr/bin/git',*arguments],cwd=self.root,check=True,capture_output=True,text=True).stdout.strip()

    def write(self,relative,contents):
        target=self.root/relative;target.parent.mkdir(parents=True,exist_ok=True);target.write_text(contents)

    def commit(self,message):
        self.git('add','-A');self.git('commit','-q','-m',message)

    def validate(self,candidate=None):
        validate_source_candidate(self.root,candidate or self.candidate,self.git('rev-parse','HEAD'),self.manifest,source_manifest(self.root))

    def test_current_clean_candidate_and_evidence_only_descendant_are_accepted(self):
        self.validate()
        self.write('.forge-codex/evidence/EVID-fixture.json','{"result":"fixture"}')
        self.write('.forge-codex/state/current-handoff.json','{"candidate":"'+self.candidate+'"}')
        self.commit('retain qualification evidence')
        self.assertNotEqual(self.candidate,self.git('rev-parse','HEAD'))
        self.assertEqual(self.manifest,source_manifest(self.root))
        self.validate()
        # Generated interpreter and per-user Xcode state do not enter the manifest.
        self.write('.forge-codex/scripts/__pycache__/fixture.pyc','cache')
        self.write('ForgeConductor.xcodeproj/xcuserdata/person.xcuserdatad/fixture','ui')
        self.validate()

    def test_native_record_revalidates_original_candidate_after_committed_evidence(self):
        import p10_native_cli_scenario as native
        evidence_id='EVID-delivery-fixture'
        artifacts=[]
        for suffix in ('stdout','stderr'):
            path=f'.forge-codex/evidence/{evidence_id}.{suffix}.txt'
            self.write(path,'')
            artifacts.append({'path':path,'bytes':0,'sha256':hashlib.sha256(b'').hexdigest(),'storage':'evidence-id-specific-stream'})
        relative=f'.forge-codex/evidence/{evidence_id}.json'
        record={'schema_version':2,'id':evidence_id,'kind':'p10-native-cli-build','exit_code':0,'timed_out':False,'stream_limit_exceeded':False,'artifact_capture_errors':[],'ledger_reference':{'status':'recorded','exit_code':0},'source_manifest':self.manifest,'source_manifest_after':self.manifest,'source_manifest_changed':False,'execution_provenance':{'repository':{'head_sha':self.candidate}},'environment':{'cwd':str(self.root)},'related_gates':['G10'],'maximum_stream_bytes':67108864,'started_at':'2026-09-04T00:00:00+00:00','ended_at':'2026-09-04T00:01:00+00:00','artifacts':artifacts}
        self.write(relative,json.dumps(record));self.write('.forge-codex/state/run-state.json',json.dumps({'evidence':[relative]}))
        self.commit('retain fixture evidence')
        observed,_=native.record(self.root,evidence_id,'p10-native-cli-build',exits={0})
        self.assertEqual(observed['execution_provenance']['repository']['head_sha'],self.candidate)
        self.assertNotEqual(self.git('rev-parse','HEAD'),self.candidate)
        self.write('Sources/App.swift','changed');self.commit('change source')
        self.write('Sources/App.swift','let productVersion = "0.9.0"\n');self.commit('revert source')
        with self.assertRaisesRegex(EvidenceSupportError,'delivery history'):native.record(self.root,evidence_id,'p10-native-cli-build',exits={0})

    def test_source_edit_and_revert_are_rejected_despite_identical_final_manifest(self):
        self.write('Sources/App.swift','changed input\n');self.commit('change input')
        with self.assertRaises(EvidenceSupportError):self.validate()
        self.write('Sources/App.swift','let productVersion = "0.9.0"\n');self.commit('revert input')
        self.assertEqual(self.manifest,source_manifest(self.root))
        with self.assertRaisesRegex(EvidenceSupportError,'delivery history'):self.validate()

    def test_unrelated_same_tree_commit_is_not_a_source_candidate(self):
        tree=self.git('rev-parse','HEAD^{tree}')
        unrelated=self.git('commit-tree',tree,'-m','unrelated same tree')
        with self.assertRaises(EvidenceSupportError):self.validate(unrelated)

    def test_dirty_tracked_staged_untracked_and_ignored_controlled_files_are_rejected(self):
        cases=[('Sources/App.swift','changed'),('Sources/New.swift','new'),('Sources/ignored.swift','ignored'),('ForgeConductor.xcodeproj/xcshareddata/xcschemes/ForgeConductor.xcscheme','scheme')]
        for relative,value in cases:
            with self.subTest(relative=relative):
                original=(self.root/relative).read_bytes() if (self.root/relative).exists() else None
                self.write(relative,value)
                # Even a caller supplying a matching dirty manifest cannot promote it.
                dirty=source_manifest(self.root)
                with self.assertRaises(EvidenceSupportError):validate_source_candidate(self.root,self.candidate,self.candidate,dirty,dirty)
                if relative=='Sources/App.swift':
                    self.git('add',relative)
                    with self.assertRaises(EvidenceSupportError):validate_source_candidate(self.root,self.candidate,self.candidate,dirty,dirty)
                    self.git('reset','-q','HEAD','--',relative)
                if original is None:(self.root/relative).unlink()
                else:(self.root/relative).write_bytes(original)

    def test_controlled_state_and_non_evidence_delivery_edits_are_not_exempt(self):
        for relative in ('.forge-codex/state/feature-baseline.json','README.md'):
            with self.subTest(relative=relative):
                self.write(relative,'changed');self.commit('non evidence change')
                with self.assertRaises(EvidenceSupportError):self.validate()

    def test_source_change_on_merged_branch_is_rejected_after_revert(self):
        self.git('checkout','-q','-b','side')
        self.write('Sources/App.swift','side input');self.commit('side input')
        self.write('Sources/App.swift','let productVersion = "0.9.0"\n');self.commit('side revert')
        self.git('checkout','-q','fixture')
        self.write('.forge-codex/evidence/fixture.txt','evidence');self.commit('evidence')
        self.git('merge','--no-ff','-q','side','-m','merge side evidence')
        self.assertEqual(self.manifest,source_manifest(self.root))
        with self.assertRaisesRegex(EvidenceSupportError,'delivery history'):self.validate()

    def test_incorrect_delivery_head_or_manifest_is_rejected(self):
        with self.assertRaises(EvidenceSupportError):validate_source_candidate(self.root,self.candidate,'b'*40,self.manifest,self.manifest)
        with self.assertRaises(EvidenceSupportError):validate_source_candidate(self.root,self.candidate,self.candidate,{'stale':True},self.manifest)


if __name__=='__main__':unittest.main()
