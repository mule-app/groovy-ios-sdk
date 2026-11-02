import Foundation

/// Spec 232 adds what research R2 and R5 name: no field takes focus or text, and payment, clipboard
/// and share are gone.
///
/// Spec 230 (data-model "Permissions") — the script injected at document start in the page's own
/// world, in every frame: it removes `navigator.geolocation` and the media-capture entry points,
/// non-configurable on both `Navigator.prototype` and the instance, so the page cannot ask for
/// location, the camera or the microphone (the guard on iOS 15 to 26, where WebKit offers no
/// delegate to refuse geolocation; the delegates refuse the rest), and it cancels every click on a
/// file input (recognised through the native `type` getter, through shadow roots and after
/// `document.open()`) and makes `click()` and `showPicker()` on one do nothing: a file chooser can
/// offer the camera where no native delegate refuses it (iOS before 18.4, or an older toolchain). Frozen with the bridge as
/// `page.js` in `modules/widget/__tests__/sdk-bridge/fixtures/` (research R6): the widget's tests
/// check this text equals the fixture, and never change it without a new release.
enum LockdownScript {
    static let source = """
    (function () {
      function remove(target, name) {
        try {
          Object.defineProperty(target, name, { value: undefined, writable: false, configurable: false, enumerable: false });
        } catch (e) { /* already locked, or absent on this engine */ }
      }
      var names = ["geolocation", "mediaDevices", "getUserMedia", "webkitGetUserMedia", "clipboard", "share", "canShare"];
      for (var i = 0; i < names.length; i++) {
        if (typeof Navigator !== "undefined" && Navigator.prototype) { remove(Navigator.prototype, names[i]); }
        if (typeof navigator !== "undefined") { remove(navigator, names[i]); }
      }
      // No payment from the page, and no clipboard constructor to go with the removed `clipboard`.
      var globals = ["ApplePaySession", "ApplePaySetup", "PaymentRequest", "ClipboardItem"];
      for (var g = 0; g < globals.length; g++) {
        if (typeof window !== "undefined") { remove(window, globals[g]); }
      }
      // Nothing may create a closed declarative shadow root after this script: its nodes would be hidden
      // from the guards' path. A closed root in the served HTML, or through `document.write`, cannot be
      // stopped; the focus guard's allowlist and the SDK's native layer hold there.
      var parsers = ["setHTMLUnsafe", "setHTML", "appendHTML", "appendHTMLUnsafe", "prependHTML", "prependHTMLUnsafe", "beforeHTML", "beforeHTMLUnsafe", "afterHTML", "afterHTMLUnsafe", "replaceWithHTML", "replaceWithHTMLUnsafe"];
      for (var p = 0; p < parsers.length; p++) {
        if (typeof Element !== "undefined" && Element.prototype) { remove(Element.prototype, parsers[p]); }
        if (typeof ShadowRoot !== "undefined" && ShadowRoot.prototype) { remove(ShadowRoot.prototype, parsers[p]); }
      }
      if (typeof Document !== "undefined") {
        remove(Document, "parseHTMLUnsafe");
        remove(Document, "parseHTML");
      }
      // No file chooser and no text entry from the page: a file input can offer the camera where no
      // native delegate refuses it (iOS before 18.4, or an SDK built with an older toolchain), and a
      // focused field offers the customer's saved passwords. Everything the guards rely on is captured
      // here, before any page script runs, and called through `Reflect.apply`, so a page that later
      // replaces `Event.prototype.preventDefault`, `composedPath`, the `target` getter,
      // `addEventListener`, `Function.prototype.call` or `HTMLInputElement[Symbol.hasInstance]` changes
      // nothing. Fields are recognised through native getters, whose own brand checks reject anything
      // else (no `instanceof`). The guards listen on the window in the capture phase (first), inside
      // every shadow root (attached open: a closed one would hide its nodes from the window's path, and
      // a page listener on the window could stop the event before the root's own guard), and again
      // after `document.open()`, `write()` and `writeln()`, which drop the window's listeners.
      var reflectApply = Reflect.apply;
      var own = Object.getOwnPropertyDescriptor;
      var define = Object.defineProperty;
      var assign = Object.assign;
      var toText = String;
      var toLower = String.prototype.toLowerCase;
      var indexOf = String.prototype.indexOf;
      var EventProto = typeof Event !== "undefined" ? Event.prototype : null;
      var preventDefault = EventProto && EventProto.preventDefault;
      var composedPath = EventProto && EventProto.composedPath;
      var stopImmediate = EventProto && EventProto.stopImmediatePropagation;
      var addListener = typeof EventTarget !== "undefined" && EventTarget.prototype ? EventTarget.prototype.addEventListener : null;
      var ElementProto = typeof Element !== "undefined" ? Element.prototype : null;
      var HTMLProto = typeof HTMLElement !== "undefined" ? HTMLElement.prototype : null;
      var DocumentProto = typeof Document !== "undefined" ? Document.prototype : null;
      var InputProto = typeof HTMLInputElement !== "undefined" ? HTMLInputElement.prototype : null;
      function getter(proto, name) {
        var descriptor = proto && own(proto, name);
        return descriptor && descriptor.get;
      }
      // The value of a native getter, or undefined when `node` is not what the getter is for.
      function read(get, node) {
        if (!get) { return undefined; }
        try { return reflectApply(get, node, []); } catch (e) { return undefined; }
      }
      var nativeTarget = getter(EventProto, "target");
      var nativeType = getter(InputProto, "type");
      var nativeTextValue = getter(typeof HTMLTextAreaElement !== "undefined" ? HTMLTextAreaElement.prototype : null, "value");
      var nativeEditable = getter(HTMLProto, "isContentEditable");
      var nativeControl = getter(typeof HTMLLabelElement !== "undefined" ? HTMLLabelElement.prototype : null, "control");
      var nativeLocalName = getter(ElementProto, "localName");
      var nativeView = getter(DocumentProto, "defaultView");
      var nativeActive = getter(DocumentProto, "activeElement");
      var nativeEventType = getter(EventProto, "type");
      var nativeComputedStyle = typeof getComputedStyle === "function" ? getComputedStyle : null;
      var nativeStyleValue = typeof CSSStyleDeclaration !== "undefined" ? CSSStyleDeclaration.prototype.getPropertyValue : null;
      var nativeParent = getter(typeof Node !== "undefined" ? Node.prototype : null, "parentElement");
      var SelectionProto = typeof Selection !== "undefined" ? Selection.prototype : null;
      var nativeAnchor = getter(SelectionProto, "anchorNode");
      var nativeRemoveRanges = SelectionProto && SelectionProto.removeAllRanges;
      var nativeGetSelection = typeof getSelection === "function" ? getSelection : null;
      // `focus` and `blur` are separate functions on HTML, SVG and MathML elements.
      var focusProtos = [HTMLProto, typeof SVGElement !== "undefined" ? SVGElement.prototype : null, typeof MathMLElement !== "undefined" ? MathMLElement.prototype : null];
      var nativeBlurs = [];
      for (var b = 0; b < focusProtos.length; b++) {
        if (focusProtos[b] && focusProtos[b].blur) { nativeBlurs[nativeBlurs.length] = focusProtos[b].blur; }
      }
      function isFileInput(node) {
        return read(nativeType, node) === "file";
      }
      function isField(node) {
        if (node === null || typeof node !== "object") { return false; }
        return read(nativeType, node) !== undefined || read(nativeTextValue, node) !== undefined || read(nativeEditable, node) === true || isUserModifiable(node);
      }
      // `-webkit-user-modify` takes text while `isContentEditable` stays false.
      function isUserModifiable(node) {
        if (!nativeComputedStyle || !nativeStyleValue) { return false; }
        try {
          var modify = reflectApply(nativeStyleValue, nativeComputedStyle(node), ["-webkit-user-modify"]);
          return modify === "read-write" || modify === "read-write-plaintext-only";
        } catch (e) { return false; }
      }
      function pathOf(event) {
        var path = null;
        if (composedPath) { try { path = reflectApply(composedPath, event, []); } catch (e) { path = null; } }
        if (!path || !path.length) { path = [read(nativeTarget, event)]; }
        return path;
      }
      // A tap or a click on a field, or on a label for one, does nothing.
      function guard(event) {
        var path = pathOf(event);
        for (var j = 0; j < path.length; j++) {
          if (isField(path[j]) || isField(read(nativeControl, path[j]))) {
            if (preventDefault) { try { reflectApply(preventDefault, event, []); } catch (e) { /* not cancelable */ } }
            return;
          }
        }
      }
      // After focus, by autofocus, Tab, assistive technology or another realm's `focus`: only elements
      // that cannot host a shadow root keep it, so `activeElement` is never left on a field, nor on the
      // host of a closed root holding one.
      var focusable = Object.create(null);
      focusable.a = focusable.button = focusable.summary = focusable.video = true;
      function mayKeepFocus(node) {
        return focusable[read(nativeLocalName, node)] === true && !isField(node);
      }
      function drop(node) {
        for (var j = 0; j < nativeBlurs.length; j++) {
          try { reflectApply(nativeBlurs[j], node, []); return; } catch (e) { /* another kind of element */ }
        }
      }
      function guardFocus(event) {
        var target = pathOf(event)[0];
        if (read(nativeLocalName, target) === undefined || mayKeepFocus(target)) { return; }
        drop(target);
        var active = typeof document !== "undefined" ? read(nativeActive, document) : null;
        if (active && read(nativeLocalName, active) !== "body" && !mayKeepFocus(active)) { drop(active); }
      }
      // No text arrives either way: a caret placed by a selection needs no focus, and an element can
      // become editable after it took focus, with no focus event to see it.
      function guardInput(event) {
        guard(event);
        var path = pathOf(event);
        for (var j = 0; j < path.length; j++) {
          if (isField(path[j])) { drop(path[j]); return; }
        }
      }
      function guardSelection() {
        if (!nativeGetSelection || !nativeRemoveRanges) { return; }
        try {
          var selection = nativeGetSelection();
          var anchor = read(nativeAnchor, selection);
          if (!anchor) { return; }
          if (isField(anchor) || isField(read(nativeParent, anchor))) { reflectApply(nativeRemoveRanges, selection, []); }
        } catch (e) { /* no selection here */ }
      }
      var gestures = ["click", "touchend", "pointerdown", "mousedown"];
      var focusEvents = ["focus", "focusin"];
      var inputEvents = ["keydown", "beforeinput", "compositionstart"];
      // A page listener can get ahead of the guards: one added while `document.open()` runs, by a custom
      // element's `disconnectedCallback`, comes before they are installed again. It cannot stop them:
      // stopping an event they watch runs its guard first.
      var guardFor = Object.create(null);
      for (var t = 0; t < gestures.length; t++) { guardFor[gestures[t]] = guard; }
      for (var u = 0; u < focusEvents.length; u++) { guardFor[focusEvents[u]] = guardFocus; }
      for (var v = 0; v < inputEvents.length; v++) { guardFor[inputEvents[v]] = guardInput; }
      guardFor.selectionchange = guardSelection;
      if (EventProto && stopImmediate) {
        try {
          define(EventProto, "stopImmediatePropagation", {
            value: function () {
              var run = guardFor[read(nativeEventType, this)];
              if (run) { run(this); }
              return reflectApply(stopImmediate, this, arguments);
            },
            writable: false, configurable: false
          });
        } catch (e) { /* already locked */ }
      }
      function install(target) {
        if (!target || !addListener) { return; }
        try {
          for (var j = 0; j < gestures.length; j++) { reflectApply(addListener, target, [gestures[j], guard, true]); }
          for (var k = 0; k < focusEvents.length; k++) { reflectApply(addListener, target, [focusEvents[k], guardFocus, true]); }
          for (var m = 0; m < inputEvents.length; m++) { reflectApply(addListener, target, [inputEvents[m], guardInput, true]); }
          reflectApply(addListener, target, ["selectionchange", guardSelection, true]);
        } catch (e) { /* not an event target */ }
      }
      install(typeof window !== "undefined" ? window : null);
      if (ElementProto && typeof ElementProto.attachShadow === "function") {
        var attachShadow = ElementProto.attachShadow;
        try {
          define(ElementProto, "attachShadow", {
            value: function (init) {
              var options = init;
              if (init && typeof init === "object") {
                // Its own property: a setter for `mode` on `Object.prototype` would take an assignment.
                options = assign({}, init);
                define(options, "mode", { value: "open", enumerable: true, configurable: true, writable: true });
              }
              var root = reflectApply(attachShadow, this, [options]);
              install(root);
              return root;
            },
            writable: false, configurable: false
          });
        } catch (e) { /* already locked */ }
      }
      if (DocumentProto && typeof DocumentProto.open === "function") {
        var rawWrite = DocumentProto.write;
        var rearmAfter = function (name, opensFirst) {
          var native = DocumentProto[name];
          if (typeof native !== "function") { return; }
          try {
            define(DocumentProto, name, {
              value: function () {
                // `write` can open the document, then runs the scripts it writes. An empty write opens
                // it exactly when the real one would, so the guards are back before any of them runs.
                // `write` is coerced first and once into the one string it writes: a `toString` must not run
                // between the two, and an array built here by index would reach a setter on `Array.prototype`.
                var result;
                if (opensFirst) {
                  var text = "";
                  for (var j = 0; j < arguments.length; j++) { text += toText(arguments[j]); }
                  reflectApply(rawWrite, this, [""]);
                  install(read(nativeView, this));
                  result = reflectApply(native, this, [text]);
                } else {
                  result = reflectApply(native, this, arguments);
                }
                install(read(nativeView, this));
                return result;
              },
              writable: false, configurable: false
            });
          } catch (e) { /* already locked */ }
        };
        rearmAfter("open", false);
        rearmAfter("write", true);
        rearmAfter("writeln", true);
      }
      if (DocumentProto) {
        var design = own(DocumentProto, "designMode");
        if (design && design.set) {
          try {
            define(DocumentProto, "designMode", {
              get: design.get,
              set: function (value) {
                var mode = reflectApply(toLower, toText(value), []);
                if (mode !== "on") { reflectApply(design.set, this, [mode]); }
              },
              configurable: false
            });
          } catch (e) { /* already locked */ }
        }
        var execCommand = DocumentProto.execCommand;
        if (typeof execCommand === "function") {
          try {
            define(DocumentProto, "execCommand", {
              // One coercion: a `toString` answering differently on a second read gets nothing.
              value: function (command, showUI, value) {
                var name = toText(command);
                var lower = reflectApply(toLower, name, []);
                if (lower === "copy" || lower === "cut" || reflectApply(indexOf, lower, ["paste"]) === 0) { return false; }
                return reflectApply(execCommand, this, [name, showUI, value]);
              },
              writable: false, configurable: false
            });
          } catch (e) { /* already locked */ }
        }
      }
      var lockFocus = function (proto) {
        var nativeFocus = proto && proto.focus;
        if (!nativeFocus) { return; }
        try {
          define(proto, "focus", {
            // The options are read before the check: a getter on them could make the element editable after it.
            value: function (options) {
              var scroll = !!(options && options.preventScroll);
              if (!isField(this)) { return reflectApply(nativeFocus, this, [{ preventScroll: scroll }]); }
            },
            writable: false, configurable: false
          });
        } catch (e) { /* already locked */ }
      };
      for (var f = 0; f < focusProtos.length; f++) { lockFocus(focusProtos[f]); }
      if (InputProto) {
        var click = InputProto.click;
        var showPicker = InputProto.showPicker;
        try {
          define(InputProto, "click", {
            value: function () { if (!isFileInput(this)) { return reflectApply(click, this, arguments); } },
            writable: false, configurable: false
          });
          define(InputProto, "showPicker", {
            value: function () { if (!isFileInput(this)) { return showPicker ? reflectApply(showPicker, this, arguments) : undefined; } },
            writable: false, configurable: false
          });
        } catch (e) { /* already locked */ }
      }
    })();
    """
}
