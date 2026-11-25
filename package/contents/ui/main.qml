import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasma5support as P5Support
import org.kde.kirigami as Kirigami

PlasmoidItem {
    id: root

    readonly property string pasteTool: decodeURIComponent(Qt.resolvedUrl("../tools/paste.py").toString().replace(/^file:\/\//, ""))
    property var view: null

    Plasmoid.icon: "tools-check-spelling"
    toolTipMainText: "Rephraser"
    toolTipSubText: "Select text in any app, then click here or press the widget's shortcut"

    // Shown as a full widget on the desktop, as an icon in a panel.
    switchWidth: Kirigami.Units.gridUnit * 18
    switchHeight: Kirigami.Units.gridUnit * 20

    compactRepresentation: MouseArea {
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton
        onClicked: root.expanded = !root.expanded
        Accessible.role: Accessible.Button
        Accessible.name: "Rephraser"
        Kirigami.Icon {
            anchors.fill: parent
            source: Qt.resolvedUrl("../icons/rephraser.svg")
            active: parent.containsMouse
        }
    }

    fullRepresentation: RephraserView {
        id: fullView
        cfg: Plasmoid.configuration
        Component.onCompleted: {
            root.view = fullView;
            if (root.expanded) captureTimer.restart();
        }
        onConfigureRequested: Plasmoid.internalAction("configure").trigger()
        onReplaceRequested: root.pasteIntoPreviousWindow()
    }

    // The primary selection becomes readable once the popup has keyboard
    // focus, which takes a moment after it opens.
    Timer {
        id: captureTimer
        property int tries: 0
        interval: 120
        onTriggered: {
            if (!root.expanded || !root.view) return;
            if (!root.view.captureSelection() && ++tries < 4) restart();
        }
    }

    onExpandedChanged: {
        if (expanded) {
            captureTimer.tries = 0;
            captureTimer.restart();
        }
    }

    // ---- Replace: the result is already on the clipboard. Close the popup so
    // the original window gets focus back, then send the paste shortcut.
    function pasteIntoPreviousWindow() {
        root.expanded = false;
        pasteTimer.restart();
    }

    function shellQuote(s) {
        return "'" + String(s).replace(/'/g, "'\\''") + "'";
    }

    Timer {
        id: pasteTimer
        interval: 350
        onTriggered: {
            const keys = ["ctrl+v", "ctrl+shift+v", "shift+insert"].indexOf(Plasmoid.configuration.pasteKeys) !== -1
                ? Plasmoid.configuration.pasteKeys : "ctrl+v";
            // The trailing comment makes each run a distinct source name.
            executable.connectSource("python3 " + root.shellQuote(root.pasteTool) + " --keys " + keys + " # " + Date.now());
        }
    }

    P5Support.DataSource {
        id: executable
        engine: "executable"
        connectedSources: []
        onNewData: (sourceName, data) => {
            disconnectSource(sourceName);
            const code = data["exit code"];
            if (code === 0) return;
            const reason = String(data.stdout || "").trim() || "The paste shortcut could not be sent.";
            if (root.view) root.view.notice = reason + " The rewrite is on your clipboard: paste it with Ctrl+V.";
            root.expanded = true;
        }
    }
}
