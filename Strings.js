// Interface text in English and Russian; Russian when the system locale is Russian.
var TEXT = {
  ask:          ["Ask Claude", "Спросить Claude"],
  app:          ["Application", "Приложение"],
  placeholder:  ["Find an app or file, or ask Claude", "Найти приложение, файл или спросить Claude"],
  answering:    ["Claude is answering…", "Claude отвечает…"],
  followUp:     ["Ask a follow-up…", "Уточнить вопрос…"],
  hintAsk:      ["↵ ask", "↵ спросить"],
  hintOpen:     ["↵ open", "↵ открыть"],
  footSearch:   ["↵ open · Ctrl+↵ ask Claude · Alt+↵ folder · Esc clear",
                 "↵ открыть · Ctrl+↵ спросить Claude · Alt+↵ папка · Esc очистить"],
  footAnswer:   ["↵ follow up · Ctrl+C copy · Ctrl+N new · Esc back",
                 "↵ уточнить · Ctrl+C копировать · Ctrl+N заново · Esc назад"],
  footStop:     ["Esc stop", "Esc остановить"],
  copied:       ["Answer copied", "Ответ скопирован"],
  linkBlocked:  ["Won't open: ", "Ссылка не откроется: "],
  interrupted:  ["Interrupted", "Прервано"],
  stopped:      ["Stopped", "Остановлено"],
  empty:        ["Empty answer", "Пустой ответ"],
  exitCode:     ["claude exited with code ", "claude завершился с кодом "],
  errFailed:    ["Claude couldn't answer", "Claude не смог ответить"],
  errAuth:      ["Claude isn't signed in. Run claude in a terminal and log in.",
                 "Claude не авторизован. Запусти claude в терминале и войди."],
  errLimit:     ["Claude usage limit reached: ", "Лимит подписки Claude исчерпан: "],
  errMissing:   ["The claude CLI wasn't found in PATH.", "Не найден claude CLI в PATH."],
  hintCopy:     ["↵ copy", "↵ копировать"],
  hintSwitch:   ["↵ switch", "↵ перейти"],
  hintRun:      ["↵ run", "↵ выполнить"],
  calcSub:      ["Calculator · ↵ copies the result", "Калькулятор · ↵ копирует результат"],
  window:       ["Open window", "Открытое окно"],
  binding:      ["Keybinding", "Сочетание клавиш"],
  workspace:    ["workspace ", "рабочий стол "],
  launching:    ["Launching ", "Запуск "],
  limitShort:   ["5h ", "5ч "],
  modelHint:    ["Ctrl+M or click: switch model", "Ctrl+M или клик: сменить модель"],
  widgetTip:    ["OmaLight · Alt+Space", "OmaLight · Alt+Space"],
  limitSession: ["Claude session (5h): ", "Сессия Claude (5ч): "],
  limitWeek:    ["Claude week: ", "Неделя Claude: "]
}

function isRussian(localeName) {
  return String(localeName || "").toLowerCase().indexOf("ru") === 0
}

function tr(key, ru) {
  var pair = TEXT[key]
  return pair ? pair[ru ? 1 : 0] : key
}

if (typeof module !== "undefined") module.exports = { TEXT: TEXT, isRussian: isRussian, tr: tr }
