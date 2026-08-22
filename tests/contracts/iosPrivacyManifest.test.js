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

test('iOS privacy manifest declares tracking, collected data, and required-reason APIs', () => {
  const manifest = readManifest()

  assert.equal(manifest.NSPrivacyTracking, false)
  assert.deepEqual(manifest.NSPrivacyTrackingDomains, [])
  assert.deepEqual(manifest.NSPrivacyAccessedAPITypes, [
    {
      NSPrivacyAccessedAPIType: 'NSPrivacyAccessedAPICategoryUserDefaults',
      NSPrivacyAccessedAPITypeReasons: ['CA92.1'],
    },
  ])

  const expectedDataTypes = [
    'NSPrivacyCollectedDataTypeDeviceID',
    'NSPrivacyCollectedDataTypeEmailAddress',
    'NSPrivacyCollectedDataTypeEmailsOrTextMessages',
    'NSPrivacyCollectedDataTypeName',
    'NSPrivacyCollectedDataTypeOtherDataTypes',
    'NSPrivacyCollectedDataTypeOtherUserContent',
    'NSPrivacyCollectedDataTypeProductInteraction',
    'NSPrivacyCollectedDataTypeUserID',
  ]
  const declarations = manifest.NSPrivacyCollectedDataTypes
  assert.deepEqual(
    declarations.map((entry) => entry.NSPrivacyCollectedDataType).sort(),
    expectedDataTypes,
  )
  for (const declaration of declarations) {
    assert.equal(declaration.NSPrivacyCollectedDataTypeLinked, true)
    assert.equal(declaration.NSPrivacyCollectedDataTypeTracking, false)
    assert.deepEqual(declaration.NSPrivacyCollectedDataTypePurposes, [
      'NSPrivacyCollectedDataTypePurposeAppFunctionality',
    ])
  }
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
