const AUTH_ROUTE_PATHS = Object.freeze({
  login: '/login',
  refresh: '/refresh',
  revoke: '/revoke',
  devices: '/devices',
})

const SYNC_ROUTE_PATHS = Object.freeze({
  snapshot: '/snapshot',
  push: '/push',
  pull: '/pull',
})

const ERROR_DEFINITIONS = Object.freeze({
  apiRateLimited: Object.freeze({ code: 'api_rate_limited', status: 429 }),
  authRequired: Object.freeze({ code: 'mobile_auth_required', status: 401 }),
  accessExpired: Object.freeze({ code: 'mobile_access_expired', status: 401 }),
  invalidLogin: Object.freeze({ code: 'invalid_mobile_login', status: 400 }),
  authUnconfigured: Object.freeze({ code: 'mobile_auth_unconfigured', status: 503 }),
  loginInvalid: Object.freeze({ code: 'mobile_login_invalid', status: 401 }),
  loginRateLimited: Object.freeze({ code: 'mobile_login_rate_limited', status: 429 }),
  invalidRefresh: Object.freeze({ code: 'invalid_mobile_refresh', status: 400 }),
  refreshInvalid: Object.freeze({ code: 'mobile_refresh_invalid', status: 401 }),
  invalidDevice: Object.freeze({ code: 'invalid_mobile_device', status: 400 }),
  deviceNotFound: Object.freeze({ code: 'mobile_device_not_found', status: 404 }),
  invalidCursor: Object.freeze({ code: 'invalid_cursor', status: 400 }),
  invalidLimit: Object.freeze({ code: 'invalid_limit', status: 400 }),
  invalidBirthdayPayload: Object.freeze({ code: 'invalid_birthday_payload', status: 400 }),
  tooManyOperations: Object.freeze({ code: 'too_many_operations', status: 400 }),
  payloadTooLarge: Object.freeze({ code: 'payload_too_large', status: 413 }),
  serverError: Object.freeze({ code: 'server_error', status: 500 }),
})

const MOBILE_ERROR_CODES = Object.freeze(Object.fromEntries(
  Object.entries(ERROR_DEFINITIONS).map(([name, definition]) => [name, definition.code]),
))

const ROUTES = Object.freeze({
  login: Object.freeze({ method: 'POST', path: `/auth${AUTH_ROUTE_PATHS.login}`, auth: 'none' }),
  refresh: Object.freeze({ method: 'POST', path: `/auth${AUTH_ROUTE_PATHS.refresh}`, auth: 'none' }),
  revoke: Object.freeze({ method: 'POST', path: `/auth${AUTH_ROUTE_PATHS.revoke}`, auth: 'bearer' }),
  devices: Object.freeze({ method: 'GET', path: `/auth${AUTH_ROUTE_PATHS.devices}`, auth: 'bearer' }),
  snapshot: Object.freeze({ method: 'GET', path: `/sync${SYNC_ROUTE_PATHS.snapshot}`, auth: 'bearer' }),
  push: Object.freeze({ method: 'POST', path: `/sync${SYNC_ROUTE_PATHS.push}`, auth: 'bearer' }),
  pull: Object.freeze({ method: 'GET', path: `/sync${SYNC_ROUTE_PATHS.pull}`, auth: 'bearer' }),
})

const DTO_FIELDS = Object.freeze({
  birthday: Object.freeze([
    'id', 'name', 'lunarMonth', 'lunarDay', 'isLeapMonth', 'reminderTimeMinutes',
    'notifyDayBefore', 'notifySameDay', 'emailEnabled', 'emailAddress', 'emailMessage',
    'nextSolarDate', 'version', 'createdAt', 'updatedAt', 'deletedAt',
  ]),
  birthdayMutation: Object.freeze([
    'id', 'name', 'lunarMonth', 'lunarDay', 'isLeapMonth', 'reminderTimeMinutes',
    'notifyDayBefore', 'notifySameDay', 'emailEnabled', 'emailAddress', 'emailMessage',
  ]),
  loginRequest: Object.freeze(['username', 'password', 'deviceId', 'deviceName']),
  tokenResponse: Object.freeze([
    'deviceId', 'accessToken', 'accessExpiresAt', 'refreshToken', 'refreshExpiresAt',
  ]),
  device: Object.freeze(['deviceId', 'deviceName', 'createdAt', 'lastUsedAt', 'revokedAt']),
  pushOperation: Object.freeze(['operationId', 'entityId', 'type', 'baseVersion', 'payload']),
  pullChange: Object.freeze(['seq', 'operation', 'record']),
})

const MOBILE_API_CONTRACT = Object.freeze({
  basePath: '/api/mobile',
  apiMountPath: '/mobile',
  mounts: Object.freeze({ auth: '/auth', sync: '/sync' }),
  routes: ROUTES,
  endpoints: Object.freeze(Object.fromEntries(
    Object.entries(ROUTES).map(([name, route]) => [name, route.path]),
  )),
  limits: Object.freeze({
    jsonBodyLimit: '64kb',
    jsonBodyBytes: 64 * 1024,
    pushCompactJSONBytes: 60 * 1024,
    pushOperations: 50,
    pullDefault: 200,
    pullMaximum: 200,
    enabledEmailStorageBytes: 8192,
    signedInt64Maximum: '9223372036854775807',
    accessTokenTTLSeconds: 15 * 60,
    refreshTokenTTLSeconds: 180 * 24 * 60 * 60,
  }),
  dtoFields: DTO_FIELDS,
  errors: Object.freeze(Object.fromEntries(
    Object.values(ERROR_DEFINITIONS).map(definition => [definition.code, definition]),
  )),
  errorCodes: Object.freeze(Object.values(MOBILE_ERROR_CODES)),
})

module.exports = {
  AUTH_ROUTE_PATHS,
  MOBILE_API_CONTRACT,
  MOBILE_ERROR_CODES,
  SYNC_ROUTE_PATHS,
}
