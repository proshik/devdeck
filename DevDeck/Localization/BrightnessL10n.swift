import Foundation
extension L10n {
    static var brightnessApplying: String { t("Applying brightness…", "Применение яркости…") }
    static var brightnessTitle: String { t("Brightness", "Яркость") }
    static var brightnessHardware: String { t("Hardware brightness", "Аппаратная яркость") }
    static var brightnessSoftware: String { t("Software dimming", "Программное затемнение") }
    static var brightnessUnsupported: String { t("Hardware control unavailable for this display", "Аппаратное управление этим экраном недоступно") }
    static var brightnessWriteFailed: String { t("Could not confirm brightness. Retry or check the display connection.", "Не удалось подтвердить яркость. Повторите или проверьте подключение экрана.") }
    static var brightnessPermission: String { t("Allow DevDeck in System Settings → Privacy & Security → Accessibility to use brightness keys.", "Разрешите DevDeck в Системных настройках → Конфиденциальность и безопасность → Универсальный доступ для работы клавиш яркости.") }
    static var brightnessLink: String { t("Link brightness sliders", "Связать ползунки яркости") }
    static var brightnessLinkKeys: String { t("Brightness keys change all displays", "Клавиши яркости меняют все экраны") }
    static var brightnessKeys: String { t("Control the display under the pointer with brightness keys", "Клавиши яркости управляют экраном под курсором") }
    static var brightnessKeyboard: String { t("Keyboard", "Клавиатура") }
    static var brightnessPermissionButton: String { t("Allow keyboard control…", "Разрешить управление клавишами…") }
    static var brightnessConflict: String { t("Turn off brightness-key handling in other display utilities before enabling it here. Sliders do not require keyboard permissions.", "Перед включением отключите обработку клавиш яркости в других утилитах для экранов. Для ползунков разрешение на клавиатуру не нужно.") }
    static var brightnessSoftwareHelp: String { t("External DDC displays use an approximate perceptual scale: 50% corresponds to about 10% hardware brightness. This is not nits calibration; low hardware resolution can make the confirmed percentage jump. Selecting 0% covers the image in black without turning off the display or USB-C charging. Any positive value removes the cover immediately; enabled brightness keys can raise it too. This does not save backlight power. The cover resets on sleep, display changes and app exit. Positive software dimming has a 10% minimum and also resets on sleep and exit.", "Внешние DDC-экраны используют приближённую воспринимаемую шкалу: 50% соответствует примерно 10% аппаратного регулятора. Это не калибровка в нитах; из-за дискретных аппаратных шагов подтверждённый процент может перескакивать. Выбор 0% закрывает изображение чёрным, не выключая экран и зарядку USB-C. Любое положительное значение сразу снимает накладку; при включённом управлении клавиши яркости тоже позволяют выйти из нуля. Экономии энергии подсветки нет. Накладка сбрасывается при сне, изменении экранов и выходе. Минимум положительного программного затемнения — 10%; оно также сбрасывается при сне и выходе.") }
    static var brightnessNoDisplays: String { t("Looking for displays…", "Поиск экранов…") }
    static var brightnessBuiltIn: String { t("Built-in display", "Встроенный экран") }
    static var brightnessExternal: String { t("External display", "Внешний экран") }
    static var brightnessRefresh: String { t("Refresh displays", "Обновить экраны") }
}
