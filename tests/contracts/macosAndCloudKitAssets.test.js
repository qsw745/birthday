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

function buildSettings(scheme, configuration = 'Release') {
  const output = run('/usr/bin/xcodebuild', [
    '-project', projectPath,
    '-scheme', scheme,
    '-configuration', configuration,
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

function targetBuildSettings(target, configuration) {
  const output = run('/usr/bin/xcodebuild', [
    '-project', projectPath,
    '-target', target,
    '-configuration', configuration,
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

test('production CloudKit smoke configuration is debug-only and selects Production', () => {
  generatedProject()
  const phone = buildSettings('BirthdayMobile', 'CloudKitProductionSmoke')
  const mac = buildSettings('BirthdayMac', 'CloudKitProductionSmoke')
  const phoneUITests = targetBuildSettings(
    'BirthdayMobileUITests',
    'CloudKitProductionSmoke',
  )
  const macUITests = targetBuildSettings(
    'BirthdayMacUITests',
    'CloudKitProductionSmoke',
  )
  const phoneEntitlements = readPlist(phone.CODE_SIGN_ENTITLEMENTS)
  const macEntitlements = readPlist(mac.CODE_SIGN_ENTITLEMENTS)

  assert.equal(phone.SWIFT_ACTIVE_COMPILATION_CONDITIONS.includes('DEBUG'), true)
  assert.equal(mac.SWIFT_ACTIVE_COMPILATION_CONDITIONS.includes('DEBUG'), true)
  assert.equal(phone.PRODUCT_BUNDLE_IDENTIFIER, 'top.qisw.birthday.cloudkitsmoke')
  assert.equal(mac.PRODUCT_BUNDLE_IDENTIFIER, 'top.qisw.birthday.cloudkitsmoke')
  assert.equal(phone.BIRTHDAY_API_BASE_URL ?? '', '')
  assert.equal(mac.BIRTHDAY_API_BASE_URL ?? '', '')
  assert.equal(
    phoneUITests.SWIFT_ACTIVE_COMPILATION_CONDITIONS.includes('CLOUDKIT_PRODUCTION_SMOKE'),
    true,
  )
  assert.equal(
    macUITests.SWIFT_ACTIVE_COMPILATION_CONDITIONS.includes('CLOUDKIT_PRODUCTION_SMOKE'),
    true,
  )
  assert.equal(
    phoneEntitlements['com.apple.developer.icloud-container-environment'],
    'Production',
  )
  assert.equal(
    macEntitlements['com.apple.developer.icloud-container-environment'],
    'Production',
  )
  assert.equal(
    buildSettings('BirthdayMobile').CODE_SIGN_ENTITLEMENTS,
    'BirthdayMobile/Config/BirthdayMobile.entitlements',
  )
  assert.equal(
    buildSettings('BirthdayMac').CODE_SIGN_ENTITLEMENTS,
    'BirthdayMobile/Config/BirthdayMac.entitlements',
  )
})

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

test('release candidates use non-conflicting iPhone and Mac version trains', () => {
  generatedProject()
  const phone = buildSettings('BirthdayMobile')
  const mac = buildSettings('BirthdayMac')

  assert.equal(phone.MARKETING_VERSION, '1.1.1')
  assert.equal(phone.CURRENT_PROJECT_VERSION, '5')
  assert.equal(mac.MARKETING_VERSION, '1.0.1')
  assert.equal(mac.CURRENT_PROJECT_VERSION, '5')
})

test('desktop screenshot fixture is isolated and contains only declared fictional names', () => {
  const source = readFileSync(
    path.join(iosRoot, 'BirthdayMobile/App/BirthdayMobileApp.swift'),
    'utf8',
  )
  const fixture = source.slice(
    source.indexOf('  private func seedDesktopPreview'),
    source.indexOf('\n  }\n}', source.indexOf('  private func seedDesktopPreview')),
  )
  const names = [...fixture.matchAll(/UUID\([^\n]+\)!,\s*"([^"]+)"/g)]
    .map((match) => match[1])

  assert.deepEqual(names, ['清和', '星野', '望舒', '知夏', '小满'])
  assert.doesNotMatch(fixture, /@|\b1[3-9]\d{9}\b/)
  assert.match(fixture, /ModelContext\(container\)/)
})

test('each Apple product excludes the other platform Info plist from copied resources', () => {
  const project = readFileSync(path.join(iosRoot, 'project.yml'), 'utf8')
  const phoneTarget = project.slice(
    project.indexOf('  BirthdayMobile:\n'),
    project.indexOf('  BirthdayMac:\n'),
  )
  const macTarget = project.slice(
    project.indexOf('  BirthdayMac:\n'),
    project.indexOf('  BirthdayMobileUITests:\n'),
  )

  assert.match(phoneTarget, /excludes:[\s\S]*- MacInfo\.plist/)
  assert.match(macTarget, /excludes:[\s\S]*- Info\.plist/)
})

test('both products carry the planned private CloudKit and platform push capabilities', () => {
  const expectedCloudCapabilities = {
    'com.apple.developer.icloud-container-identifiers': ['$(ICLOUD_CONTAINER_IDENTIFIER)'],
    'com.apple.developer.icloud-services': ['CloudKit'],
    'com.apple.developer.ubiquity-kvstore-identifier':
      '$(TeamIdentifierPrefix)top.qisw.birthday',
  }
  const phone = readPlist('BirthdayMobile/Config/BirthdayMobile.entitlements')
  const mac = readPlist('BirthdayMobile/Config/BirthdayMac.entitlements')

  assert.deepEqual(phone, {
    ...expectedCloudCapabilities,
    'aps-environment': 'development',
  })
  assert.deepEqual(mac, {
    ...expectedCloudCapabilities,
    'com.apple.developer.aps-environment': 'development',
    'com.apple.security.app-sandbox': true,
    'com.apple.security.network.client': true,
  })
})

test('both products advertise CloudKit and remote notifications to automatic signing', () => {
  const project = readFileSync(path.join(iosRoot, 'project.yml'), 'utf8')
  const phoneTarget = project.slice(
    project.indexOf('  BirthdayMobile:\n'),
    project.indexOf('  BirthdayMac:\n'),
  )
  const macTarget = project.slice(
    project.indexOf('  BirthdayMac:\n'),
    project.indexOf('  BirthdayMobileUITests:\n'),
  )

  for (const target of [phoneTarget, macTarget]) {
    assert.match(target, /SystemCapabilities:[\s\S]*com\.apple\.iCloud:[\s\S]*enabled: 1/)
    assert.match(target, /SystemCapabilities:[\s\S]*com\.apple\.Push:[\s\S]*enabled: 1/)
  }

  assert.match(project, /postGenCommand: \.\/scripts\/fix-system-capabilities\.py/)
  generatedProject()
  const generated = readFileSync(path.join(projectPath, 'project.pbxproj'), 'utf8')
  assert.doesNotMatch(generated, /SystemCapabilities = "/)
  assert.equal((generated.match(/com\.apple\.iCloud =/g) ?? []).length, 2)
  assert.equal((generated.match(/com\.apple\.Push =/g) ?? []).length, 2)
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
  assert.equal(info.ITSAppUsesNonExemptEncryption, false)
  assert.equal(macInfo.ITSAppUsesNonExemptEncryption, false)
  assert.equal(macInfo.LSApplicationCategoryType, 'public.app-category.lifestyle')
  assert.match(releaseConfiguration, /^BIRTHDAY_API_BASE_URL\s*=\s*$/m)
  assert.doesNotMatch(releaseConfiguration, /https?:/)
})

test('iPhone and Mac store drafts describe private, optional CloudKit without real-time promises', () => {
  const phone = JSON.parse(readFileSync(
    path.join(iosRoot, 'AppStore/metadata/zh-Hans.json'),
    'utf8',
  ))
  const mac = JSON.parse(readFileSync(
    path.join(iosRoot, 'AppStore/metadata/macos-zh-Hans.json'),
    'utf8',
  ))

  for (const metadata of [phone, mac]) {
    const copy = `${metadata.promotionalText}\n${metadata.description}\n${metadata.reviewNotes}`
    assert.match(copy, /iCloud/)
    assert.match(copy, /私有/)
    assert.match(copy, /离线/)
    assert.doesNotMatch(copy, /实时同步|即时同步/)
  }
})
