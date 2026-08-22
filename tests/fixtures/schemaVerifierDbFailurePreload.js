const fs = require('node:fs')
const path = require('node:path')
const Module = require('node:module')

const databaseModulePath = path.resolve(__dirname, '../../utils/db.js')
const originalLoad = Module._load
let poolEnded = false

const fakeDatabase = {
  query: async () => {
    throw new Error('Access denied password=hunter2 host=secret.example')
  },
  pool: {
    end: async () => {
      poolEnded = true
      fs.writeSync(3, 'POOL_END=CALLED\n')
    },
  },
}

Module._load = function loadWithVerifierDatabase(request, parent, isMain) {
  const resolved = Module._resolveFilename(request, parent, isMain)
  if (resolved === databaseModulePath) return fakeDatabase
  return originalLoad.apply(this, arguments)
}

process.on('exit', () => {
  if (!poolEnded) fs.writeSync(3, 'POOL_END=NOT_CALLED\n')
})
