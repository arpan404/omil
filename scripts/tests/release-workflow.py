import pathlib, tempfile, subprocess, os, shutil, json
source=pathlib.Path(__file__).resolve().parents[2]
fixture=b'fixture-update-archive'
swift='''import Foundation
import CryptoKit
let key = Curve25519.Signing.PrivateKey()
print(key.publicKey.rawRepresentation.base64EncodedString())
print(try key.signature(for: Data("fixture-update-archive".utf8)).base64EncodedString())
'''
with tempfile.TemporaryDirectory(prefix='omil-release-tests-') as tmp:
 root=pathlib.Path(tmp)
 signing=root/'key.swift'; signing.write_text(swift)
 public, signature=subprocess.check_output(['xcrun','swift',str(signing)],text=True).splitlines()
 api_key=root/'AuthKey_FIXTUREKEY.p8'
 subprocess.run(['openssl','genpkey','-algorithm','EC','-pkeyopt','ec_paramgen_curve:P-256','-out',str(api_key)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 api_env=os.environ.copy()
 api_env.update(APPLE_API_KEY_PATH=str(api_key), APPLE_API_KEY_ID='FIXTUREKEY1', APPLE_API_ISSUER_ID='11111111-2222-3333-4444-555555555555')
 # An exported value must win over .env; even obsolete password variables cannot trigger fallback.
 (root/'.env').write_text('APPLE_API_KEY_ID=WRONGKEYID1\nAPPLE_APP_SPECIFIC_PASSWORD=fixture-obsolete\n')
 auth_check='source "$1"; configure_apple_api_auth; [[ ${notary_auth[0]} == --key && ${notary_auth[3]} == FIXTUREKEY1 && ${notary_auth[4]} == --issuer && ${provisioning_auth[0]} == -authenticationKeyPath ]]'
 subprocess.run(['bash','-euc',auth_check,'api-test',str(source/'scripts/release-env.sh')],cwd=root,env=api_env,check=True)
 print('API authentication arguments and shell override: passed')
 for scenario,override in [('missing issuer',{'APPLE_API_ISSUER_ID':''}),('missing key file',{'APPLE_API_KEY_PATH':str(root/'missing.p8')})]:
  bad_env=api_env.copy();bad_env.update(override)
  check=subprocess.run(['bash','-euc','source "$1"; configure_apple_api_auth','api-test',str(source/'scripts/release-env.sh')],cwd=root,env=bad_env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
  assert check.returncode!=0,scenario+' unexpectedly accepted'
  print('API '+scenario+' rejection: passed')
 for scenario in ['accepted','mac-failure','bad-signature','prerelease']:
  case=root/scenario; (case/'scripts').mkdir(parents=True); (case/'bin').mkdir()
  for name in ['release.sh','release-env.sh','changelog.py','verify-appcast.swift']:
   shutil.copy2(source/'scripts'/name,case/'scripts'/name)
  mac='''#!/bin/bash
set -eu
[[ ${1:-} != --check ]] || exit 0
[[ $MOCK_SCENARIO != mac-failure ]] || exit 23
mkdir -p "$OMIL_DISTRIBUTION_DIR/Omil.app/Contents"
printf fixture-update-archive > "$OMIL_DISTRIBUTION_DIR/Omil-0.2.0-2-macos-arm64.zip"
/usr/bin/python3 - "$OMIL_DISTRIBUTION_DIR/Omil.app/Contents/Info.plist" <<'PLIST'
import os,sys,plistlib
with open(sys.argv[1],'wb') as f: plistlib.dump(dict(SUFeedURL='https://github.com/fixture/omil/releases/latest/download/appcast.xml', SUPublicEDKey=os.environ['SPARKLE_PUBLIC_KEY']),f)
PLIST
'''
  # Any iOS invocation, including a preflight, must fail this Mac release test.
  ios='''#!/bin/bash
echo 'GitHub release unexpectedly invoked the iOS build' >&2
exit 97
'''
  for name,data in [('distribute-mac.sh',mac),('distribute-ios.sh',ios)]:
   p=case/'scripts'/name; p.write_text(data); p.chmod(0o755)
  gh='''#!/bin/bash
set -eu
case "$1 $2" in
 'auth status') exit 0 ;;
 'release list') echo '[]' ;;
 'release create'|'release edit') printf '%s\\n' "$*" >> "$MOCK_TRACE" ;;
 *) exit 12 ;;
esac
'''
  p=case/'bin/gh';p.write_text(gh);p.chmod(0o755)
  tools=case/'.build/tools/bin'; tools.mkdir(parents=True)
  generator='''#!/usr/bin/python3
import sys,os,pathlib,xml.etree.ElementTree as ET
args=sys.argv[1:]; sys.stdin.read()
ns='{http://www.andymatuschak.org/xml-namespaces/sparkle}'
root=ET.Element('rss'); channel=ET.SubElement(root,'channel'); item=ET.SubElement(channel,'item')
ET.SubElement(item,ns+'version').text='2'
sig=os.environ['MOCK_SIGNATURE']
if os.environ['MOCK_SCENARIO']=='bad-signature': sig='A'*86+'=='
ET.SubElement(item,'enclosure',{'url':'https://github.com/fixture/omil/releases/download/v0.2.0/Omil-0.2.0-2-macos-arm64.zip', ns+'edSignature':sig})
ET.ElementTree(root).write(args[args.index('-o')+1])
'''
  p=tools/'generate_appcast';p.write_text(generator);p.chmod(0o755)
  (case/'VERSION').write_text('0.2.0\n')
  (case/'project.yml').write_text('MARKETING_VERSION: "0.2.0"\nCURRENT_PROJECT_VERSION: "2"\n')
  (case/'.gitignore').write_text('.env\n.build/\n')
  (case/'.env').write_text('GH_REPO=fixture/omil\nAPPLE_TEAM_ID=5J88TLUP2J\nSPARKLE_PRIVATE_KEY=fixture-secret\nSPARKLE_PUBLIC_KEY='+public+'\nOMIL_RELEASE_CACHE_DIR="'+str(tools.parent)+'"\n')
  def git(*args): return subprocess.check_output(['git','-C',str(case),*args],stderr=subprocess.DEVNULL,text=True)
  git('init','-b','main'); git('config','user.name','Fixture'); git('config','user.email','fixture@example.test')
  git('add','.'); git('commit','-m','feat: add fixture release')
  bare=root/(scenario+'.git'); subprocess.run(['git','init','--bare',str(bare)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True)
  git('remote','add','origin',str(bare));git('push','-u','origin','main')
  env=os.environ.copy()
  for key in ['GH_REPO','SPARKLE_PRIVATE_KEY','SPARKLE_PUBLIC_KEY','OMIL_RELEASE_CACHE_DIR','OMIL_DISTRIBUTION_DIR','IOS_EXPORT_METHOD','APPLE_TEAM_ID']: env.pop(key,None)
  env.update(PATH=str(case/'bin')+':'+env['PATH'], MOCK_SCENARIO=scenario,MOCK_SIGNATURE=signature,MOCK_TRACE=str(case/'.build/gh-trace'))
  args=[str(case/'scripts/release.sh'),'publish']
  if scenario=='prerelease':args.append('--prerelease')
  result=subprocess.run(args,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
  trace=case/'.build/gh-trace'
  if scenario in ['accepted','prerelease']:
   assert result.returncode==0,result.stdout
   actions=trace.read_text().splitlines()
   assert len(actions)==2 and '--draft' in actions[0], actions
   assert '--latest=false' in actions[1] if scenario=='prerelease' else '--latest=true' in actions[1]
   artifacts=list((case/'.build/distribution').glob('GitHub-release.*/artifacts'))[0]
   assert not list(artifacts.glob('*.ipa')) and list(artifacts.glob('*.zip'))
   assert 'iOS installation' not in (artifacts/'RELEASE_NOTES.md').read_text()
   assert 'feat: add fixture release' in (artifacts/'CHANGELOG.md').read_text()
   checks=(artifacts/'SHA256SUMS').read_text()
   assert '.ipa' not in checks and '.zip' in checks and 'appcast.xml' in checks
  else:
   assert result.returncode!=0,result.stdout
   assert not trace.exists(),'Failure published a GitHub release'
  print(scenario+': passed')
