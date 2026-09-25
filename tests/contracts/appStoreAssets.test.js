const assert = require('node:assert/strict')
const { execFileSync } = require('node:child_process')
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
  assert.match(metadata.whatsNew, /iCloud/)
  assert.match(metadata.description, /设置.*关闭/)
  assert.match(metadata.description, /本机优先/)
  assert.match(metadata.description, /iCloud.*私有/)
  assert.match(metadata.description, /离线/)
  assert.match(metadata.description, /导出/)
  assert.match(metadata.reviewNotes, /iCloud.*私有/)
  assert.match(metadata.reviewNotes, /无需.*账号/)
  assert.doesNotMatch(`${metadata.promotionalText}\n${metadata.description}\n${metadata.whatsNew}`, /实时同步|即时同步|完全离线/)
})

test('Mac zh-Hans metadata describes the desktop, offline, and private iCloud experience', () => {
  const metadata = JSON.parse(
    readFileSync(path.join(appStoreRoot, 'metadata/macos-zh-Hans.json'), 'utf8'),
  )

  assert.ok(characterCount(metadata.name) <= 30)
  assert.ok(characterCount(metadata.subtitle) <= 30)
  assert.ok(characterCount(metadata.promotionalText) <= 170)
  assert.ok(characterCount(metadata.description) <= 4_000)
  assert.ok(Buffer.byteLength(metadata.keywords, 'utf8') <= 100)
  assert.equal(metadata.supportURL, 'https://qisw.top/birthday/support.html')
  assert.equal(metadata.privacyPolicyURL, 'https://qisw.top/birthday/privacy.html')
  assert.equal(metadata.requiresDemoAccount, false)
  assert.match(metadata.description, /Mac/)
  assert.match(metadata.description, /三栏|桌面窗口/)
  assert.match(metadata.description, /键盘|快捷键/)
  assert.match(metadata.description, /本机优先/)
  assert.match(metadata.description, /iCloud.*私有/)
  assert.match(metadata.description, /离线/)
  assert.doesNotMatch(`${metadata.promotionalText}\n${metadata.description}`, /实时同步|即时同步|完全离线/)
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
  assert.match(privacy, /本机优先/)
  assert.match(privacy, /iCloud 私有数据库/)
  assert.match(privacy, /默认开启/)
  assert.match(privacy, /设置.*关闭/)
  assert.match(privacy, /账号变化.*确认/)
  assert.match(privacy, /导出生日数据/)
  assert.match(privacy, /开发者.*无法.*读取.*iCloud/)
  assert.match(privacy, /支持邮件会保留到问题解决或数据请求完成后最多 12 个月/)
  assert.match(support, /iCloud 私有数据库/)
  assert.match(support, /设置.*关闭/)
  assert.match(support, /账号变化.*确认/)
  assert.match(support, /导出生日数据/)
  assert.match(support, /发件邮箱仅用于答复与排查/)
  assert.match(stylesheet, /prefers-reduced-motion/)
  assert.doesNotMatch(`${privacy}\n${support}`, /iOS 1\.0|纯离线应用|完全在本机处理/)
  assert.doesNotMatch(`${privacy}\n${support}\n${stylesheet}`, /__[A-Z0-9_]+__/)
})

test('privacy questionnaire and review notes document the CloudKit boundary', () => {
  const questionnaire = readFileSync(path.join(appStoreRoot, 'app-privacy.md'), 'utf8')
  const reviewNotes = readFileSync(path.join(appStoreRoot, 'review-notes.md'), 'utf8')
  const readme = readFileSync(path.join(appStoreRoot, 'README.md'), 'utf8')

  assert.match(questionnaire, /Apple.*私有数据库/)
  assert.match(questionnaire, /开发者.*无法.*访问.*记录正文/)
  assert.match(questionnaire, /不收集数据/)
  assert.match(questionnaire, /Xcode.*Privacy Report|Xcode.*隐私报告/)
  assert.match(reviewNotes, /iCloud.*私有/)
  assert.match(reviewNotes, /设置.*关闭/)
  assert.match(reviewNotes, /离线/)
  assert.doesNotMatch(`${questionnaire}\n${reviewNotes}\n${readme}`, /首发采用纯离线方案|本版本不包含账号登录或服务器同步入口/)
})

test('App Store Release keeps legacy server sync disabled while allowing CloudKit changes', () => {
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
  assert.doesNotMatch(project, /BGTaskSchedulerPermittedIdentifiers/)
  assert.doesNotMatch(info, /BGTaskSchedulerPermittedIdentifiers/)
  assert.match(info, /<string>remote-notification<\/string>/)
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

test('Mac App Store upload screenshot set is complete 16:10 RGB JPEG output', () => {
  const screenshotDirectory = path.join(appStoreRoot, 'Screenshots/macos/zh-Hans/upload')
  const expectedFiles = [
    '01-calendar.jpg',
    '02-all-birthdays.jpg',
    '03-reminder-editor.jpg',
    '04-local-privacy.jpg',
    '05-icloud-export.jpg',
  ]

  assert.deepEqual(readdirSync(screenshotDirectory).sort(), expectedFiles)
  for (const filename of expectedFiles) {
    const filePath = path.join(screenshotDirectory, filename)
    assert.ok(statSync(filePath).size > 200_000, `${filename} is unexpectedly small`)
    assert.deepEqual(readJPEGDimensions(filePath), { width: 2_880, height: 1_800 })

    const metadata = execFileSync('/usr/bin/sips', [
      '-g', 'format',
      '-g', 'space',
      '-g', 'hasAlpha',
      filePath,
    ], { encoding: 'utf8' })
    assert.match(metadata, /format: jpeg/)
    assert.match(metadata, /space: RGB/)
    assert.match(metadata, /hasAlpha: no/)
  }
})
