// 获取版本列表
async function loadVersions() {
  try {
    const response = await fetch('/api/version/apk-versions')
    if (!response.ok) {
      throw new Error('加载版本列表失败')
    }
    const versions = await response.json()
    const tbody = document.querySelector('#versionTable tbody')
    tbody.innerHTML = versions
      .map(
        version => `
        <tr id="versionRow-${version.id}">
          <td class="versionCode">${version.version_code}</td>
          <td class="versionName">${version.version_name}</td>
          <td class="packageName">${version.package_name}</td>
          <td class="fileSize">${(version.file_size / 1024 / 1024).toFixed(2)} MB</td>
          <td class="isForceUpdate">${version.is_force_update ? '是' : '否'}</td>
          <td class="minAndroidVersion">${version.min_android_version || '无'}</td>
          <td>
            <button class="deleteButton" data-id="${version.id}">删除</button>
            <button class="editButton" data-id="${version.id}">编辑</button>
          </td>
        </tr>
      `
      )
      .join('')

    // 添加编辑按钮的事件监听
    const editButtons = document.querySelectorAll('.editButton')
    editButtons.forEach(button => {
      button.addEventListener('click', () => {
        const id = button.getAttribute('data-id')
        editVersion(id) // 调用编辑函数
      })
    })

    // 添加删除按钮的事件监听
    const deleteButtons = document.querySelectorAll('.deleteButton')
    deleteButtons.forEach(button => {
      button.addEventListener('click', () => {
        const id = button.getAttribute('data-id')
        deleteVersion(id) // 调用删除函数
      })
    })
  } catch (error) {
    alert('加载版本列表失败: ' + error.message)
  }
}

// 上传新版本
document.getElementById('addButton').addEventListener('click', async () => {
  const formData = new FormData()
  formData.append('version_code', document.getElementById('versionCode').value)
  formData.append('version_name', document.getElementById('versionName').value)
  formData.append('package_name', document.getElementById('packageName').value)
  formData.append('apkFile', document.getElementById('apkFile').files[0])
  formData.append('release_notes', document.getElementById('releaseNotes').value)
  formData.append('is_force_update', document.getElementById('isForceUpdate').checked ? 1 : 0)
  formData.append('min_android_version', document.getElementById('minAndroidVersion').value)

  try {
    const response = await fetch('/api/version/apk-versions', {
      method: 'POST',
      body: formData,
    })

    if (!response.ok) {
      throw new Error('上传失败')
    }

    alert('新增成功')
    loadVersions() // 刷新版本列表
  } catch (error) {
    alert('操作失败: ' + error.message)
  }
})

// 编辑版本
async function editVersion(id) {
  const versionRow = document.querySelector(`#versionRow-${id}`)

  if (!versionRow) {
    alert('版本信息未找到')
    return
  }

  // 从当前行中提取版本信息
  const versionCode = versionRow.querySelector('.versionCode').textContent
  const versionName = versionRow.querySelector('.versionName').textContent
  const packageName = versionRow.querySelector('.packageName').textContent
  const releaseNotes = versionRow.querySelector('.releaseNotes')
    ? versionRow.querySelector('.releaseNotes').textContent
    : ''
  const isForceUpdate = versionRow.querySelector('.isForceUpdate').textContent === '是'
  const minAndroidVersion = versionRow.querySelector('.minAndroidVersion').textContent

  // 填充表单数据
  document.getElementById('versionCode').value = versionCode
  document.getElementById('versionName').value = versionName
  document.getElementById('packageName').value = packageName
  document.getElementById('releaseNotes').value = releaseNotes || ''
  document.getElementById('isForceUpdate').checked = isForceUpdate
  document.getElementById('minAndroidVersion').value = minAndroidVersion || ''

  // 显示更新按钮
  document.getElementById('addButton').style.display = 'none'
  document.getElementById('updateButton').style.display = 'inline-block'

  // 更新按钮点击时的操作
  document.getElementById('updateButton').addEventListener('click', async () => {
    const formData = new FormData()
    formData.append('version_code', document.getElementById('versionCode').value)
    formData.append('version_name', document.getElementById('versionName').value)
    formData.append('package_name', document.getElementById('packageName').value)
    formData.append('release_notes', document.getElementById('releaseNotes').value)
    formData.append('is_force_update', document.getElementById('isForceUpdate').checked ? 1 : 0)
    formData.append('min_android_version', document.getElementById('minAndroidVersion').value)

    // 检查是否有新的 APK 文件上传
    const apkFile = document.getElementById('apkFile').files[0]
    if (apkFile) {
      formData.append('apkFile', apkFile)
    }

    try {
      const response = await fetch(`/api/version/apk-versions/${id}`, {
        method: 'PUT',
        body: formData,
      })

      if (!response.ok) {
        throw new Error('更新失败')
      }

      alert('更新成功')
      loadVersions() // 刷新版本列表
    } catch (error) {
      alert('操作失败: ' + error.message)
    }
  })
}

// 监听APK文件上传并填充包名（去掉 .apk 后缀）
document.getElementById('apkFile').addEventListener('change', () => {
  const apkFile = document.getElementById('apkFile').files[0]
  if (apkFile) {
    let fileName = apkFile.name
    // 去掉 .apk 后缀
    fileName = fileName.replace(/\.apk$/, '')
    document.getElementById('packageName').value = fileName // 将文件名填充到包名字段
  }
})

// 删除版本
async function deleteVersion(id) {
  // 弹出确认框，要求用户确认删除
  const confirmDelete = window.confirm('确定要删除该版本吗？')

  if (confirmDelete) {
    try {
      const response = await fetch(`/api/version/apk-versions/${id}`, {
        method: 'DELETE',
      })

      if (!response.ok) {
        throw new Error('删除失败')
      }

      alert('删除成功')
      loadVersions() // 刷新版本列表
    } catch (error) {
      alert('删除失败: ' + error.message)
    }
  } else {
    console.log('删除操作已取消')
  }
}

// 初始化加载版本列表
loadVersions()
