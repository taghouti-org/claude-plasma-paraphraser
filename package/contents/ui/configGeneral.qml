import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM
import "../code/core.js" as Core

KCM.SimpleKCM {
    id: page

    property alias cfg_apiKey: keyField.text
    property string cfg_model
    property string cfg_defaultMode
    property string cfg_outputLang
    property string cfg_pasteKeys
    property alias cfg_customInstructions: customField.text
    property alias cfg_autoRun: autoRunBox.checked
    property alias cfg_saveHistory: historyBox.checked
    property string cfg_history

    property string keyStatus: ""
    property bool keyOk: false
    property bool testing: false

    function indexOfId(list, id) {
        for (let i = 0; i < list.length; i++) {
            if (list[i].id === id) return i;
        }
        return 0;
    }

    Kirigami.FormLayout {
        Item {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: "Claude API key"
        }
        RowLayout {
            Kirigami.FormData.label: "API key:"
            QQC2.TextField {
                id: keyField
                Layout.preferredWidth: Kirigami.Units.gridUnit * 18
                echoMode: showKey.checked ? TextInput.Normal : TextInput.Password
                placeholderText: "sk-ant-…"
                inputMethodHints: Qt.ImhNoPredictiveText | Qt.ImhNoAutoUppercase | Qt.ImhSensitiveData
                onTextChanged: page.keyStatus = ""
            }
            QQC2.ToolButton {
                id: showKey
                checkable: true
                icon.name: checked ? "password-show-off" : "password-show-on"
                QQC2.ToolTip.text: checked ? "Hide the key" : "Show the key"
                QQC2.ToolTip.visible: hovered
                Accessible.name: QQC2.ToolTip.text
            }
            QQC2.Button {
                text: "Test"
                enabled: !page.testing && keyField.text.trim().length > 0
                onClicked: {
                    page.testing = true;
                    page.keyStatus = "Checking…";
                    page.keyOk = false;
                    Core.testKey(keyField.text, (ok, message) => {
                        page.testing = false;
                        page.keyOk = ok;
                        page.keyStatus = message;
                    });
                }
            }
        }
        QQC2.Label {
            visible: page.keyStatus.length > 0
            text: page.keyStatus
            color: page.testing ? Kirigami.Theme.textColor : (page.keyOk ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.negativeTextColor)
            wrapMode: Text.Wrap
            Layout.maximumWidth: Kirigami.Units.gridUnit * 24
        }
        QQC2.Label {
            Layout.maximumWidth: Kirigami.Units.gridUnit * 24
            wrapMode: Text.Wrap
            font: Kirigami.Theme.smallFont
            opacity: 0.75
            textFormat: Text.StyledText
            text: "Create a key at <a href=\"https://platform.claude.com/settings/keys\">platform.claude.com → API keys</a>. "
                + "Usage is billed to your Claude Console account; a claude.ai chat subscription does not include API access. "
                + "The key is saved in this widget's settings file in your home folder and is sent only to api.anthropic.com."
            onLinkActivated: link => Qt.openUrlExternally(link)
        }

        Item {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: "Rewriting"
        }
        QQC2.ComboBox {
            Kirigami.FormData.label: "Model:"
            Layout.preferredWidth: Kirigami.Units.gridUnit * 18
            model: Core.MODELS.map(m => m.label)
            currentIndex: page.indexOfId(Core.MODELS, page.cfg_model)
            onActivated: index => page.cfg_model = Core.MODELS[index].id
        }
        QQC2.ComboBox {
            Kirigami.FormData.label: "Default mode:"
            Layout.preferredWidth: Kirigami.Units.gridUnit * 18
            model: Core.MODES.map(m => m.label + " — " + m.hint)
            currentIndex: page.indexOfId(Core.MODES, page.cfg_defaultMode)
            onActivated: index => page.cfg_defaultMode = Core.MODES[index].id
        }
        QQC2.ComboBox {
            Kirigami.FormData.label: "Output language:"
            Layout.preferredWidth: Kirigami.Units.gridUnit * 18
            model: ["Same as the original text"].concat(Core.LANGUAGES.map(l => "Always " + l))
            currentIndex: page.cfg_outputLang === "auto" ? 0 : Math.max(0, Core.LANGUAGES.indexOf(page.cfg_outputLang) + 1)
            onActivated: index => page.cfg_outputLang = index === 0 ? "auto" : Core.LANGUAGES[index - 1]
        }
        QQC2.TextArea {
            id: customField
            Kirigami.FormData.label: "Style preferences:"
            Layout.preferredWidth: Kirigami.Units.gridUnit * 18
            Layout.preferredHeight: Kirigami.Units.gridUnit * 4
            wrapMode: TextEdit.Wrap
            placeholderText: "Optional. Example: British spelling. Never use exclamation marks."
        }

        Item {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: "Behaviour"
        }
        QQC2.CheckBox {
            id: autoRunBox
            Kirigami.FormData.label: "When opened:"
            text: "Rewrite the selected text right away"
        }
        QQC2.Label {
            Layout.maximumWidth: Kirigami.Units.gridUnit * 24
            wrapMode: Text.Wrap
            font: Kirigami.Theme.smallFont
            opacity: 0.75
            text: "The text currently selected in any app is sent to Claude as soon as the widget opens. Turn this off to choose a mode first."
        }
        QQC2.ComboBox {
            Kirigami.FormData.label: "Replace pastes with:"
            Layout.preferredWidth: Kirigami.Units.gridUnit * 18
            model: Core.PASTE_KEYS.map(k => k.label)
            currentIndex: page.indexOfId(Core.PASTE_KEYS, page.cfg_pasteKeys)
            onActivated: index => page.cfg_pasteKeys = Core.PASTE_KEYS[index].id
        }
        QQC2.CheckBox {
            id: historyBox
            Kirigami.FormData.label: "History:"
            text: "Keep my last 30 rewrites"
        }
        QQC2.Button {
            text: "Clear history"
            icon.name: "edit-clear-history"
            enabled: page.cfg_history !== "[]" && page.cfg_history !== ""
            onClicked: page.cfg_history = "[]"
        }
    }
}
