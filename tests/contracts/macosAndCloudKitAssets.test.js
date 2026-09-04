const assert = require('node:assert/strict')
const { execFileSync } = require('node:child_process')
const { readFileSync } = require('node:fs')
const path = require('node:path')
const test = require('node:test')

const repositoryRoot = path.resolve(__dirname, '../..')
const iosRoot = path.join(repositoryRoot, 'ios')
const projectPath = path.join(iosRoot, 'BirthdayMobile.xcodeproj')

function run(executable, args, options = {}) {
  return execFileSync(executable, args, {
    cwd: iosRoot,
    encoding: 'utf8',
    ...options,
  })
}

function generatedProject() {
  run('/opt/homebrew/bin/xcodegen', ['generate'])
  return JSON.parse(run('/usr/bin/xcodebuild', [
    '-project', projectPath,
    '-list',
    '-json',
  ]))
}

function buildSettings(scheme) {
  const output = run('/usr/bin/xcodebuild', [
    '-project', projectPath,
    '-scheme', scheme,
    '-configuration', 'Release',
    '-showBuildSettings',
  ])
  return Object.fromEntries(
    output
      .split('\n')
      .map((line) => line.match(/^\s{4}([A-Z0-9_]+) = (.*)$/))
      .filter(Boolean)
      .map((match) => [match[1], match[2]]),
  )
}

function readPlist(relativePath) {
  return JSON.parse(run('/usr/bin/plutil', [
    '-convert', 'json',
    '-o', '-',
    path.join(iosRoot, relativePath),
  ]))
}

test('generated project exposes separate iPhone and Mac Catalyst products', () => {
  const project = generatedProject()
  const schemes = project.project.schemes

  assert.ok(schemes.includes('BirthdayMobile'))
  assert.ok(schemes.includes('BirthdayMac'))

  const phone = buildSettings('BirthdayMobile')
  const mac = buildSettings('BirthdayMac')

  assert.equal(phone.PRODUCT_BUNDLE_IDENTIFIER, 'top.qisw.birthday')
  assert.equal(mac.PRODUCT_BUNDLE_IDENTIFIER, 'top.qisw.birthday')
  assert.equal(phone.ICLOUD_CONTAINER_IDENTIFIER, 'iCloud.top.qisw.birthday')
  assert.equal(mac.ICLOUD_CONTAINER_IDENTIFIER, 'iCloud.top.qisw.birthday')
  assert.equal(phone.SUPPORTS_MACCATALYST, 'NO')
  assert.equal(phone.SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD, 'NO')
  assert.equal(mac.SUPPORTS_MACCATALYST, 'YES')
  assert.equal(mac.DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER, 'NO')
  assert.equal(mac.SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD, 'NO')
  assert.equal(phone.CODE_SIGN_ENTITLEMENTS, 'BirthdayMobile/Config/BirthdayMobile.entitlements')
  assert.equal(mac.CODE_SIGN_ENTITLEMENTS, 'BirthdayMobile/Config/BirthdayMac.entitlements')
  assert.equal(phone.INFOPLIST_FILE, 'BirthdayMobile/Info.plist')
  assert.equal(mac.INFOPLIST_FILE, 'BirthdayMobile/MacInfo.plist')
})

test('both products carry only the planned private CloudKit capabilities', () => {
  const expectedCloudCapabilities = {
    'com.apple.developer.icloud-container-identifiers': ['$(ICLOUD_CONTAINER_IDENTIFIER)'],
    'com.apple.developer.icloud-services': ['CloudKit'],
    'com.apple.developer.ubiquity-kvstore-identifier':
      '$(TeamIdentifierPrefix)top.qisw.birthday',
  }
  const phone = readPlist('BirthdayMobile/Config/BirthdayMobile.entitlements')
  const mac = readPlist('BirthdayMobile/Config/BirthdayMac.entitlements')

  assert.deepEqual(phone, expectedCloudCapabilities)
  assert.deepEqual(mac, {
    ...expectedCloudCapabilities,
    'com.apple.security.app-sandbox': true,
    'com.apple.security.network.client': true,
  })
})

test('release receives CloudKit changes without restoring the legacy server transport', () => {
  const info = readPlist('BirthdayMobile/Info.plist')
  const macInfo = readPlist('BirthdayMobile/MacInfo.plist')
  const releaseConfiguration = readFileSync(
    path.join(iosRoot, 'BirthdayMobile/Config/Release.xcconfig'),
    'utf8',
  )

  assert.deepEqual(info.UIBackgroundModes, ['remote-notification'])
  assert.deepEqual(macInfo.UIBackgroundModes, ['remote-notification'])
  assert.match(releaseConfiguration, /^BIRTHDAY_API_BASE_URL\s*=\s*$/m)
  assert.doesNotMatch(releaseConfiguration, /https?:/)
})
