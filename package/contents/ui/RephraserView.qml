// The whole popup UI. It depends only on its `cfg` object (the widget
// configuration) and a few signals, so it can also run outside plasmashell.
import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PC3
import org.kde.kquickcontrolsaddons as KQCA
import "../code/core.js" as Core

Item {
    id: view

    // Widget configuration (Plasmoid.configuration or a stand-in with the same keys).
    property var cfg
    property string apiUrl: Core.API_URL
    // Set by the host when automatic pasting failed.
    property string notice: ""

    signal configureRequested()
    // The host copies nothing itself: the view has already put `text` on the
    // clipboard. The host closes the popup and sends the paste shortcut.
    signal replaceRequested(string text)

    // ---- state
    property string mode: Core.getMode(cfg ? cfg.defaultMode : "").id
    property string outLang: cfg && (cfg.outputLang === "auto" || Core.LANGUAGES.indexOf(cfg.outputLang) !== -1) ? cfg.outputLang : "auto"
    property string status: "idle"          // idle | loading | streaming | done | error
    property string result: ""
    property string lang: ""
    property string errorMessage: ""
    property string errorCode: ""
    property bool truncated: false
    property bool autoReplace: false
    property var job: null
    property string lastCaptured: ""
    property bool showHistory: false
    property string copiedNote: ""

    readonly property bool busy: status === "loading" || status === "streaming"
    readonly property bool hasKey: !!cfg && String(cfg.apiKey || "").trim().length > 0
    readonly property bool ready: status === "done" && result.length > 0
    readonly property var historyItems: Core.parseHistory(cfg ? cfg.history : "[]")

    implicitWidth: Kirigami.Units.gridUnit * 27
    implicitHeight: Kirigami.Units.gridUnit * 31
    Layout.minimumWidth: Kirigami.Units.gridUnit * 20
    Layout.minimumHeight: Kirigami.Units.gridUnit * 24
    Layout.preferredWidth: implicitWidth
    Layout.preferredHeight: implicitHeight

    KQCA.Clipboard { id: clipboard }
    // The primary selection: whatever text is highlighted in any app.
    // (QClipboard::Mode cannot be assigned declaratively, hence onCompleted.)
    KQCA.Clipboard { id: selection }
    Component.onCompleted: selection.mode = 1 // QClipboard::Selection

    // Runs deferred work for core.js (retries with backoff, async errors).
    Timer {
        id: scheduler
        property var fn: null
        repeat: false
        onTriggered: {
            const f = fn;
            fn = null;
            if (f) f();
        }
    }
    function schedule(fn, ms) {
        scheduler.stop();
        scheduler.fn = fn;
        scheduler.interval = Math.max(1, ms);
        scheduler.start();
    }

    Timer { id: copiedTimer; interval: 1600; onTriggered: view.copiedNote = "" }

    // ---- actions

    function clipboardText(which) {
        const c = which === "selection" ? selection.content : clipboard.content;
        return typeof c === "string" ? c : "";
    }

    // Called by the host each time the popup opens. Takes the text selected in
    // whatever app the user came from; rewrites it at once when it is new.
    function captureSelection() {
        notice = "";
        const text = clipboardText("selection");
        if (!text.trim() || text === lastCaptured || text === result) return false;
        lastCaptured = text;
        setSource(text);
        if (cfg.autoRun && hasKey) run(mode);
        return true;
    }

    function setSource(text) {
        cancel();
        source.text = text;
        status = "idle";
        result = "";
        lang = "";
        showHistory = false;
    }

    function cancel() {
        if (job) {
            job.abort();
            job = null;
        }
        scheduler.stop();
        scheduler.fn = null;
        if (busy) status = result ? "done" : "idle";
    }

    // sourceOverride: rewrite this text instead of the source box (used to
    // humanize a result). The language badge always describes the original.
    function run(modeId, sourceOverride, replaceWhenDone) {
        cancel();
        mode = Core.getMode(modeId).id;
        const fromSource = sourceOverride === undefined || sourceOverride === null;
        const input = fromSource ? source.text : sourceOverride;
        result = "";
        errorMessage = "";
        errorCode = "";
        truncated = false;
        autoReplace = !!replaceWhenDone;
        notice = "";
        if (fromSource) lang = "";
        status = "loading";
        showHistory = false;

        let current = null;
        const mine = () => view.job === current;
        current = Core.rewrite({
            apiUrl: apiUrl,
            apiKey: cfg.apiKey,
            model: cfg.model,
            text: input,
            modeId: mode,
            outputLang: outLang,
            instruction: instruction.text,
            customInstructions: cfg.customInstructions,
            schedule: view.schedule
        }, {
            onLang: l => { if (mine() && fromSource && l) view.lang = l; },
            onDelta: t => { if (mine()) { view.result += t; view.status = "streaming"; } },
            onReset: () => { if (mine()) { view.result = ""; view.status = "loading"; } },
            onDone: r => {
                if (!mine()) return;
                view.job = null;
                view.result = r.text;
                if (fromSource && r.lang) view.lang = r.lang;
                view.truncated = r.truncated;
                view.status = "done";
                if (cfg.saveHistory) {
                    cfg.history = Core.pushHistory(cfg.history, {
                        ts: Date.now(), mode: view.mode, lang: r.lang,
                        source: String(input).slice(0, 2000), result: r.text.slice(0, 4000)
                    });
                }
                if (view.autoReplace && !r.truncated) view.replace();
            },
            onError: e => {
                if (!mine()) return;
                view.job = null;
                view.errorMessage = e.message;
                view.errorCode = e.code;
                view.autoReplace = false;
                view.status = "error";
            }
        });
        job = current;
    }

    function copy(text) {
        clipboard.content = text;
        copiedNote = "Copied";
        copiedTimer.restart();
    }

    // Keeps the leading and trailing whitespace of the selection so the
    // replacement drops cleanly into the surrounding text.
    function withOriginalSpacing(text) {
        const src = source.text;
        const lead = src.match(/^\s*/)[0];
        if (lead === src) return text;
        return lead + text + src.match(/\s*$/)[0];
    }

    function replace() {
        if (!ready) return;
        const text = withOriginalSpacing(result);
        clipboard.content = text;
        replaceRequested(text);
    }

    function humanize(andReplace) {
        run("humanize", ready ? result : null, andReplace);
    }

    // ---- UI

    ColumnLayout {
        anchors.fill: parent
        spacing: Kirigami.Units.smallSpacing

        RowLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing

            Kirigami.Icon {
                source: Qt.resolvedUrl("../icons/rephraser.svg")
                Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
            }
            PC3.Label {
                font.bold: true
                text: view.showHistory ? "Recent rewrites" : "Rephraser"
            }
            Rectangle {
                visible: !view.showHistory && view.lang.length > 0
                radius: height / 2
                color: Qt.alpha(Kirigami.Theme.highlightColor, 0.18)
                implicitWidth: badge.implicitWidth + Kirigami.Units.largeSpacing * 2
                implicitHeight: badge.implicitHeight + Kirigami.Units.smallSpacing
                PC3.Label {
                    id: badge
                    anchors.centerIn: parent
                    font: Kirigami.Theme.smallFont
                    color: Kirigami.Theme.textColor
                    text: view.outLang !== "auto" && view.outLang !== view.lang ? view.lang + " → " + view.outLang : view.lang
                }
                PC3.ToolTip.text: "Detected language: " + view.lang
                PC3.ToolTip.visible: badgeHover.hovered
                HoverHandler { id: badgeHover }
            }
            Item { Layout.fillWidth: true }
            PC3.ToolButton {
                icon.name: view.showHistory ? "go-previous" : "view-history"
                visible: view.showHistory || view.historyItems.length > 0
                onClicked: view.showHistory = !view.showHistory
                PC3.ToolTip.text: view.showHistory ? "Back" : "Recent rewrites"
                PC3.ToolTip.visible: hovered
                PC3.ToolTip.delay: Kirigami.Units.toolTipDelay
                Accessible.name: PC3.ToolTip.text
            }
            PC3.ToolButton {
                icon.name: "configure"
                onClicked: view.configureRequested()
                PC3.ToolTip.text: "Settings"
                PC3.ToolTip.visible: hovered
                PC3.ToolTip.delay: Kirigami.Units.toolTipDelay
                Accessible.name: "Settings"
            }
        }

        // ---------------- history page
        ColumnLayout {
            visible: view.showHistory
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: Kirigami.Units.smallSpacing

            PC3.ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                ListView {
                    id: historyList
                    clip: true
                    spacing: Kirigami.Units.smallSpacing
                    model: view.historyItems
                    delegate: PC3.ItemDelegate {
                        id: entry
                        required property var modelData
                        width: historyList.width
                        onClicked: view.copy(modelData.result)
                        contentItem: ColumnLayout {
                            spacing: 0
                            PC3.Label {
                                Layout.fillWidth: true
                                font: Kirigami.Theme.smallFont
                                opacity: 0.7
                                elide: Text.ElideRight
                                text: [Core.getMode(entry.modelData.mode).label, entry.modelData.lang,
                                       new Date(entry.modelData.ts).toLocaleString(Qt.locale(), Locale.ShortFormat)]
                                      .filter(x => !!x).join(" · ")
                            }
                            PC3.Label {
                                Layout.fillWidth: true
                                wrapMode: Text.Wrap
                                maximumLineCount: 3
                                elide: Text.ElideRight
                                text: entry.modelData.result
                            }
                        }
                    }
                }
            }
            RowLayout {
                Layout.fillWidth: true
                PC3.Label {
                    Layout.fillWidth: true
                    font: Kirigami.Theme.smallFont
                    opacity: 0.7
                    text: view.copiedNote || "Click an entry to copy it."
                }
                PC3.Button {
                    text: "Clear"
                    icon.name: "edit-clear-history"
                    onClicked: {
                        view.cfg.history = "[]";
                        view.showHistory = false;
                    }
                }
            }
        }

        // ---------------- main page
        ColumnLayout {
            visible: !view.showHistory
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: Kirigami.Units.smallSpacing

            Kirigami.InlineMessage {
                Layout.fillWidth: true
                visible: !view.hasKey
                type: Kirigami.MessageType.Information
                text: "Add your Claude API key to start rewriting."
                actions: [
                    Kirigami.Action {
                        text: "Open settings"
                        icon.name: "configure"
                        onTriggered: view.configureRequested()
                    }
                ]
            }
            Kirigami.InlineMessage {
                Layout.fillWidth: true
                visible: view.notice.length > 0
                type: Kirigami.MessageType.Warning
                text: view.notice
                showCloseButton: true
                onVisibleChanged: if (!visible) view.notice = ""
            }

            PC3.ScrollView {
                Layout.fillWidth: true
                Layout.preferredHeight: Kirigami.Units.gridUnit * 5.5
                PC3.TextArea {
                    id: source
                    wrapMode: TextEdit.Wrap
                    placeholderText: "Select text in any app, then open Rephraser.\nYou can also type or paste here."
                    Accessible.name: "Text to rewrite"
                    Keys.onPressed: event => {
                        if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && (event.modifiers & Qt.ControlModifier)) {
                            event.accepted = true;
                            view.run(view.mode);
                        }
                    }
                }
            }

            Flow {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing
                Repeater {
                    model: Core.MODES
                    PC3.Button {
                        required property var modelData
                        text: modelData.label
                        checkable: true
                        checked: view.mode === modelData.id
                        enabled: source.text.trim().length > 0
                        // Clicking the active mode rewrites again, so keep it checked.
                        onClicked: {
                            checked = Qt.binding(() => view.mode === modelData.id);
                            view.run(modelData.id);
                        }
                        PC3.ToolTip.text: modelData.hint
                        PC3.ToolTip.visible: hovered
                        PC3.ToolTip.delay: Kirigami.Units.toolTipDelay
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing
                PC3.ComboBox {
                    id: langBox
                    Layout.preferredWidth: Kirigami.Units.gridUnit * 9
                    model: ["Same language"].concat(Core.LANGUAGES.map(l => "→ " + l))
                    currentIndex: view.outLang === "auto" ? 0 : Core.LANGUAGES.indexOf(view.outLang) + 1
                    Accessible.name: "Output language"
                    onActivated: index => {
                        view.outLang = index === 0 ? "auto" : Core.LANGUAGES[index - 1];
                        if (source.text.trim()) view.run(view.mode);
                    }
                }
                PC3.TextField {
                    id: instruction
                    Layout.fillWidth: true
                    maximumLength: 300
                    placeholderText: "Extra instruction, then Enter (optional)"
                    Accessible.name: "Extra instruction"
                    onAccepted: if (source.text.trim()) view.run(view.mode)
                }
            }

            // Result area
            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.minimumHeight: Kirigami.Units.gridUnit * 6

                PC3.ScrollView {
                    anchors.fill: parent
                    visible: view.status === "streaming" || view.status === "done"
                    PC3.TextArea {
                        readOnly: true
                        wrapMode: TextEdit.Wrap
                        text: view.result
                        Accessible.name: "Rewritten text"
                    }
                }
                ColumnLayout {
                    anchors.centerIn: parent
                    width: parent.width - Kirigami.Units.gridUnit * 2
                    visible: view.status === "loading"
                    spacing: Kirigami.Units.smallSpacing
                    PC3.BusyIndicator { Layout.alignment: Qt.AlignHCenter; running: parent.visible }
                    PC3.Label {
                        Layout.alignment: Qt.AlignHCenter
                        opacity: 0.7
                        text: Core.getMode(view.mode).label + "…"
                    }
                }
                ColumnLayout {
                    anchors.centerIn: parent
                    width: parent.width - Kirigami.Units.gridUnit * 2
                    visible: view.status === "error"
                    spacing: Kirigami.Units.largeSpacing
                    PC3.Label {
                        Layout.fillWidth: true
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.Wrap
                        color: Kirigami.Theme.negativeTextColor
                        text: view.errorMessage
                    }
                    PC3.Button {
                        readonly property bool needsSetup: ["no_key", "auth", "model", "billing"].indexOf(view.errorCode) !== -1
                        Layout.alignment: Qt.AlignHCenter
                        text: needsSetup ? "Open settings" : "Try again"
                        icon.name: needsSetup ? "configure" : "view-refresh"
                        onClicked: needsSetup ? view.configureRequested() : view.run(view.mode)
                    }
                }
                PC3.Label {
                    anchors.centerIn: parent
                    width: parent.width - Kirigami.Units.gridUnit * 2
                    visible: view.status === "idle"
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                    opacity: 0.6
                    text: source.text.trim().length > 0 ? "Pick a mode to rewrite this text." : "The rewrite will appear here."
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing
                PC3.Label {
                    Layout.fillWidth: true
                    font: Kirigami.Theme.smallFont
                    opacity: 0.7
                    elide: Text.ElideRight
                    text: {
                        if (view.copiedNote) return view.copiedNote;
                        if (view.status !== "done") return "";
                        return Core.countWords(source.text) + " → " + Core.countWords(view.result) + " words"
                               + (view.truncated ? " · may be incomplete" : "");
                    }
                }
                PC3.ToolButton {
                    icon.name: view.busy ? "process-stop" : "view-refresh"
                    enabled: view.busy || source.text.trim().length > 0
                    onClicked: view.busy ? view.cancel() : view.run(view.mode)
                    PC3.ToolTip.text: view.busy ? "Stop" : "Try another version"
                    PC3.ToolTip.visible: hovered
                    PC3.ToolTip.delay: Kirigami.Units.toolTipDelay
                    Accessible.name: PC3.ToolTip.text
                }
                PC3.Button {
                    text: "Copy"
                    icon.name: "edit-copy"
                    enabled: view.ready
                    onClicked: view.copy(view.result)
                }
                PC3.Button {
                    text: "Humanize & replace"
                    enabled: !view.busy && source.text.trim().length > 0
                    onClicked: view.humanize(true)
                    PC3.ToolTip.text: "Make it sound more natural, then paste it over the selection in the app you came from"
                    PC3.ToolTip.visible: hovered
                    PC3.ToolTip.delay: Kirigami.Units.toolTipDelay
                }
                PC3.Button {
                    text: "Replace"
                    icon.name: "edit-paste"
                    enabled: view.ready
                    onClicked: view.replace()
                    PC3.ToolTip.text: "Paste the rewrite over the selection in the app you came from"
                    PC3.ToolTip.visible: hovered
                    PC3.ToolTip.delay: Kirigami.Units.toolTipDelay
                }
            }
        }
    }
}
