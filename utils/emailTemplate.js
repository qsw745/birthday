// utils/emailTemplate.js
const moment = require('moment')

function escapeHtml(value) {
  return String(value ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;')
}

const FONT_STACK = "-apple-system,BlinkMacSystemFont,'PingFang SC','Hiragino Sans GB','Microsoft YaHei',sans-serif"

// 生日提醒邮件 HTML（邮件客户端兼容：table 布局 + 内联样式）
function buildBirthdayEmailHtml({ name, message, remind_time }) {
  const safeName = escapeHtml(name)
  const safeMessage = escapeHtml(message).replace(/\n/g, '<br>')
  const dateText = moment(remind_time).locale('zh-cn').format('YYYY年M月D日 dddd HH:mm')

  const messageBlock = safeMessage
    ? `<div style="margin-top:20px;background:#fdf3ec;border-left:4px solid #ff8a5c;border-radius:0 8px 8px 0;padding:14px 16px;font:400 15px/1.8 ${FONT_STACK};color:#5c4a3a;">${safeMessage}</div>`
    : ''

  return `
<div style="display:none;max-height:0;overflow:hidden;mso-hide:all;">${safeName}的生日快到了，记得送上祝福！</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background-color:#faf6f1;">
  <tr>
    <td align="center" style="padding:32px 16px;">
      <table role="presentation" cellpadding="0" cellspacing="0" border="0" style="width:100%;max-width:560px;background:#ffffff;border-radius:16px;overflow:hidden;box-shadow:0 2px 12px rgba(60,40,20,0.08);">
        <tr>
          <td align="center" bgcolor="#ff8a5c" style="background-color:#ff8a5c;background-image:linear-gradient(135deg,#ff8a5c 0%,#ff5e7e 100%);padding:36px 32px 32px;">
            <div style="font-size:46px;line-height:1;">&#127874;</div>
            <div style="margin-top:12px;font:600 22px/1.4 ${FONT_STACK};color:#ffffff;letter-spacing:4px;">生日提醒</div>
          </td>
        </tr>
        <tr>
          <td style="padding:32px;">
            <p style="margin:0;font:600 20px/1.5 ${FONT_STACK};color:#2d2016;">${safeName} 的生日到啦&nbsp;&#127881;</p>
            <p style="margin:10px 0 0;font:400 14px/1.6 ${FONT_STACK};color:#8c7f70;">
              &#128197;&nbsp;${dateText}
            </p>
            ${messageBlock}
            <p style="margin:24px 0 0;font:400 14px/1.6 ${FONT_STACK};color:#8c7f70;">别忘了送上你的祝福～</p>
          </td>
        </tr>
        <tr>
          <td align="center" style="background:#faf6f1;padding:16px 32px;">
            <p style="margin:0;font:400 12px/1.6 ${FONT_STACK};color:#a99f93;">此邮件由生日提醒助手自动发送，请勿直接回复</p>
          </td>
        </tr>
      </table>
    </td>
  </tr>
</table>`
}

module.exports = { buildBirthdayEmailHtml, escapeHtml }
