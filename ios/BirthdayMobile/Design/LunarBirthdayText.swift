import BirthdayCore

enum LunarBirthdayText {
  static let months = [
    "正月", "二月", "三月", "四月", "五月", "六月",
    "七月", "八月", "九月", "十月", "冬月", "腊月",
  ]
  static let days = [
    "初一", "初二", "初三", "初四", "初五", "初六", "初七", "初八", "初九", "初十",
    "十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九", "二十",
    "廿一", "廿二", "廿三", "廿四", "廿五", "廿六", "廿七", "廿八", "廿九", "三十",
  ]

  static func string(for birthday: LunarBirthday) -> String {
    let month = months.indices.contains(birthday.month - 1)
      ? months[birthday.month - 1] : "第\(birthday.month)月"
    let day = days.indices.contains(birthday.day - 1)
      ? days[birthday.day - 1] : "第\(birthday.day)日"
    return "\(birthday.isLeapMonth ? "闰" : "")\(month)\(day)"
  }
}
