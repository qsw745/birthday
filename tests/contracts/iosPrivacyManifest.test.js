const assert = require('node:assert/strict')
const { execFileSync } = require('node:child_process')
const { readFileSync } = require('node:fs')
const path = require('node:path')
const test = require('node:test')

const repositoryRoot = path.resolve(__dirname, '../..')
const manifestPath = path.join(
  repositoryRoot,
  'ios/BirthdayMobile/PrivacyInfo.xcprivacy',
)

function readManifest() {
  return JSON.parse(execFileSync(
    '/usr/bin/plutil',
    ['-convert', 'json', '-o', '-', manifestPath],
    { encoding: 'utf8' },
  ))
}

test('privacy manifest declares no developer collection, tracking, or undeclared required-reason API', () => {
  const manifest = readManifest()

  assert.equal(manifest.NSPrivacyTracking, false)
  assert.deepEqual(manifest.NSPrivacyTrackingDomains, [])
  assert.deepEqual(manifest.NSPrivacyAccessedAPITypes, [
    {
      NSPrivacyAccessedAPIType: 'NSPrivacyAccessedAPICategoryUserDefaults',
      NSPrivacyAccessedAPITypeReasons: ['CA92.1'],
    },
  ])

  assert.deepEqual(manifest.NSPrivacyCollectedDataTypes, [])
})

test('Apple release sources contain no advertising, analytics, or tracking SDK', () => {
  const project = readFileSync(path.join(repositoryRoot, 'ios/project.yml'), 'utf8')

  assert.doesNotMatch(
    project,
    /GoogleMobileAds|FirebaseAnalytics|Amplitude|Mixpanel|Appsflyer|Adjust|FacebookSDK|AdSupport|AppTrackingTransparency/i,
  )
  assert.doesNotMatch(project, /^\s+url:\s*https?:/m)
})

test('XcodeGen classifies the privacy manifest as an application resource', () => {
  const project = readFileSync(
    path.join(repositoryRoot, 'ios/project.yml'),
    'utf8',
  )
  assert.match(
    project,
    /- path: BirthdayMobile\/PrivacyInfo\.xcprivacy\n\s+buildPhase: resources/,
  )
})
