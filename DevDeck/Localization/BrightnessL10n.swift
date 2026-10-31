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
    static var brightnessSoftwareHelp: String { t("Software dimming overlays the image; it does not lower the backlight or power use. Minimum 10%. It resets on sleep and app exit.", "Программное затемнение накладывается на изображение; подсветка и энергопотребление не уменьшаются. Минимум 10%. Сбрасывается при засыпании и выходе из приложения.") }
    static var brightnessNoDisplays: String { t("Looking for displays…", "Поиск экранов…") }
    static var brightnessBuiltIn: String { t("Built-in display", "Встроенный экран") }
    static var brightnessExternal: String { t("External display", "Внешний экран") }
    static var brightnessRefresh: String { t("Refresh displays", "Обновить экраны") }
}
