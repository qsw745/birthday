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

const MOBILE_ERROR_CODES = Object.freeze({
  authRequired: 'mobile_auth_required',
  accessExpired: 'mobile_access_expired',
  invalidLogin: 'invalid_mobile_login',
  authUnconfigured: 'mobile_auth_unconfigured',
  loginInvalid: 'mobile_login_invalid',
  loginRateLimited: 'mobile_login_rate_limited',
  invalidRefresh: 'invalid_mobile_refresh',
  refreshInvalid: 'mobile_refresh_invalid',
  invalidDevice: 'invalid_mobile_device',
  deviceNotFound: 'mobile_device_not_found',
  invalidCursor: 'invalid_cursor',
  invalidLimit: 'invalid_limit',
  invalidBirthdayPayload: 'invalid_birthday_payload',
  tooManyOperations: 'too_many_operations',
  payloadTooLarge: 'payload_too_large',
  serverError: 'server_error',
})

const MOBILE_API_CONTRACT = Object.freeze({
  basePath: '/api/mobile',
  apiMountPath: '/mobile',
  mounts: Object.freeze({ auth: '/auth', sync: '/sync' }),
  endpoints: Object.freeze({
    login: `/auth${AUTH_ROUTE_PATHS.login}`,
    refresh: `/auth${AUTH_ROUTE_PATHS.refresh}`,
    revoke: `/auth${AUTH_ROUTE_PATHS.revoke}`,
    devices: `/auth${AUTH_ROUTE_PATHS.devices}`,
    snapshot: `/sync${SYNC_ROUTE_PATHS.snapshot}`,
    push: `/sync${SYNC_ROUTE_PATHS.push}`,
    pull: `/sync${SYNC_ROUTE_PATHS.pull}`,
  }),
  errorCodes: Object.freeze(Object.values(MOBILE_ERROR_CODES)),
})

module.exports = {
  AUTH_ROUTE_PATHS,
  MOBILE_API_CONTRACT,
  MOBILE_ERROR_CODES,
  SYNC_ROUTE_PATHS,
}
