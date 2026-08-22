const assert = require('node:assert/strict')
const { readFileSync, readdirSync, statSync } = require('node:fs')
const path = require('node:path')
const test = require('node:test')

const repositoryRoot = path.resolve(__dirname, '../..')
const appStoreRoot = path.join(repositoryRoot, 'ios/AppStore')

function characterCount(value) {
  return [...value].length
}

function readJPEGDimensions(filePath) {
  const bytes = readFileSync(filePath)
  assert.equal(bytes.readUInt16BE(0), 0xffd8, `${filePath} must be a JPEG`)

  const startOfFrameMarkers = new Set([
    0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf,
  ])
  let offset = 2
  while (offset + 8 < bytes.length) {
    if (bytes[offset] !== 0xff) {
      offset += 1
      continue
    }
    const marker = bytes[offset + 1]
    if (startOfFrameMarkers.has(marker)) {
      return {
        height: bytes.readUInt16BE(offset + 5),
        width: bytes.readUInt16BE(offset + 7),
      }
    }
    if (marker === 0xd8 || marker === 0xd9) {
      offset += 2
      continue
    }
    const segmentLength = bytes.readUInt16BE(offset + 2)
    assert.ok(segmentLength >= 2, `${filePath} contains an invalid JPEG segment`)
    offset += 2 + segmentLength
  }
  throw new Error(`${filePath} is missing JPEG dimensions`)
}

test('App Store zh-Hans metadata stays inside field limits and points to prepared pages', () => {
  const metadata = JSON.parse(
    readFileSync(path.join(appStoreRoot, 'metadata/zh-Hans.json'), 'utf8'),
  )

  assert.ok(characterCount(metadata.name) <= 30)
  assert.ok(characterCount(metadata.subtitle) <= 30)
  assert.ok(characterCount(metadata.promotionalText) <= 170)
  assert.ok(characterCount(metadata.description) <= 4_000)
  assert.ok(Buffer.byteLength(metadata.keywords, 'utf8') <= 100)
  assert.equal(metadata.supportURL, 'https://qisw.top/birthday/support.html')
  assert.equal(metadata.privacyPolicyURL, 'https://qisw.top/birthday/privacy.html')
  assert.equal(metadata.requiresDemoAccount, false)
  assert.equal(Object.hasOwn(metadata, 'whatsNew'), false)
  assert.doesNotMatch(metadata.description, /连接服务器|多设备同步|可选同步/)
  assert.doesNotMatch(metadata.reviewNotes, /连接服务器|多设备同步|可选同步|账号密码/)
})

test('public privacy and support pages expose matching navigation and support contact', () => {
  const privacy = readFileSync(path.join(repositoryRoot, 'public/privacy.html'), 'utf8')
  const support = readFileSync(path.join(repositoryRoot, 'public/support.html'), 'utf8')
  const stylesheet = readFileSync(path.join(repositoryRoot, 'public/legal.css'), 'utf8')

  assert.match(privacy, /href="support\.html"/)
  assert.match(support, /href="privacy\.html"/)
  assert.match(privacy, /mailto:support@qisw\.top/)
  assert.match(support, /mailto:support@qisw\.top/)
  assert.match(privacy, /不用于跨应用跟踪/)
  assert.match(privacy, /不集成第三方广告或分析 SDK/)
  assert.match(privacy, /不低于本政策的隐私保护义务/)
  assert.match(privacy, /不包含账号登录或服务器同步入口/)
  assert.match(privacy, /支持邮件会保留到问题解决或数据请求完成后最多 12 个月/)
  assert.match(support, /发件邮箱仅用于答复与排查/)
  assert.match(stylesheet, /prefers-reduced-motion/)
  assert.doesNotMatch(`${privacy}\n${support}\n${stylesheet}`, /__[A-Z0-9_]+__/)
})

test('App Store Release composition is local-only and has no background sync entitlement', () => {
  const releaseConfiguration = readFileSync(
    path.join(repositoryRoot, 'ios/BirthdayMobile/Config/Release.xcconfig'),
    'utf8',
  )
  const project = readFileSync(path.join(repositoryRoot, 'ios/project.yml'), 'utf8')
  const info = readFileSync(
    path.join(repositoryRoot, 'ios/BirthdayMobile/Info.plist'),
    'utf8',
  )

  assert.match(releaseConfiguration, /^BIRTHDAY_API_BASE_URL\s*=\s*$/m)
  assert.doesNotMatch(releaseConfiguration, /https?:/)
  assert.doesNotMatch(project, /BGTaskSchedulerPermittedIdentifiers|UIBackgroundModes/)
  assert.doesNotMatch(info, /BGTaskSchedulerPermittedIdentifiers|UIBackgroundModes/)
})

test('iOS settings exposes the public privacy and support pages', () => {
  const settings = readFileSync(
    path.join(repositoryRoot, 'ios/BirthdayMobile/Features/Settings/SettingsView.swift'),
    'utf8',
  )

  assert.match(settings, /Section\("关于与支持"\)/)
  assert.match(settings, /https:\/\/qisw\.top\/birthday\/privacy\.html/)
  assert.match(settings, /https:\/\/qisw\.top\/birthday\/support\.html/)
  assert.match(settings, /accessibilityIdentifier\("privacyPolicyLink"\)/)
  assert.match(settings, /accessibilityIdentifier\("supportLink"\)/)
})

test('App Store upload screenshot set is complete 6.9-inch JPEG output', () => {
  const screenshotDirectory = path.join(appStoreRoot, 'Screenshots/zh-Hans/upload')
  const expectedFiles = [
    '01-lunar-calendar.jpg',
    '02-all-birthdays.jpg',
    '03-reminder-editor.jpg',
    '04-local-privacy.jpg',
    '05-offline-first.jpg',
  ]

  assert.deepEqual(readdirSync(screenshotDirectory).sort(), expectedFiles)
  for (const filename of expectedFiles) {
    const filePath = path.join(screenshotDirectory, filename)
    assert.ok(statSync(filePath).size > 100_000, `${filename} is unexpectedly small`)
    assert.deepEqual(readJPEGDimensions(filePath), { width: 1_320, height: 2_868 })
  }
})
