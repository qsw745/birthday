const STORAGE_KEY = 'birthday_reminder_cache_v1'
const VIEW_KEY = 'birthday_reminder_view_v1'
const DEFAULT_TIME = '08:00'
const DATE_TIME_CONNECTOR = '|'
const COMMON_TIMES = ['08:00', '09:00', '10:00', '12:00', '14:00', '16:00', '18:00', '20:00']

const state = {
  birthdays: [],
  editingId: null,
  busy: false,
  authenticated: false,
  viewMode: loadViewMode(),
  cache: loadCache(),
}

const dom = {}
let statusTimer = null
let dateTimePicker = null

document.addEventListener('DOMContentLoaded', () => {
  cacheDom()
  populateLunarOptions()
  populateTimeLists()
  bindEvents()
  initDateTimePicker()
  resetForm({ clearStatus: true })
  checkAuth()
})

function cacheDom() {
  dom.loginView = document.getElementById('loginView')
  dom.appView = document.getElementById('appView')
  dom.loginForm = document.getElementById('loginForm')
  dom.loginUsername = document.getElementById('loginUsername')
  dom.loginPassword = document.getElementById('loginPassword')
  dom.loginButton = document.getElementById('loginButton')
  dom.loginStatus = document.getElementById('loginStatus')
  dom.passkeyDivider = document.getElementById('passkeyDivider')
  dom.passkeyLoginButton = document.getElementById('passkeyLoginButton')

  dom.formCard = document.getElementById('formCard')
  dom.birthdayForm = document.getElementById('birthdayForm')
  dom.formTitle = document.getElementById('formTitle')
  dom.formHint = document.getElementById('formHint')
  dom.statusToast = document.getElementById('statusToast')

  dom.nameInput = document.getElementById('nameInput')
  dom.emailInput = document.getElementById('emailInput')
  dom.messageInput = document.getElementById('messageInput')
  dom.lunarMonth = document.getElementById('lunarMonth')
  dom.lunarDay = document.getElementById('lunarDay')
  dom.isLeapMonth = document.getElementById('isLeapMonth')
  dom.remindTime = document.getElementById('remindTime')
  dom.timePicker = document.getElementById('timePicker')
  dom.timeOptions = Array.from(document.querySelectorAll('.time-option'))
  dom.timeDisplay = document.getElementById('timeDisplay')
  dom.timePanel = document.getElementById('timePanel')
  dom.timeText = document.getElementById('timeText')
  dom.timeBadge = document.getElementById('timeBadge')
  dom.hourList = document.getElementById('hourList')
  dom.minuteList = document.getElementById('minuteList')

  dom.addButton = document.getElementById('addButton')
  dom.updateButton = document.getElementById('updateButton')
  dom.cancelButton = document.getElementById('cancelButton')
  dom.refreshButton = document.getElementById('refreshButton')
  dom.scrollToForm = document.getElementById('scrollToForm')
  dom.togglePasswordButton = document.getElementById('togglePasswordButton')
  dom.logoutButton = document.getElementById('logoutButton')
  dom.passwordCard = document.getElementById('passwordCard')
  dom.passwordForm = document.getElementById('passwordForm')
  dom.currentPasswordInput = document.getElementById('currentPasswordInput')
  dom.newPasswordInput = document.getElementById('newPasswordInput')
  dom.confirmPasswordInput = document.getElementById('confirmPasswordInput')
  dom.passwordStatus = document.getElementById('passwordStatus')
  dom.changePasswordButton = document.getElementById('changePasswordButton')
  dom.cancelPasswordButton = document.getElementById('cancelPasswordButton')

  dom.togglePasskeyButton = document.getElementById('togglePasskeyButton')
  dom.passkeyCard = document.getElementById('passkeyCard')
  dom.passkeyStatus = document.getElementById('passkeyStatus')
  dom.passkeyList = document.getElementById('passkeyList')
  dom.passkeyEmpty = document.getElementById('passkeyEmpty')
  dom.addPasskeyButton = document.getElementById('addPasskeyButton')
  dom.closePasskeyButton = document.getElementById('closePasskeyButton')

  dom.searchInput = document.getElementById('searchInput')
  dom.upcomingFilter = document.getElementById('upcomingFilter')
  dom.viewButtons = Array.from(document.querySelectorAll('[data-view-mode]'))

  dom.list = document.getElementById('birthdayList')
  dom.emptyState = document.getElementById('emptyState')

  dom.totalCount = document.getElementById('totalCount')
  dom.upcomingCount = document.getElementById('upcomingCount')
  dom.leapCount = document.getElementById('leapCount')
  dom.viewCount = document.getElementById('viewCount')
}

function populateLunarOptions() {
  for (let i = 1; i <= 12; i += 1) {
    const option = document.createElement('option')
    option.value = i
    option.textContent = `${i}月`
    dom.lunarMonth.appendChild(option)
  }

  for (let i = 1; i <= 30; i += 1) {
    const option = document.createElement('option')
    option.value = i
    option.textContent = `${i}日`
    dom.lunarDay.appendChild(option)
  }
}

function populateTimeLists() {
  if (!dom.hourList || !dom.minuteList) return

  dom.hourList.innerHTML = ''
  dom.minuteList.innerHTML = ''

  for (let i = 0; i < 24; i += 1) {
    const button = document.createElement('button')
    button.type = 'button'
    button.className = 'time-item'
    button.dataset.unit = 'hour'
    button.dataset.value = String(i).padStart(2, '0')
    button.textContent = button.dataset.value
    dom.hourList.appendChild(button)
  }

  for (let i = 0; i < 60; i += 1) {
    const button = document.createElement('button')
    button.type = 'button'
    button.className = 'time-item'
    button.dataset.unit = 'minute'
    button.dataset.value = String(i).padStart(2, '0')
    button.textContent = button.dataset.value
    dom.minuteList.appendChild(button)
  }
}

function bindEvents() {
  dom.loginForm.addEventListener('submit', handleLogin)
  dom.birthdayForm.addEventListener('submit', event => event.preventDefault())
  dom.addButton.addEventListener('click', handleAdd)
  dom.updateButton.addEventListener('click', handleUpdate)
  dom.cancelButton.addEventListener('click', () => resetForm({ clearStatus: true }))
  dom.refreshButton.addEventListener('click', () => loadBirthdays({ showStatus: true }))
  dom.togglePasswordButton.addEventListener('click', togglePasswordCard)
  dom.logoutButton.addEventListener('click', handleLogout)
  dom.passwordForm.addEventListener('submit', handlePasswordChange)
  dom.cancelPasswordButton.addEventListener('click', closePasswordCard)
  dom.passkeyLoginButton.addEventListener('click', handlePasskeyLogin)
  dom.togglePasskeyButton.addEventListener('click', togglePasskeyCard)
  dom.addPasskeyButton.addEventListener('click', handleAddPasskey)
  dom.closePasskeyButton.addEventListener('click', closePasskeyCard)
  dom.passkeyList.addEventListener('click', handlePasskeyListAction)
  dom.scrollToForm.addEventListener('click', () => {
    dom.formCard.scrollIntoView({ behavior: 'smooth', block: 'start' })
    dom.nameInput.focus()
  })

  dom.searchInput.addEventListener('input', renderBirthdays)
  dom.upcomingFilter.addEventListener('change', renderBirthdays)
  dom.viewButtons.forEach(button => {
    button.addEventListener('click', () => setViewMode(button.dataset.viewMode))
  })
  dom.lunarMonth.addEventListener('change', syncDateTimeDisplay)
  dom.lunarDay.addEventListener('change', syncDateTimeDisplay)
  dom.isLeapMonth.addEventListener('change', syncDateTimeDisplay)
  dom.list.addEventListener('click', handleListAction)
  if (dom.timePanel && dom.timeDisplay) {
    dom.timeDisplay.addEventListener('click', toggleTimePanel)
    dom.timeDisplay.addEventListener('keydown', handleTimeDisplayKeydown)
  }
  if (dom.timePanel) {
    dom.timePanel.addEventListener('click', handleTimePanelClick)
  }
  document.addEventListener('click', handleTimeOutsideClick)
  document.addEventListener('keydown', handleTimeEscape)
}

function initDateTimePicker() {
  if (!dom.timeDisplay || typeof MobileSelect === 'undefined') return

  dateTimePicker = new MobileSelect({
    trigger: dom.timeDisplay,
    title: '选择农历生日与提醒时间',
    wheels: buildDateTimeWheels(),
    position: getDateTimePosition(),
    colWidth: [1, 1, 1, 1, 1],
    connector: DATE_TIME_CONNECTOR,
    triggerDisplayValue: false,
    ensureBtnText: '完成',
    cancelBtnText: '取消',
    ensureBtnColor: '#2e8c8c',
    cancelBtnColor: '#687482',
    titleColor: '#18202a',
    titleBgColor: '#ffffff',
    textColor: '#18202a',
    bgColor: '#ffffff',
    maskOpacity: 0.35,
    onShow: syncDateTimePickerPosition,
    onChange: applyDateTimeSelection,
  })
}

function buildDateTimeWheels() {
  return [
    { data: Array.from({ length: 12 }, (_, index) => ({ id: String(index + 1), value: `${index + 1}月` })) },
    { data: Array.from({ length: 30 }, (_, index) => ({ id: String(index + 1), value: `${index + 1}日` })) },
    {
      data: [
        { id: 'normal', value: '不闰' },
        { id: 'leap', value: '闰月' },
      ],
    },
    { data: Array.from({ length: 24 }, (_, index) => ({ id: String(index).padStart(2, '0'), value: `${String(index).padStart(2, '0')}时` })) },
    { data: Array.from({ length: 60 }, (_, index) => ({ id: String(index).padStart(2, '0'), value: `${String(index).padStart(2, '0')}分` })) },
  ]
}

function applyDateTimeSelection(data) {
  if (!Array.isArray(data) || data.length < 5) return

  const month = Number(data[0].id)
  const day = Number(data[1].id)
  const isLeap = data[2].id === 'leap'
  const hour = data[3].id
  const minute = data[4].id
  if (!month || !day || !hour || !minute) return

  dom.lunarMonth.value = String(month)
  dom.lunarDay.value = String(day)
  dom.isLeapMonth.checked = isLeap
  setTimeFromString(`${hour}:${minute}`)
}

function getDateTimePosition() {
  const month = Math.max(Number(dom.lunarMonth.value || 1) - 1, 0)
  const day = Math.max(Number(dom.lunarDay.value || 1) - 1, 0)
  const leap = dom.isLeapMonth.checked ? 1 : 0
  const { hour, minute } = parseTime(dom.remindTime.value || DEFAULT_TIME)
  return [month, day, leap, Number(hour), Number(minute)]
}

function syncDateTimePickerPosition() {
  if (!dateTimePicker || typeof dateTimePicker.locatePosition !== 'function') return
  getDateTimePosition().forEach((position, index) => {
    dateTimePicker.locatePosition(index, position)
  })
}

async function checkAuth() {
  setLoginBusy(true)
  try {
    const response = await fetch('/api/auth/status', { credentials: 'same-origin' })
    const data = response.ok ? await response.json() : { authenticated: false }
    if (data.authenticated) {
      showApp()
      await loadBirthdays()
    } else {
      showLogin()
    }
  } catch (error) {
    showLogin()
    setLoginStatus('error', '无法检查登录状态')
  } finally {
    setLoginBusy(false)
  }
}

async function handleLogin(event) {
  event.preventDefault()
  if (state.busy) return

  const username = dom.loginUsername.value.trim()
  const password = dom.loginPassword.value
  if (!username || !password) {
    setLoginStatus('error', '请输入用户名和密码')
    return
  }

  setLoginBusy(true)
  try {
    const response = await fetch('/api/auth/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      credentials: 'same-origin',
      body: JSON.stringify({ username, password }),
    })
    if (!response.ok) {
      const detail = await safeReadError(response)
      throw new Error(detail || '登录失败')
    }
    dom.loginPassword.value = ''
    setLoginStatus('', '')
    showApp()
    await loadBirthdays()
  } catch (error) {
    setLoginStatus('error', error.message)
  } finally {
    setLoginBusy(false)
  }
}

async function handleLogout() {
  if (state.busy) return
  setBusy(true)
  try {
    await fetch('/api/auth/logout', {
      method: 'POST',
      credentials: 'same-origin',
    })
  } finally {
    state.birthdays = []
    renderBirthdays()
    resetForm({ clearStatus: true })
    showLogin()
    setBusy(false)
  }
}

function togglePasswordCard() {
  if (dom.passwordCard.hidden) {
    dom.passwordCard.hidden = false
    dom.currentPasswordInput.focus()
  } else {
    closePasswordCard()
  }
}

function closePasswordCard() {
  dom.passwordForm.reset()
  setPasswordStatus('', '')
  dom.passwordCard.hidden = true
}

async function handlePasswordChange(event) {
  event.preventDefault()
  if (state.busy) return

  const currentPassword = dom.currentPasswordInput.value
  const newPassword = dom.newPasswordInput.value
  const confirmPassword = dom.confirmPasswordInput.value

  if (!currentPassword || !newPassword || !confirmPassword) {
    setPasswordStatus('error', '请填写完整密码信息')
    return
  }
  if (newPassword.length < 8) {
    setPasswordStatus('error', '新密码至少 8 位')
    return
  }
  if (newPassword !== confirmPassword) {
    setPasswordStatus('error', '两次输入的新密码不一致')
    return
  }

  setBusy(true)
  try {
    const response = await fetch('/api/auth/password', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      credentials: 'same-origin',
      body: JSON.stringify({ currentPassword, newPassword }),
    })
    if (!response.ok) {
      const detail = await safeReadError(response)
      throw new Error(detail || '修改密码失败')
    }
    dom.passwordForm.reset()
    setPasswordStatus('success', '密码已修改，请重新登录')
    setTimeout(() => {
      state.birthdays = []
      renderBirthdays()
      closePasswordCard()
      showLogin()
    }, 900)
  } catch (error) {
    setPasswordStatus('error', error.message)
  } finally {
    setBusy(false)
  }
}

function showLogin() {
  state.authenticated = false
  dom.appView.hidden = true
  dom.loginView.hidden = false
  const passkeySupported = supportsWebAuthn()
  dom.passkeyDivider.hidden = !passkeySupported
  dom.passkeyLoginButton.hidden = !passkeySupported
  dom.loginUsername.focus()
}

function showApp() {
  state.authenticated = true
  dom.loginView.hidden = true
  dom.appView.hidden = false
}

function supportsWebAuthn() {
  return typeof window.PublicKeyCredential === 'function' && !!(navigator.credentials && navigator.credentials.create)
}

function bufToB64u(buffer) {
  const bytes = new Uint8Array(buffer)
  let binary = ''
  bytes.forEach(byte => {
    binary += String.fromCharCode(byte)
  })
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

function b64uToBuf(value) {
  const base64 = String(value).replace(/-/g, '+').replace(/_/g, '/')
  const padded = base64 + '='.repeat((4 - (base64.length % 4)) % 4)
  const binary = atob(padded)
  const bytes = new Uint8Array(binary.length)
  for (let i = 0; i < binary.length; i += 1) {
    bytes[i] = binary.charCodeAt(i)
  }
  return bytes.buffer
}

function decodeCreationOptions(options) {
  return {
    ...options,
    challenge: b64uToBuf(options.challenge),
    user: { ...options.user, id: b64uToBuf(options.user.id) },
    excludeCredentials: (options.excludeCredentials || []).map(item => ({ ...item, id: b64uToBuf(item.id) })),
  }
}

function decodeRequestOptions(options) {
  return {
    ...options,
    challenge: b64uToBuf(options.challenge),
    allowCredentials: (options.allowCredentials || []).map(item => ({ ...item, id: b64uToBuf(item.id) })),
  }
}

function encodeRegistrationResult(credential) {
  const response = credential.response
  return {
    id: credential.id,
    rawId: bufToB64u(credential.rawId),
    type: credential.type,
    authenticatorAttachment: credential.authenticatorAttachment || undefined,
    clientExtensionResults: credential.getClientExtensionResults ? credential.getClientExtensionResults() : {},
    response: {
      clientDataJSON: bufToB64u(response.clientDataJSON),
      attestationObject: bufToB64u(response.attestationObject),
      transports: typeof response.getTransports === 'function' ? response.getTransports() : undefined,
    },
  }
}

function encodeAuthenticationResult(credential) {
  const response = credential.response
  return {
    id: credential.id,
    rawId: bufToB64u(credential.rawId),
    type: credential.type,
    authenticatorAttachment: credential.authenticatorAttachment || undefined,
    clientExtensionResults: credential.getClientExtensionResults ? credential.getClientExtensionResults() : {},
    response: {
      clientDataJSON: bufToB64u(response.clientDataJSON),
      authenticatorData: bufToB64u(response.authenticatorData),
      signature: bufToB64u(response.signature),
      userHandle: response.userHandle ? bufToB64u(response.userHandle) : undefined,
    },
  }
}

function describePasskeyError(error, fallback) {
  if (error && (error.name === 'NotAllowedError' || error.name === 'AbortError')) {
    return '已取消验证，或验证超时'
  }
  if (error && error.name === 'InvalidStateError') {
    return '该设备可能已注册过通行密钥'
  }
  return (error && error.message) || fallback
}

async function handlePasskeyLogin() {
  if (state.busy) return
  setLoginBusy(true)
  try {
    const optionsResponse = await fetch('/api/auth/webauthn/login/options', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      credentials: 'same-origin',
      body: '{}',
    })
    if (!optionsResponse.ok) {
      const detail = await safeReadError(optionsResponse)
      throw new Error(detail || '无法发起通行密钥登录')
    }
    const { token, options } = await optionsResponse.json()
    const credential = await navigator.credentials.get({ publicKey: decodeRequestOptions(options) })
    if (!credential) {
      throw new Error('未获取到通行密钥')
    }
    const verifyResponse = await fetch('/api/auth/webauthn/login/verify', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      credentials: 'same-origin',
      body: JSON.stringify({ token, response: encodeAuthenticationResult(credential) }),
    })
    if (!verifyResponse.ok) {
      const detail = await safeReadError(verifyResponse)
      throw new Error(detail || '通行密钥登录失败')
    }
    setLoginStatus('', '')
    showApp()
    await loadBirthdays()
  } catch (error) {
    setLoginStatus('error', describePasskeyError(error, '通行密钥登录失败'))
  } finally {
    setLoginBusy(false)
  }
}

function togglePasskeyCard() {
  if (dom.passkeyCard.hidden) {
    dom.passkeyCard.hidden = false
    setPasskeyStatus('', '')
    if (!supportsWebAuthn()) {
      setPasskeyStatus('error', '当前浏览器不支持通行密钥')
    }
    loadPasskeys()
  } else {
    closePasskeyCard()
  }
}

function closePasskeyCard() {
  setPasskeyStatus('', '')
  dom.passkeyCard.hidden = true
}

async function loadPasskeys() {
  try {
    const response = await fetch('/api/auth/webauthn/credentials', { credentials: 'same-origin' })
    if (response.status === 401) {
      showLogin()
      return
    }
    if (!response.ok) {
      throw new Error('获取通行密钥列表失败')
    }
    renderPasskeys(await response.json())
  } catch (error) {
    setPasskeyStatus('error', error.message)
  }
}

function renderPasskeys(list) {
  const items = Array.isArray(list) ? list : []
  dom.passkeyList.innerHTML = items
    .map(item => {
      const id = escapeHTML(item.id)
      const name = escapeHTML(item.deviceName || '通行密钥')
      const created = escapeHTML(formatDate(item.createdAt))
      const lastUsed = item.lastUsedAt ? `最近使用 ${escapeHTML(formatDate(item.lastUsedAt))}` : '未使用过'
      return `
        <div class="passkey-item" data-id="${id}">
          <div class="passkey-meta">
            <strong>${name}</strong>
            <span class="muted">注册于 ${created} · ${lastUsed}</span>
          </div>
          <button class="btn danger" data-action="remove-passkey" data-id="${id}" type="button">删除</button>
        </div>
      `
    })
    .join('')
  dom.passkeyEmpty.classList.toggle('show', items.length === 0)
}

function defaultDeviceName() {
  const ua = navigator.userAgent
  if (/iPhone/.test(ua)) return 'iPhone'
  if (/iPad/.test(ua)) return 'iPad'
  if (/Android/.test(ua)) return 'Android 设备'
  if (/Macintosh/.test(ua)) return 'Mac'
  if (/Windows/.test(ua)) return 'Windows 电脑'
  return '通行密钥'
}

async function handleAddPasskey() {
  if (state.busy) return
  if (!supportsWebAuthn()) {
    setPasskeyStatus('error', '当前浏览器不支持通行密钥')
    return
  }

  setBusy(true)
  try {
    const optionsResponse = await fetch('/api/auth/webauthn/register/options', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      credentials: 'same-origin',
      body: '{}',
    })
    if (optionsResponse.status === 401) {
      showLogin()
      throw new Error('请先登录')
    }
    if (!optionsResponse.ok) {
      const detail = await safeReadError(optionsResponse)
      throw new Error(detail || '无法发起通行密钥注册')
    }
    const { token, options } = await optionsResponse.json()
    const credential = await navigator.credentials.create({ publicKey: decodeCreationOptions(options) })
    if (!credential) {
      throw new Error('未获取到通行密钥')
    }
    const verifyResponse = await fetch('/api/auth/webauthn/register/verify', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      credentials: 'same-origin',
      body: JSON.stringify({
        token,
        deviceName: defaultDeviceName(),
        response: encodeRegistrationResult(credential),
      }),
    })
    if (!verifyResponse.ok) {
      const detail = await safeReadError(verifyResponse)
      throw new Error(detail || '通行密钥注册失败')
    }
    setPasskeyStatus('success', '通行密钥已添加，下次可直接扫脸/指纹登录')
    await loadPasskeys()
  } catch (error) {
    setPasskeyStatus('error', describePasskeyError(error, '通行密钥注册失败'))
  } finally {
    setBusy(false)
  }
}

async function handlePasskeyListAction(event) {
  const button = event.target.closest('button[data-action="remove-passkey"]')
  if (!button || state.busy) return
  const id = button.dataset.id
  if (!id) return

  const confirmed = window.confirm('确定要删除这个通行密钥吗？删除后该设备将无法扫脸/指纹登录。')
  if (!confirmed) return

  setBusy(true)
  try {
    const response = await fetch(`/api/auth/webauthn/credentials/${encodeURIComponent(id)}`, {
      method: 'DELETE',
      credentials: 'same-origin',
    })
    if (response.status === 401) {
      showLogin()
      throw new Error('请先登录')
    }
    if (!response.ok) {
      const detail = await safeReadError(response)
      throw new Error(detail || '删除失败')
    }
    setPasskeyStatus('success', '通行密钥已删除')
    await loadPasskeys()
  } catch (error) {
    setPasskeyStatus('error', error.message)
  } finally {
    setBusy(false)
  }
}

function setPasskeyStatus(type, message) {
  if (!message) {
    dom.passkeyStatus.textContent = ''
    dom.passkeyStatus.dataset.state = ''
    dom.passkeyStatus.classList.remove('visible')
    return
  }
  dom.passkeyStatus.textContent = message
  dom.passkeyStatus.dataset.state = type
  dom.passkeyStatus.classList.add('visible')
}

async function loadBirthdays(options = {}) {
  const { showStatus = true } = options
  setBusy(true)
  if (showStatus) {
    setStatus('info', '正在加载提醒列表...')
  }

  try {
    const response = await fetch('/api/birthdays/list', { credentials: 'same-origin' })
    if (response.status === 401) {
      showLogin()
      throw new Error('请先登录')
    }
    if (!response.ok) {
      throw new Error('加载提醒列表失败')
    }
    const data = await response.json()
    state.birthdays = Array.isArray(data) ? data : []
    applyCache()
    renderBirthdays()
    if (showStatus) {
      setStatus('success', `已加载 ${state.birthdays.length} 条提醒`)
    }
  } catch (error) {
    if (showStatus) {
      setStatus('error', `加载失败：${error.message}`)
    }
  } finally {
    setBusy(false)
  }
}

function applyCache() {
  state.birthdays = state.birthdays.map(item => {
    const cached = state.cache[item.id] || {}
    return {
      ...item,
      userEmail: cached.userEmail || item.userEmail || '',
      message: cached.message || item.message || '',
    }
  })
}

function renderBirthdays() {
  const filtered = getFilteredBirthdays()
  const sorted = sortBirthdays(filtered)

  syncViewButtons()
  dom.list.className = `list-scroll ${state.viewMode === 'card' ? 'card-view' : 'table-view'}`
  dom.list.innerHTML = sorted.length ? buildListMarkup(sorted) : ''
  dom.emptyState.classList.toggle('show', sorted.length === 0)
  updateStats(sorted)
}

function buildListMarkup(list) {
  if (state.viewMode === 'card') {
    return list.map(buildCard).join('')
  }

  return `
    <table class="reminder-table">
      <thead>
        <tr>
          <th scope="col">姓名</th>
          <th scope="col">农历生日</th>
          <th scope="col">提醒时间</th>
          <th scope="col">下次提醒</th>
          <th scope="col">倒计时</th>
          <th scope="col">邮箱</th>
          <th scope="col">操作</th>
        </tr>
      </thead>
      <tbody>
        ${list.map(buildTableRow).join('')}
      </tbody>
    </table>
  `
}

function buildTableRow(item) {
  const id = escapeHTML(item.id)
  const name = escapeHTML(item.name || '未命名')
  const lunar = escapeHTML(formatLunar(item))
  const remindTime = escapeHTML(item.remindTime || '未设置')
  const email = escapeHTML(item.userEmail || '未记录')
  const message = escapeHTML(item.message || '未填写提醒内容')
  const nextDate = escapeHTML(formatDate(item.nextSolarDate))
  const countdown = escapeHTML(formatCountdown(item.nextSolarDate))
  const isUpcoming = isUpcomingWithin(item.nextSolarDate, 30)

  return `
    <tr class="${isUpcoming ? 'is-upcoming' : ''}" data-id="${id}">
      <td>
        <div class="person-cell">
          <strong title="${name}">${name}</strong>
          <span class="table-subline" title="${message}">${message}</span>
        </div>
      </td>
      <td>${lunar}</td>
      <td>${remindTime}</td>
      <td>${nextDate}</td>
      <td><span class="countdown ${isUpcoming ? 'soon' : ''}">${countdown}</span></td>
      <td><span class="email-cell" title="${email}">${email}</span></td>
      <td>
        <div class="table-actions">
          <button class="btn ghost" data-action="edit" data-id="${id}" type="button">编辑</button>
          <button class="btn danger" data-action="delete" data-id="${id}" type="button">删除</button>
        </div>
      </td>
    </tr>
  `
}

function buildCard(item) {
  const id = escapeHTML(item.id)
  const name = escapeHTML(item.name || '未命名')
  const lunar = escapeHTML(formatLunar(item))
  const remindTime = escapeHTML(item.remindTime || '未设置')
  const email = escapeHTML(item.userEmail || '未记录')
  const message = escapeHTML(item.message || '未填写提醒内容')
  const nextDate = escapeHTML(formatDate(item.nextSolarDate))
  const countdown = escapeHTML(formatCountdown(item.nextSolarDate))
  const isUpcoming = isUpcomingWithin(item.nextSolarDate, 30)

  return `
    <article class="birthday-card ${isUpcoming ? 'upcoming' : ''}" data-id="${id}">
      <div class="card-top">
        <div>
          <h3>${name}</h3>
          <p class="meta">${lunar}</p>
        </div>
        <span class="chip">${isUpcoming ? '即将到来' : '未来提醒'}</span>
      </div>
      <div class="card-grid">
        <div>
          <span class="label">提醒时间</span>
          <span>${remindTime}</span>
        </div>
        <div>
          <span class="label">下次提醒</span>
          <span>${nextDate}</span>
        </div>
        <div>
          <span class="label">倒计时</span>
          <span>${countdown}</span>
        </div>
        <div>
          <span class="label">邮箱</span>
          <span>${email}</span>
        </div>
      </div>
      <div class="card-message">
        <span class="label">提醒内容</span>
        <p>${message}</p>
      </div>
      <div class="card-actions">
        <button class="btn ghost" data-action="edit" data-id="${id}" type="button">编辑</button>
        <button class="btn danger" data-action="delete" data-id="${id}" type="button">删除</button>
      </div>
    </article>
  `
}

function setViewMode(mode) {
  const nextMode = mode === 'card' ? 'card' : 'table'
  if (state.viewMode === nextMode) return
  state.viewMode = nextMode
  persistViewMode()
  renderBirthdays()
}

function syncViewButtons() {
  dom.viewButtons.forEach(button => {
    const active = button.dataset.viewMode === state.viewMode
    button.classList.toggle('active', active)
    button.setAttribute('aria-pressed', String(active))
  })
}

function getFilteredBirthdays() {
  const search = dom.searchInput.value.trim().toLowerCase()
  const upcomingOnly = dom.upcomingFilter.checked

  return state.birthdays.filter(item => {
    if (upcomingOnly && !isUpcomingWithin(item.nextSolarDate, 30)) {
      return false
    }

    if (!search) return true

    const haystack = [
      item.name,
      item.userEmail,
      item.message,
      item.lunarMonth ? `${item.lunarMonth}月` : null,
      item.lunarDay ? `${item.lunarDay}日` : null,
    ]
      .filter(Boolean)
      .join(' ')
      .toLowerCase()

    return haystack.includes(search)
  })
}

function sortBirthdays(list) {
  return [...list].sort((a, b) => {
    const dateA = toDate(a.nextSolarDate)
    const dateB = toDate(b.nextSolarDate)
    if (dateA && dateB) {
      return dateA.getTime() - dateB.getTime()
    }
    if (dateA) return -1
    if (dateB) return 1
    return String(a.name || '').localeCompare(String(b.name || ''), 'zh-CN')
  })
}

function updateStats(viewList) {
  const total = state.birthdays.length
  const upcoming = state.birthdays.filter(item => isUpcomingWithin(item.nextSolarDate, 30)).length
  const leap = state.birthdays.filter(item => Number(item.isLeapMonth) === 1).length

  dom.totalCount.textContent = total
  dom.upcomingCount.textContent = upcoming
  dom.leapCount.textContent = leap
  dom.viewCount.textContent = viewList.length
}

async function handleAdd() {
  if (state.busy) return
  const payload = collectFormData()
  if (!payload) return

  await submitForm({
    url: '/api/birthdays',
    method: 'POST',
    payload,
    successMessage: '提醒已保存',
  })
}

async function handleUpdate() {
  if (state.busy) return
  if (!state.editingId) {
    setStatus('error', '请先选择要编辑的提醒')
    return
  }

  const payload = collectFormData()
  if (!payload) return

  await submitForm({
    url: `/api/birthdays/${state.editingId}`,
    method: 'PUT',
    payload,
    successMessage: '提醒已更新',
  })
}

async function submitForm({ url, method, payload, successMessage }) {
  setBusy(true)
  try {
    const response = await fetch(url, {
      method,
      headers: { 'Content-Type': 'application/json' },
      credentials: 'same-origin',
      body: JSON.stringify(payload),
    })

    if (response.status === 401) {
      showLogin()
      throw new Error('请先登录')
    }

    if (!response.ok) {
      const detail = await safeReadError(response)
      throw new Error(detail || '操作失败')
    }

    const data = await safeReadJson(response)
    const cacheId = data && data.birthday && data.birthday.id ? data.birthday.id : state.editingId
    updateCache(payload, cacheId)
    setStatus('success', successMessage)
    resetForm()
    await loadBirthdays({ showStatus: false })
  } catch (error) {
    setStatus('error', error.message)
  } finally {
    setBusy(false)
  }
}

async function safeReadError(response) {
  try {
    const data = await response.json()
    return data.error || data.message || ''
  } catch (error) {
    return ''
  }
}

async function safeReadJson(response) {
  try {
    return await response.json()
  } catch (error) {
    return null
  }
}

function collectFormData() {
  const name = dom.nameInput.value.trim()
  const userEmail = dom.emailInput.value.trim()
  const message = dom.messageInput.value.trim()
  const lunarMonth = Number(dom.lunarMonth.value)
  const lunarDay = Number(dom.lunarDay.value)
  const isLeapMonth = dom.isLeapMonth.checked
  const remindTime = normalizeTime(dom.remindTime.value) || DEFAULT_TIME

  if (!name) {
    setStatus('error', '请填写寿星姓名')
    return null
  }

  if (!userEmail || !isValidEmail(userEmail)) {
    setStatus('error', '请输入有效的邮箱地址')
    return null
  }

  if (!lunarMonth || !lunarDay) {
    setStatus('error', '请选择农历生日')
    return null
  }

  return {
    name,
    userEmail,
    message,
    lunarMonth,
    lunarDay,
    isLeapMonth,
    remindTime,
  }
}

function handleListAction(event) {
  const button = event.target.closest('button[data-action]')
  if (!button) return

  const { action, id } = button.dataset
  if (!id) return

  if (action === 'edit') {
    startEdit(id)
  } else if (action === 'delete') {
    deleteBirthday(id)
  }
}

function toggleTimePanel(event) {
  event.stopPropagation()
  if (!dom.timePanel || !dom.timeDisplay) return
  const isOpen = !dom.timePanel.hidden
  if (isOpen) {
    closeTimePanel()
  } else {
    openTimePanel()
  }
}

function handleTimeDisplayKeydown(event) {
  if (event.key === 'Enter' || event.key === ' ') {
    event.preventDefault()
    toggleTimePanel(event)
  }
}

function handleTimePanelClick(event) {
  const target = event.target
  if (!(target instanceof Element)) return

  const preset = target.closest('.time-option')
  if (preset && preset.dataset.time) {
    setTimeFromString(preset.dataset.time)
    closeTimePanel()
    return
  }

  const item = target.closest('.time-item')
  if (!item) return
  const { unit, value } = item.dataset
  if (!unit || !value) return

  const current = parseTime(dom.remindTime.value || DEFAULT_TIME)
  const hour = unit === 'hour' ? value : current.hour
  const minute = unit === 'minute' ? value : current.minute
  setTimeFromString(`${hour}:${minute}`)
}

function handleTimeOutsideClick(event) {
  if (!dom.timePanel || dom.timePanel.hidden) return
  const target = event.target
  if (!(target instanceof Element)) return
  if (dom.timePicker && dom.timePicker.contains(target)) return
  closeTimePanel()
}

function handleTimeEscape(event) {
  if (event.key !== 'Escape') return
  closeTimePanel()
}

function openTimePanel() {
  if (!dom.timePanel || !dom.timeDisplay) return
  dom.timePanel.hidden = false
  dom.timeDisplay.setAttribute('aria-expanded', 'true')
}

function closeTimePanel() {
  if (!dom.timePanel || !dom.timeDisplay) return
  dom.timePanel.hidden = true
  dom.timeDisplay.setAttribute('aria-expanded', 'false')
}

function startEdit(id) {
  const item = state.birthdays.find(entry => entry.id === id)
  if (!item) {
    setStatus('error', '未找到该提醒记录')
    return
  }

  state.editingId = id
  dom.nameInput.value = item.name || ''
  dom.emailInput.value = item.userEmail || ''
  dom.messageInput.value = item.message || ''
  dom.lunarMonth.value = item.lunarMonth || 1
  dom.lunarDay.value = item.lunarDay || 1
  dom.isLeapMonth.checked = Number(item.isLeapMonth) === 1 || item.isLeapMonth === true
  setTimeFromString(item.remindTime || DEFAULT_TIME)

  dom.addButton.hidden = true
  dom.updateButton.hidden = false
  dom.cancelButton.textContent = '取消编辑'
  dom.formTitle.textContent = '编辑生日提醒'
  dom.formHint.textContent = '修改信息后保存更新，提醒时间将重新计算。'

  dom.formCard.scrollIntoView({ behavior: 'smooth', block: 'start' })
}

async function deleteBirthday(id) {
  const confirmed = window.confirm('确定要删除该提醒吗？此操作无法撤销。')
  if (!confirmed) return

  setBusy(true)
  try {
    const response = await fetch(`/api/birthdays/${id}`, { method: 'DELETE', credentials: 'same-origin' })
    if (response.status === 401) {
      showLogin()
      throw new Error('请先登录')
    }
    if (!response.ok) {
      const detail = await safeReadError(response)
      throw new Error(detail || '删除失败')
    }

    delete state.cache[id]
    persistCache()
    if (state.editingId === id) {
      resetForm()
    }
    setStatus('success', '提醒已删除')
    await loadBirthdays({ showStatus: false })
  } catch (error) {
    setStatus('error', error.message)
  } finally {
    setBusy(false)
  }
}

function resetForm(options = {}) {
  const { clearStatus = false } = options
  state.editingId = null
  dom.birthdayForm.reset()
  setTimeFromString(DEFAULT_TIME)
  dom.addButton.hidden = false
  dom.updateButton.hidden = true
  dom.cancelButton.textContent = '清空表单'
  dom.formTitle.textContent = '新建生日提醒'
  dom.formHint.textContent = '填写寿星信息、农历生日与提醒内容，系统自动计算下一次提醒。'
  if (clearStatus) {
    clearStatusMessage()
  }
}

function setTimeFromString(value) {
  const { hour, minute } = parseTime(value || DEFAULT_TIME)
  const normalized = `${hour}:${minute}`
  if (dom.remindTime) {
    dom.remindTime.value = normalized
  }
  syncTimeOptions(normalized)
}

function syncTimeOptions(value) {
  const normalized = normalizeTime(value) || DEFAULT_TIME
  const { hour, minute } = parseTime(normalized)
  let hasMatch = COMMON_TIMES.includes(normalized)

  dom.timeOptions.forEach(button => {
    const isActive = button.dataset.time === normalized
    button.classList.toggle('active', isActive)
  })

  if (dom.timePicker) {
    dom.timePicker.classList.toggle('custom', !hasMatch)
  }

  syncDateTimeDisplay(normalized)
  if (dom.timeBadge) {
    dom.timeBadge.textContent = hasMatch ? `常用时间 ${normalized}` : `自定义 ${normalized}`
  }
  highlightTimeList(dom.hourList, hour)
  highlightTimeList(dom.minuteList, minute)
}

function syncDateTimeDisplay(timeValue) {
  if (!dom.timeText) return
  const normalized = normalizeTime(timeValue || dom.remindTime.value) || DEFAULT_TIME
  const month = dom.lunarMonth && dom.lunarMonth.value ? `${dom.lunarMonth.value}月` : '月份未选'
  const day = dom.lunarDay && dom.lunarDay.value ? `${dom.lunarDay.value}日` : '日期未选'
  const leap = dom.isLeapMonth && dom.isLeapMonth.checked ? '闰' : ''
  dom.timeText.textContent = `农历 ${leap}${month}${day} · ${normalized}`
}

function highlightTimeList(container, value) {
  if (!container) return
  container.querySelectorAll('.time-item').forEach(item => {
    item.classList.toggle('active', item.dataset.value === value)
  })
}

function setBusy(isBusy) {
  state.busy = isBusy
  dom.loginButton.disabled = isBusy
  dom.changePasswordButton.disabled = isBusy
  dom.addPasskeyButton.disabled = isBusy
  dom.addButton.disabled = isBusy
  dom.updateButton.disabled = isBusy
  dom.cancelButton.disabled = isBusy
  dom.refreshButton.disabled = isBusy
}

function setLoginBusy(isBusy) {
  state.busy = isBusy
  dom.loginButton.disabled = isBusy
  dom.passkeyLoginButton.disabled = isBusy
}

function setLoginStatus(type, message) {
  if (!message) {
    dom.loginStatus.textContent = ''
    dom.loginStatus.dataset.state = ''
    dom.loginStatus.classList.remove('visible')
    return
  }
  dom.loginStatus.textContent = message
  dom.loginStatus.dataset.state = type
  dom.loginStatus.classList.add('visible')
}

function setPasswordStatus(type, message) {
  if (!message) {
    dom.passwordStatus.textContent = ''
    dom.passwordStatus.dataset.state = ''
    dom.passwordStatus.classList.remove('visible')
    return
  }
  dom.passwordStatus.textContent = message
  dom.passwordStatus.dataset.state = type
  dom.passwordStatus.classList.add('visible')
}

function setStatus(type, message) {
  clearTimeout(statusTimer)
  if (!message) {
    clearStatusMessage()
    return
  }

  dom.statusToast.textContent = message
  dom.statusToast.dataset.state = type
  dom.statusToast.classList.add('visible')

  statusTimer = setTimeout(() => {
    if (!state.busy) {
      clearStatusMessage()
    }
  }, 4000)
}

function clearStatusMessage() {
  dom.statusToast.textContent = ''
  dom.statusToast.dataset.state = ''
  dom.statusToast.classList.remove('visible')
}

function updateCache(payload, id) {
  const cacheId = id || null
  if (!cacheId) {
    return
  }

  state.cache[cacheId] = {
    userEmail: payload.userEmail,
    message: payload.message,
  }
  persistCache()
}

function loadCache() {
  try {
    const raw = localStorage.getItem(STORAGE_KEY)
    if (!raw) return {}
    const parsed = JSON.parse(raw)
    return parsed && typeof parsed === 'object' ? parsed : {}
  } catch (error) {
    return {}
  }
}

function persistCache() {
  localStorage.setItem(STORAGE_KEY, JSON.stringify(state.cache))
}

function loadViewMode() {
  try {
    return localStorage.getItem(VIEW_KEY) === 'card' ? 'card' : 'table'
  } catch (error) {
    return 'table'
  }
}

function persistViewMode() {
  try {
    localStorage.setItem(VIEW_KEY, state.viewMode)
  } catch (error) {
    // Ignore storage failures so the list remains usable in restricted browsers.
  }
}

function formatLunar(item) {
  const month = item.lunarMonth ? `${item.lunarMonth}月` : '农历月未填'
  const day = item.lunarDay ? `${item.lunarDay}日` : '农历日未填'
  const leap = Number(item.isLeapMonth) === 1 ? '（闰月）' : ''
  return `农历 ${month}${day}${leap}`
}

function formatDate(value) {
  if (!value) return '未计算'
  const date = toDate(value)
  if (!date) return value
  return date.toLocaleString('zh-CN', {
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
  })
}

function formatCountdown(value) {
  const date = toDate(value)
  if (!date) return '未计算'
  const diffMs = date.getTime() - Date.now()
  const diffDays = Math.ceil(diffMs / (1000 * 60 * 60 * 24))
  if (diffDays < 0) return '已过期'
  if (diffDays === 0) return '今天'
  return `还有 ${diffDays} 天`
}

function isUpcomingWithin(value, days) {
  const date = toDate(value)
  if (!date) return false
  const diffMs = date.getTime() - Date.now()
  const diffDays = Math.ceil(diffMs / (1000 * 60 * 60 * 24))
  return diffDays >= 0 && diffDays <= days
}

function parseTime(value) {
  const normalized = normalizeTime(value)
  if (!normalized) {
    return { hour: DEFAULT_TIME.slice(0, 2), minute: DEFAULT_TIME.slice(3, 5) }
  }
  const [hour, minute] = normalized.split(':')
  return { hour, minute }
}

function normalizeTime(value) {
  if (!value) return ''
  const match = String(value).match(/^(\d{1,2}):(\d{2})/)
  if (!match) return ''
  let hour = Number(match[1])
  let minute = Number(match[2])
  if (!Number.isFinite(hour) || !Number.isFinite(minute)) return ''
  hour = Math.min(Math.max(hour, 0), 23)
  minute = Math.min(Math.max(minute, 0), 59)
  return `${String(hour).padStart(2, '0')}:${String(minute).padStart(2, '0')}`
}

function toDate(value) {
  if (!value) return null
  const iso = String(value).includes('T') ? String(value) : String(value).replace(' ', 'T')
  const date = new Date(iso)
  if (Number.isNaN(date.getTime())) return null
  return date
}

function isValidEmail(email) {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)
}

function escapeHTML(text) {
  return String(text)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;')
}
