import QtQuick
import QtTest
import "../../Typing.js" as Typing

// The pairing-code field as Panel.qml wires it: read-only to Qt, so Qt never
// reads the clipboard; four digits typed through Typing.js; Enter submits.
//   QT_QPA_PLATFORM=offscreen qmltestrunner -input tests/qml
Item {
  id: root
  width: 200; height: 60
  property bool busy: false
  property var submitted: []

  TextInput {
    id: codeField
    width: 100; height: 30
    maximumLength: 4
    readOnly: true
    cursorVisible: activeFocus
    onAccepted: root.submitted.push(text)
    Keys.onPressed: function(event) {
      var typed = String(event.text || "")
      if (/^[^\u0000-\u001f\u007f0-9]+$/.test(typed) && !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier))) {
        event.accepted = true
        return
      }
      Typing.handle(codeField, event, !root.busy, false, null)
    }
  }

  TestCase {
    name: "CodeField"
    when: windowShown
    function init() { codeField.text = ""; root.submitted = []; root.busy = false; codeField.forceActiveFocus() }

    function test_digits_only_and_four_at_most() {
      keyClick(Qt.Key_1); keyClick(Qt.Key_A); keyClick(Qt.Key_2); keyClick(Qt.Key_3); keyClick(Qt.Key_4); keyClick(Qt.Key_5)
      compare(codeField.text, "1234")
      keyClick(Qt.Key_Backspace)
      compare(codeField.text, "123")
    }

    function test_enter_submits() {
      keyClick(Qt.Key_4); keyClick(Qt.Key_2); keyClick(Qt.Key_4); keyClick(Qt.Key_2)
      keyClick(Qt.Key_Return)
      compare(root.submitted, ["4242"])
    }

    function test_no_clipboard_and_no_paste() {
      verify(codeField.readOnly && !codeField.canPaste, "Qt never asks for the clipboard")
      keyClick(Qt.Key_V, Qt.ControlModifier)
      keyClick(Qt.Key_Insert, Qt.ShiftModifier)
      compare(codeField.text, "")
    }

    function test_nothing_typed_while_pairing() {
      root.busy = true
      keyClick(Qt.Key_7)
      compare(codeField.text, "")
    }
  }
}
