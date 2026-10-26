"""Prepare one authorized fork source pair, preserving every existing remote ref.

Run only after Ash completion is committed. Drafting this utility does not mutate refs.
"""
import argparse,hashlib,json,os,pathlib,re,shutil,subprocess
parser=argparse.ArgumentParser();parser.add_argument('case');parser.add_argument('--ash-completion-commit',required=True);parser.add_argument('--dry-run',action='store_true');args=parser.parse_args()
assert re.fullmatch(r'[0-9a-f]{40}',args.ash_completion_commit)
root=pathlib.Path.cwd();work=root/'.local/fork-migration'
def call(argv,**kw):return subprocess.check_output(argv,text=True,**kw).strip()
def save(path,value):
    path.parent.mkdir(parents=True,exist_ok=True);path.write_text(json.dumps(value,indent=2)+'\n')
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
# An actual committed successful pair and restoration are prerequisites to migration.
completion=json.loads(call(['git','show',args.ash_completion_commit+':verification/case-curation-2026-10-20/ash-pr-3031/astra-results.json']))
# Ash completed under the user's recorded single-run exception (case-curation-loop.md).
assert completion['two_fresh_blind_runs'] or (completion['single_fresh_blind_run'] and completion['user_authorized_single_run_exception'] and len(completion['runs'])==1)
call(['git','cat-file','-e',args.ash_completion_commit+':verification/case-curation-2026-10-20/ash-pr-3031/restoration.json'])
row=next(r for r in json.loads((work/'initial-source-audit.json').read_text()) if r['case']==args.case)
repo=work/'forks'/row['fork'].rsplit('/',1)[1]
source=root/'cases_approved'/args.case
if not source.exists():source=root/'cases'/args.case
spec=json.loads((source/'case.json').read_text());old=json.loads((source/'provenance.json').read_text())
assert spec['repository']==row['old_repository']
assert {p.name:sha(p) for p in source.iterdir() if p.is_file()}==row['bundle_hashes'], 'Source bundle changed since audit'
assert all(p.name=='.git' for p in repo.iterdir()), 'Expected dedicated no-checkout audit clone'
def git(*argv,**kw):return call(['git','-C',str(repo),*argv],**kw)
def remote_heads():
    return {line.split()[1].removeprefix('refs/heads/'):line.split()[0] for line in git('ls-remote','--heads','origin').splitlines()}
before=remote_heads();fork_slug=row['fork'].removeprefix('https://github.com/')
record={'case':args.case,'status':'preparing','ash_completion_commit':args.ash_completion_commit,'old_source_pair':old,'remote_heads_before':before,'old_bundle_hashes':{p.name:sha(p) for p in sorted(source.iterdir()) if p.is_file()},'tree_audit':row['prepared_tree_audit'],'operations':[]}
record_path=work/('dry-run-records' if args.dry_run else 'preparation-records')/f'{args.case}.json'
if args.dry_run and record_path.exists():record_path.unlink()
if record_path.exists():raise RuntimeError('Existing preparation record; inspect and resume explicitly')
save(record_path,record)
trees=row['prepared_tree_audit'];overlay=(source/'environment.patch').exists()
for role in ['broken','fixed']:
    assert git('rev-parse',old[role+'_revision']+'^{tree}')==old[role+'_tree']
# Reinspect every current head, including branches added since the first audit.
for commit in set(before.values()):
    present=subprocess.run(['git','-C',str(repo),'cat-file','-e',commit+'^{commit}'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0
    if not present:git('fetch','--no-tags','origin',commit)
branch_trees={branch:git('rev-parse',commit+'^{tree}') for branch,commit in before.items()}
default_branch=call(['gh','api','repos/'+fork_slug,'--jq','.default_branch'])
record['current_branch_trees']=branch_trees
record['default_branch']=default_branch
save(record_path,record)
def ancestor(first,last):
    return subprocess.run(['git','-C',str(repo),'merge-base','--is-ancestor',first,last],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0
def choose_existing(tree,base,preferred):
    names=[name for name,commit in before.items() if name!=default_branch and branch_trees[name]==tree and ancestor(base,commit)]
    return next((name for name in preferred if name in names), sorted(names)[0] if names else None)
def unused_name(preferred):
    name=preferred;number=2
    while name in before or git('for-each-ref','--format=%(objectname)',f'refs/heads/{name}'):
        name=preferred+'-'+str(number);number+=1
    return name
baseline=choose_existing(trees['broken_tree'],old['broken_revision'],row['exact_starting_revision_branches']+[f'codex/{args.case}-benchmark'])
if baseline:
    broken=before[baseline]
else:
    baseline=unused_name(f'codex/{args.case}-benchmark')
    broken=old['broken_revision'] if not overlay else git('commit-tree',trees['broken_tree'],'-p',old['broken_revision'],'-m',f'Prepare {args.case} benchmark baseline\n\nPreserve the recorded environment overlay in source so benchmark clones need no source patch.')
reference=choose_existing(trees['fixed_tree'],broken,[f'codex/{args.case}-reference'])
if reference:
    fixed=before[reference]
else:
    reference=unused_name(f'codex/{args.case}-reference')
    if not overlay and ancestor(broken,old['fixed_revision']):fixed=old['fixed_revision']
    else:
        author={'name':git('show','-s','--format=%an',old['fixed_revision']),'email':git('show','-s','--format=%ae',old['fixed_revision']),'date':git('show','-s','--format=%aI',old['fixed_revision'])}
        environment=os.environ.copy();environment.update(GIT_AUTHOR_NAME=author['name'],GIT_AUTHOR_EMAIL=author['email'],GIT_AUTHOR_DATE=author['date'])
        message=git('show','-s','--format=%B',old['fixed_revision'])+'\n\n(cherry picked from commit '+old['fixed_revision']+')\n'
        fixed=git('commit-tree',trees['fixed_tree'],'-p',broken,'-m',message,env=environment)
assert git('rev-parse',broken+'^{tree}')==trees['broken_tree']
assert git('rev-parse',fixed+'^{tree}')==trees['fixed_tree']
assert git('diff','--binary',old['broken_revision'],old['fixed_revision'])==git('diff','--binary',broken,fixed), 'Prepared repair differs from original upstream diff'
record.update(preparation_branch=baseline,reference_branch=reference,broken_revision=broken,fixed_revision=fixed)
save(record_path,record)
if args.dry_run:
    # Report the intended refs and PR; nothing is pushed or opened.
    existing=json.loads(call(['gh','pr','list','--repo',fork_slug,'--state','all','--base',baseline,'--head',reference,'--json','number,url']))
    plan=[{'branch':branch,'action':'reuse' if branch in before else 'create','commit':commit,'new_commit':commit not in (old['broken_revision'],old['fixed_revision'])} for branch,commit in [(baseline,broken),(reference,fixed)]]
    print(json.dumps({'case':args.case,'fork':fork_slug,'overlay':overlay,'refs':plan,'pull_request':existing[0]['url'] if existing else 'create draft'}))
    raise SystemExit(0)
new_refs=[]
for branch,commit in [(baseline,broken),(reference,fixed)]:
    if branch in before:
        assert before[branch]==commit
        record['operations'].append({'branch':branch,'action':'reused_existing_verified_ref','commit':commit})
    else:
        git('update-ref',f'refs/heads/{branch}',commit,'0'*40)
        new_refs.append((branch,commit))
        record['operations'].append({'branch':branch,'action':'prepared_new_ref','commit':commit})
save(record_path,record)
if new_refs:
    # Empty expected values enforce server-side absence; no existing ref can move.
    leases=[f'--force-with-lease=refs/heads/{branch}:' for branch,_ in new_refs]
    refspecs=[f'refs/heads/{branch}:refs/heads/{branch}' for branch,_ in new_refs]
    git('push','--atomic',*leases,'git@github.com:'+fork_slug+'.git',*refspecs)
    for operation in record['operations']:
        if operation['action']=='prepared_new_ref':operation['action']='created_new_ref_with_absence_lease'
    save(record_path,record)
after=remote_heads()
assert all(after.get(name)==commit for name,commit in before.items())
assert after[baseline]==broken and after[reference]==fixed
record['remote_heads_after']=after;record['all_existing_remote_refs_preserved']=True;save(record_path,record)
existing=json.loads(call(['gh','pr','list','--repo',fork_slug,'--state','all','--base',baseline,'--head',reference,'--json','number,url']))
if existing:
    assert len(existing)==1;pr=existing[0]['url']
else:
    body=work/'pr-bodies'/f'{args.case}.md';body.parent.mkdir(parents=True,exist_ok=True)
    body.write_text(f'''Prepared source pair for benchmark case `{args.case}`, based on {old['pull_request']}.

The baseline `{baseline}` pins `{broken}` (tree `{trees['broken_tree']}`). Its preparation is the existing benchmark environment overlay preserved unchanged in source; cases without an overlay reuse their existing exact baseline branch.

The reference `{reference}` pins `{fixed}` (tree `{trees['fixed_tree']}`). The retained upstream implementation, exact upstream tests and documentation reconstruct that tree from the prepared baseline. Original repair authorship is retained. Hidden benchmark checks are not added to either branch.

This draft records the source pair used for reproducible benchmark provenance. It is not intended for merging into the fork's default branch.
''')
    pr=call(['gh','pr','create','--repo',fork_slug,'--draft','--base',baseline,'--head',reference,'--title',f'Benchmark source pair: {args.case}','--body-file',str(body)])
pull=json.loads(call(['gh','api',f'repos/{fork_slug}/pulls/{pr.rsplit("/",1)[1]}']))
assert pull['base']['sha']==broken and pull['head']['sha']==fixed
record['pull_request']=pr;record['status']='source_pair_verified';save(record_path,record)
draft=work/'drafts'/args.case
if draft.exists():raise RuntimeError('Draft collision')
shutil.copytree(source,draft)
for name in ['admission.json','environment.patch']:
    if (draft/name).exists():(draft/name).unlink()
spec['repository']={'url':row['fork']+'.git','revision':broken}
spec['source_inspiration']['note']='Original upstream source pair retained in provenance.json; benchmark execution pins the prepared fork branch.'
provenance={'repository':row['fork'],'pull_request':pr,'broken_revision':broken,'fixed_revision':fixed,'broken_tree':trees['broken_tree'],'fixed_tree':trees['fixed_tree'],'pair_selection':'Prepared fork baseline with the original accepted implementation, exact upstream tests and documentation; source reconstruction verified.','preparation_branch':baseline,'reference_branch':reference,'upstream':old,'preparation':{'source_revision':old['broken_revision'],'source_environment_patch_sha256':sha(source/'environment.patch') if overlay else None,'files':trees['preparation_paths']}}
save(draft/'case.json',spec);save(draft/'provenance.json',provenance)
for name in record['old_bundle_hashes']:
    if name not in ['case.json','provenance.json','admission.json','environment.patch']:assert sha(draft/name)==record['old_bundle_hashes'][name]
record['draft_hashes']={p.name:sha(p) for p in sorted(draft.iterdir()) if p.is_file()};record['status']='draft_ready_for_independent_review';save(record_path,record)
print(json.dumps({'case':args.case,'draft':str(draft),'baseline':baseline,'reference':reference,'pull_request':pr,'status':record['status']}))
