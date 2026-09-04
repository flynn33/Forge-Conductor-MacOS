#!/usr/bin/env python3
"""Read-only shipping integrity checks. A check pass is NOT release authorization."""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Set
from urllib.parse import urlsplit

EXPECTED_REPOSITORY = 'flynn33/Forge-Conductor-MacOS'
VERSION_SOURCE = 'Sources/ForgeFilesystemProtocol/ForgeFilesystemProtocol.swift'
PROJECT = 'ForgeConductor.xcodeproj/project.pbxproj'
REQUIRED_DOCS = ('README.md', 'CHANGELOG.md', 'USER-GUIDE.md', 'XCODE.md')
SOURCE_TARGETS = {
    'ForgeConductorApp': 'ForgeConductor',
    'ForgeConductorCLI': 'forge-conductor',
    'ForgeConductorCore': 'ForgeConductorCore',
    'ForgeFilesystemProtocol': 'ForgeFilesystemProtocol',
    'ForgeFilesystemDaemon': 'ForgeFilesystemDaemon',
    'ForgeRuntimeLauncher': 'ForgeRuntimeLauncher',
    # Intentional difference from SwiftPM in the audited native project:
    'ForgeNativeSessionHostPlugin': 'ForgeConductorCore',
    'ForgeFilesystemQualificationSupport': 'ForgeFilesystemQualificationSupport',
    'ForgeFilesystemQualificationHarness': 'ForgeFilesystemQualificationHarness',
    'ForgeFilesystemAdversary': 'ForgeFilesystemAdversary',
}

class IntegrityError(Exception):
    """A completed check found a mismatch."""

class ExecutionError(Exception):
    """The check could not execute completely or input is unsupported."""

@dataclass
class Report:
    check: str
    facts: Dict[str, Any] = field(default_factory=dict)
    warnings: List[str] = field(default_factory=list)

    def as_dict(self, status: str = 'passed') -> Dict[str, Any]:
        return {'check': self.check, 'status': status, 'facts': self.facts,
                'warnings': self.warnings,
                'scope': 'Named integrity check only; not product qualification or release authorization.'}

def execute(args: List[str], cwd: Path, allow_nonzero: bool = False) -> str:
    env = os.environ.copy()
    env['GIT_TERMINAL_PROMPT'] = '0'
    env.setdefault('GIT_SSH_COMMAND', 'ssh -o BatchMode=yes -o ConnectTimeout=10')
    try:
        result = subprocess.run(args, cwd=str(cwd), env=env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                timeout=45, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise ExecutionError('Tool unavailable or timed out: ' + args[0]) from exc
    if result.returncode != 0 and not allow_nonzero:
        # Avoid echoing potentially credential-bearing diagnostics.
        raise ExecutionError('Command failed; inspect locally without exposing secrets: '
                             + args[0] + ' (exit ' + str(result.returncode) + ')')
    return result.stdout

class Repository:
    def __init__(self, path: Path):
        if not path.is_dir():
            raise ExecutionError('Repository directory does not exist.')
        root = execute(['git', 'rev-parse', '--show-toplevel'], path).strip()
        self.root = Path(root).resolve()
        if self.root != path.resolve():
            raise ExecutionError('Pass the repository root, not a nested directory.')

    def git(self, *args: str) -> str:
        return execute(['git', *args], self.root)

    def read(self, relative: str) -> str:
        p = self.root / relative
        if not p.is_file():
            raise IntegrityError('Missing required file: ' + relative)
        if p.stat().st_size > 4 * 1024 * 1024:
            raise ExecutionError('Unexpectedly large metadata file: ' + relative)
        return p.read_text(encoding='utf-8')

    def resolve_commit(self, value: str) -> str:
        if not value or value.startswith('-'):
            raise ExecutionError('Invalid commit reference.')
        sha = self.git('rev-parse', '--verify', value + '^{commit}').strip()
        if not re.fullmatch(r'[0-9a-f]{40,64}', sha):
            raise ExecutionError('Unable to resolve exact commit.')
        return sha

def read_json(path: Path) -> Any:
    try:
        if path.stat().st_size > 8 * 1024 * 1024:
            raise ExecutionError('JSON metadata input exceeds 8 MiB.')
        return json.loads(path.read_text(encoding='utf-8'))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ExecutionError('Cannot read valid JSON metadata: ' + str(path)) from exc

def canonical_version(source: str) -> tuple:
    versions = re.findall(r'public\s+static\s+let\s+productVersion\s*=\s*"([^"\n]+)"', source)
    builds = re.findall(r'public\s+static\s+let\s+productBuildVersion\s*=\s*"([^"\n]+)"', source)
    if len(versions) != 1 or len(builds) != 1:
        raise IntegrityError('Expected exactly one canonical product version and build constant.')
    version, build = versions[0], builds[0]
    if not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', version):
        raise IntegrityError('Marketing version must be an unambiguous numeric MAJOR.MINOR.PATCH.')
    if not re.fullmatch(r'[1-9][0-9]*', build):
        raise IntegrityError('Build must be a positive integer.')
    return version, build

def check_project_versions(text: str, version: str, build: str) -> Dict[str, int]:
    counts = {}
    for key, expected in [('MARKETING_VERSION', version), ('CURRENT_PROJECT_VERSION', build)]:
        values = re.findall(r'\b' + key + r'\s*=\s*([^;\n]+);', text)
        if len(values) < 2:
            raise IntegrityError('Expected Debug/Release literal declarations for ' + key
                                 + '; inspect any changed build-system generation before adapting this guard.')
        normalized = [v.strip().strip('"') for v in values]
        wrong = sorted(set(v for v in normalized if v != expected))
        if wrong:
            raise IntegrityError(key + ' differs from canonical ' + expected + ': ' + ', '.join(wrong))
        counts[key] = len(values)
    return counts

def check_resolved_settings(rows: Any, version: str, build: str) -> int:
    if not isinstance(rows, list) or not rows:
        raise IntegrityError('No effective Xcode target settings were provided.')
    app_seen = False
    count = 0
    for row in rows:
        if not isinstance(row, dict) or not isinstance(row.get('buildSettings'), dict):
            raise IntegrityError('Malformed effective Xcode settings.')
        settings = row['buildSettings']
        if settings.get('PRODUCT_BUNDLE_IDENTIFIER') == 'com.forge-conductor.app':
            app_seen = True
            if 'MARKETING_VERSION' not in settings or 'CURRENT_PROJECT_VERSION' not in settings:
                raise IntegrityError('App is missing effective version/build settings.')
        for key, expected in [('MARKETING_VERSION', version), ('CURRENT_PROJECT_VERSION', build)]:
            if key in settings:
                count += 1
                if str(settings[key]) != expected:
                    raise IntegrityError('Effective ' + key + ' mismatch in target '
                                         + str(row.get('target', '<unknown>')))
    if not app_seen:
        raise IntegrityError('Effective settings must include the application target.')
    return count

def check_plist_versions(data: Dict[str, Any], version: str, build: str, source: bool = False) -> None:
    for key, expected, placeholder in [('CFBundleShortVersionString', version, '$(MARKETING_VERSION)'),
                                        ('CFBundleVersion', build, '$(CURRENT_PROJECT_VERSION)')]:
        value = str(data.get(key, ''))
        if value != expected and not (source and value == placeholder):
            raise IntegrityError('Info.plist ' + key + ' does not match canonical identity.')

def versions_command(repo: Repository, args: argparse.Namespace) -> Report:
    import plistlib
    version, build = canonical_version(repo.read(VERSION_SOURCE))
    if os.environ.get('FORGE_BUILD_NUMBER', build) != build:
        raise IntegrityError('FORGE_BUILD_NUMBER disagrees with compiled canonical build.')
    counts = check_project_versions(repo.read(PROJECT), version, build)
    for relative in ['Sources/ForgeConductorApp/Resources/Info.plist', 'Sources/ForgeConductorCLI/Info.plist']:
        p = repo.root / relative
        if p.exists():
            try:
                data = plistlib.loads(p.read_bytes())
            except (ValueError, plistlib.InvalidFileException) as exc:
                raise ExecutionError('Invalid source plist: ' + relative) from exc
            # A CLI plist may contain only sealing metadata. Check any declared versions.
            for key, expected, placeholder in [('CFBundleShortVersionString', version, '$(MARKETING_VERSION)'),
                                               ('CFBundleVersion', build, '$(CURRENT_PROJECT_VERSION)')]:
                if key in data and str(data[key]) not in (expected, placeholder):
                    raise IntegrityError(relative + ': version/build mismatch.')
    settings_count = 0
    for p in args.settings:
        settings_count += check_resolved_settings(read_json(Path(p)), version, build)
    if args.app:
        path = Path(args.app) / 'Contents/Info.plist'
        try:
            check_plist_versions(plistlib.loads(path.read_bytes()), version, build)
        except (OSError, ValueError, plistlib.InvalidFileException) as exc:
            raise ExecutionError('Cannot inspect built app Info.plist.') from exc
    return Report('versions', {'repository':str(repo.root), 'marketing_version':version, 'build':build,
                              'literal_xcode_declarations':counts,
                              'effective_setting_values_checked':settings_count,
                              'built_app_checked':bool(args.app)},
                  ['Nested Mach-O identities and runtime behavior require the native bundle checker.'])

def validate_doc_review(changed: Set[str], review: Any, base_sha: str, release: bool) -> List[str]:
    if not isinstance(review, dict) or review.get('schema_version') != 1:
        raise IntegrityError('Unsupported or absent documentation review schema.')
    if review.get('reviewed_base') != base_sha:
        raise IntegrityError('Documentation review is bound to a different or unresolved base commit.')
    entries = review.get('documents')
    if not isinstance(entries, list):
        raise IntegrityError('Documentation review needs a documents array.')
    by_path = {}
    for row in entries:
        if not isinstance(row, dict) or not isinstance(row.get('path'), str):
            raise IntegrityError('Malformed documentation review entry.')
        path = row['path']
        if path in by_path or Path(path).is_absolute() or '..' in Path(path).parts:
            raise IntegrityError('Duplicate or unsafe documentation review path.')
        if row.get('status') not in ('updated', 'not_applicable'):
            raise IntegrityError('Document remains unreviewed: ' + path)
        reason = row.get('reason')
        if not isinstance(reason, str) or len(reason.strip()) < 20:
            raise IntegrityError('Document review requires a concrete explanation: ' + path)
        if row['status'] == 'updated' and path not in changed:
            raise IntegrityError('Document claims updated but has no diff: ' + path)
        by_path[path] = row
    required = set(REQUIRED_DOCS)
    required.update(p for p in changed if p.startswith('docs/') and p.endswith('.md'))
    missing = sorted(required - by_path.keys())
    if missing:
        raise IntegrityError('Missing document reviews: ' + ', '.join(missing))
    product_changed = any(p.startswith(('Sources/', 'script/', 'ForgeConductor.xcodeproj/',
                                       'ForgeConductor.xcworkspace/')) or p == 'Package.swift'
                          for p in changed)
    if product_changed and by_path['CHANGELOG.md']['status'] != 'updated':
        raise IntegrityError('Product/build changes require an actual CHANGELOG update.')
    if release:
        for path in REQUIRED_DOCS:
            if by_path[path]['status'] != 'updated':
                raise IntegrityError('Final release range must update ' + path)
    return sorted(by_path)

def docs_command(repo: Repository, args: argparse.Namespace) -> Report:
    base = repo.resolve_commit(args.base)
    diff_args = ['diff', '--name-only', '-z']
    if args.index:
        diff_args += ['--cached', base, '--']
    else:
        diff_args += [base, 'HEAD', '--']
    changed = set(filter(None, repo.git(*diff_args).split('\0')))
    reviewed = validate_doc_review(changed, read_json(Path(args.review)), base, args.release)
    for path in reviewed:
        # Existence must come from the same snapshot as the diff. A deleted
        # staged/committed document can still have an untracked worktree copy.
        literal = ':(literal)' + path
        if args.index:
            listing = repo.git('ls-files', '--stage', '-z', '--', literal)
        else:
            listing = repo.git('ls-tree', '-z', 'HEAD', '--', literal)
        entries = list(filter(None, listing.split('\0')))
        valid = False
        if len(entries) == 1:
            metadata, separator, listed_path = entries[0].partition('\t')
            fields = metadata.split()
            if separator and listed_path == path and len(fields) == 3:
                valid = fields[0] in ('100644', '100755') and (
                    fields[2] == '0' if args.index else fields[1] == 'blob')
        if not valid:
            raise IntegrityError('Reviewed document must be a regular file in the selected '
                                 + ('index' if args.index else 'HEAD') + ' snapshot: ' + path)
    return Report('docs', {'base':base, 'snapshot':'index' if args.index else 'HEAD',
                           'release_range':args.release, 'reviewed_documents':reviewed,
                           'changed_file_count':len(changed)},
                  ['Coverage and actual diffs checked; human/agent content review still must verify accuracy.'])

def normalize_remote(url: str) -> str:
    if re.fullmatch(r'git@github\.com:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', url):
        path = url.split(':', 1)[1]
    else:
        parts = urlsplit(url)
        if parts.scheme not in ('https', 'ssh') or parts.hostname != 'github.com':
            raise IntegrityError('Remote must be the expected GitHub repository, not another host or local path.')
        if parts.password or parts.query or parts.fragment or parts.port not in (None, 22, 443):
            raise IntegrityError('Credential-bearing or unsupported remote URL; inspect locally.')
        if (parts.scheme == 'https' and parts.username) or (parts.scheme == 'ssh' and parts.username != 'git'):
            raise IntegrityError('Use a non-credential-bearing GitHub HTTPS URL or normal git SSH URL.')
        path = parts.path.lstrip('/')
    if path.endswith('.git'):
        path = path[:-4]
    if path.lower() != EXPECTED_REPOSITORY.lower():
        raise IntegrityError('Remote points to a different repository.')
    return path

def parse_remote_head(text: str, branch: str) -> str:
    lines = [line.split() for line in text.splitlines() if line.strip()]
    expected_ref = 'refs/heads/' + branch
    if len(lines) != 1 or len(lines[0]) != 2 or lines[0][1] != expected_ref:
        raise IntegrityError('Live remote branch is absent or ambiguous.')
    sha = lines[0][0]
    if not re.fullmatch(r'[0-9a-f]{40,64}', sha):
        raise IntegrityError('Invalid live remote commit identity.')
    return sha

def verify_sync_snapshot(branch: str, expected_branch: str, status: str,
                         local: str, fetch_head: str, push_head: str,
                         expected_head: Optional[str] = None) -> None:
    if branch != expected_branch:
        raise IntegrityError('Checkout is not on the declared delivery branch (or is detached).')
    if status.strip():
        raise IntegrityError('Checkout is dirty; preserve and reconcile changes before claiming synchronization.')
    if local != fetch_head or local != push_head:
        raise IntegrityError('Local HEAD differs from live fetch or push branch.')
    if expected_head is not None and local != expected_head:
        raise IntegrityError('Checkout differs from the intended delivered commit.')

def sync_command(repo: Repository, args: argparse.Namespace) -> Report:
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', args.remote):
        raise ExecutionError('Invalid remote name.')
    repo.git('check-ref-format', '--branch', args.branch)
    branch = repo.git('rev-parse', '--abbrev-ref', 'HEAD').strip()
    status = repo.git('status', '--porcelain=v1', '--untracked-files=all')
    if status.strip():
        raise IntegrityError('Checkout is dirty; no source-control changes were made by this checker.')
    fetch_urls = repo.git('remote', 'get-url', '--all', args.remote).splitlines()
    push_urls = repo.git('remote', 'get-url', '--push', '--all', args.remote).splitlines()
    if len(fetch_urls) != 1 or len(push_urls) != 1:
        raise IntegrityError('Multiple or absent fetch/push destinations require explicit reconciliation.')
    for url in fetch_urls + push_urls:
        normalize_remote(url)
    local = repo.resolve_commit('HEAD')
    heads = []
    for url in (fetch_urls[0], push_urls[0]):
        text = repo.git('ls-remote', '--exit-code', url, 'refs/heads/' + args.branch)
        heads.append(parse_remote_head(text, args.branch))
    expected = repo.resolve_commit(args.expected_head) if args.expected_head else None
    verify_sync_snapshot(branch, args.branch, status, local, heads[0], heads[1], expected)
    # Recheck after the two remote reads so a concurrent local edit cannot be ignored.
    verify_sync_snapshot(repo.git('rev-parse', '--abbrev-ref', 'HEAD').strip(), args.branch,
                         repo.git('status', '--porcelain=v1', '--untracked-files=all'),
                         repo.resolve_commit('HEAD'), heads[0], heads[1], expected)
    return Report('sync', {'checkout':str(repo.root), 'branch':branch, 'head':local,
                           'live_fetch_head':heads[0], 'live_push_head':heads[1],
                           'repository':EXPECTED_REPOSITORY, 'clean':True},
                  ['Snapshot only. Check canonical checkout separately; unmerged branch parity is not integration.'])

class XcodeProject:
    def __init__(self, document: Any, root: Path):
        if not isinstance(document, dict) or not isinstance(document.get('objects'), dict):
            raise ExecutionError('Invalid parsed Xcode project.')
        self.objects = document['objects']
        self.root = root.resolve()
        self.parents: Dict[str, str] = {}
        for object_id, obj in self.objects.items():
            if not isinstance(obj, dict):
                raise ExecutionError('Malformed Xcode object.')
            if obj.get('isa', '').startswith('PBXFileSystemSynchronized'):
                raise ExecutionError('Synchronized groups require a tested guard adaptation; not silently supported.')
            for child in obj.get('children', []):
                if child in self.parents and self.parents[child] != object_id:
                    raise ExecutionError('Ambiguous Xcode group parent.')
                self.parents[child] = object_id

    def object_path(self, object_id: str, visiting: Optional[Set[str]] = None) -> Optional[Path]:
        visiting = set() if visiting is None else set(visiting)
        if object_id in visiting:
            raise ExecutionError('Cycle in Xcode group graph.')
        visiting.add(object_id)
        obj = self.objects.get(object_id)
        if obj is None:
            raise IntegrityError('Dangling Xcode file/group reference.')
        tree = obj.get('sourceTree', '<group>')
        component = obj.get('path', '')
        if '$(' in component:
            raise ExecutionError('Generated source path needs explicit native build validation: ' + component)
        if tree == 'SOURCE_ROOT':
            base = self.root
        elif tree == '<absolute>':
            base = Path('/')
        elif tree == '<group>':
            parent = self.parents.get(object_id)
            base = self.object_path(parent, visiting) if parent else self.root
            if base is None:
                return None
        else:
            return None  # SDK and build products are not source file paths.
        return (base / component).resolve()

    def source_memberships(self) -> Dict[str, Set[str]]:
        result: Dict[str, Set[str]] = {}
        for obj in self.objects.values():
            if obj.get('isa') != 'PBXNativeTarget':
                continue
            name = obj.get('name')
            if not isinstance(name, str) or name in result:
                raise ExecutionError('Missing or duplicate native target name.')
            paths: Set[str] = set()
            for phase_id in obj.get('buildPhases', []):
                phase = self.objects.get(phase_id)
                if phase is None:
                    raise IntegrityError('Dangling Xcode build-phase reference.')
                if phase.get('isa') != 'PBXSourcesBuildPhase':
                    continue
                for build_id in phase.get('files', []):
                    record = self.objects.get(build_id, {})
                    file_ref = record.get('fileRef')
                    if not file_ref:
                        raise ExecutionError('Source build record has no supported file reference.')
                    path = self.object_path(file_ref)
                    if path is None:
                        raise ExecutionError('Unresolved compiled source reference.')
                    if not path.is_file():
                        raise IntegrityError('Xcode compiles a missing file: ' + str(path))
                    try:
                        relative = path.relative_to(self.root).as_posix()
                    except ValueError as exc:
                        raise IntegrityError('Xcode compiled source is outside the repository.') from exc
                    if relative in paths:
                        raise IntegrityError('Duplicate source membership in target ' + name + ': ' + relative)
                    paths.add(relative)
            result[name] = paths
        return result

def check_memberships(tracked: Iterable[str], memberships: Dict[str, Set[str]]) -> tuple:
    checked = 0
    review_items = []
    all_compiled: Set[str] = set().union(*memberships.values()) if memberships else set()
    for path in tracked:
        parts = Path(path).parts
        if not path.endswith('.swift'):
            continue
        if len(parts) >= 3 and parts[0] == 'Sources':
            target = SOURCE_TARGETS.get(parts[1])
            if target is None:
                raise ExecutionError('New production source module requires explicit target mapping: ' + parts[1])
            if path not in memberships.get(target, set()):
                raise IntegrityError('Tracked Swift source is absent from intended Xcode target '
                                     + target + ': ' + path)
            checked += 1
        elif parts and parts[0] == 'Tests' and path not in all_compiled:
            review_items.append(path)
    if checked == 0:
        raise IntegrityError('No tracked production Swift sources were checked.')
    return checked, sorted(review_items)

def xcode_command(repo: Repository, args: argparse.Namespace) -> Report:
    if sys.platform != 'darwin':
        raise ExecutionError('NOT RUN: native plutil Xcode parsing requires macOS.')
    parsed = execute(['/usr/bin/plutil', '-convert', 'json', '-o', '-', str(repo.root / PROJECT)], repo.root)
    try:
        document = json.loads(parsed)
    except json.JSONDecodeError as exc:
        raise ExecutionError('Native Xcode project conversion did not produce JSON.') from exc
    memberships = XcodeProject(document, repo.root).source_memberships()
    tracked = filter(None, repo.git('ls-files', '-z', '--', 'Sources', 'Tests').split('\0'))
    checked, review_items = check_memberships(tracked, memberships)
    return Report('xcode', {'production_swift_files_checked':checked,
                            'native_targets':sorted(memberships),
                            'test_files_requiring_membership_disposition':review_items},
                  ['Any test-source omissions require documented disposition and actual coverage. '
                   'Resource phases, schemes, linking, signing and native execution are separate checks.'])

def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    version = sub.add_parser('versions')
    version.add_argument('--repo', type=Path, required=True)
    version.add_argument('--app')
    version.add_argument('--settings', action='append', default=[])
    docs = sub.add_parser('docs')
    docs.add_argument('--repo', type=Path, required=True)
    docs.add_argument('--base', required=True)
    docs.add_argument('--review', required=True)
    docs.add_argument('--index', action='store_true')
    docs.add_argument('--release', action='store_true')
    sync = sub.add_parser('sync')
    sync.add_argument('--repo', type=Path, required=True)
    sync.add_argument('--branch', required=True)
    sync.add_argument('--remote', default='origin')
    sync.add_argument('--expected-head')
    xcode = sub.add_parser('xcode')
    xcode.add_argument('--repo', type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        repo = Repository(args.repo)
        command = {'versions':versions_command, 'docs':docs_command,
                   'sync':sync_command, 'xcode':xcode_command}[args.command]
        report = command(repo, args)
        print(json.dumps(report.as_dict(), indent=2))
        return 0
    except IntegrityError as exc:
        print(json.dumps({'check':args.command, 'status':'failed', 'message':str(exc)}, indent=2))
        return 1
    except (ExecutionError, OSError, UnicodeError, ValueError) as exc:
        print(json.dumps({'check':args.command, 'status':'not_completed', 'message':str(exc)}, indent=2))
        return 2

if __name__ == '__main__':
    sys.exit(main())
