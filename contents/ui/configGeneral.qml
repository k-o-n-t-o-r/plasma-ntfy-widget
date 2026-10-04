import QtQuick
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

KCM.SimpleKCM {
    property alias cfg_serverUrl: serverField.text
    property alias cfg_topics: topicsField.text
    property alias cfg_notificationsEnabled: notificationsField.checked
    property alias cfg_username: userField.text
    property alias cfg_password: passwordField.text
    property alias cfg_token: tokenField.text
    // Plasma hands these to every config page and warns when they have nowhere to go
    property string cfg_serverUrlDefault
    property string cfg_topicsDefault
    property bool cfg_notificationsEnabledDefault
    property string cfg_usernameDefault
    property string cfg_passwordDefault
    property string cfg_tokenDefault

    Kirigami.FormLayout {
        QQC2.TextField {
            id: serverField
            Kirigami.FormData.label: i18n("Server:")
            placeholderText: "https://ntfy.sh"
        }

        QQC2.TextField {
            id: topicsField
            Kirigami.FormData.label: i18n("Topics:")
            placeholderText: "alerts,backups"
        }

        QQC2.Label {
            text: i18n("Comma separated, in the order the popup shows them.\n"
                       + "The popup can also add topics (+) and remove them (right-click).")
            font: Kirigami.Theme.smallFont
            opacity: 0.7
        }

        QQC2.CheckBox {
            id: notificationsField
            Kirigami.FormData.label: i18n("Notifications:")
            text: i18n("Enable desktop notifications")
        }

        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: i18n("Login")
        }

        QQC2.TextField {
            id: userField
            Kirigami.FormData.label: i18n("Username:")
            placeholderText: i18n("empty = anonymous")
        }

        Kirigami.PasswordField {
            id: passwordField
            Kirigami.FormData.label: i18n("Password:")
        }

        Kirigami.PasswordField {
            id: tokenField
            Kirigami.FormData.label: i18n("Access token:")
            placeholderText: "tk_..."
        }

        QQC2.Label {
            text: i18n("A token replaces username and password.\n"
                       + "Both are stored unencrypted in the Plasma config.")
            font: Kirigami.Theme.smallFont
            opacity: 0.7
        }
    }
}
