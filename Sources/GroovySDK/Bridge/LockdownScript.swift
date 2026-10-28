import Foundation

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
      var names = ["geolocation", "mediaDevices", "getUserMedia", "webkitGetUserMedia"];
      for (var i = 0; i < names.length; i++) {
        if (typeof Navigator !== "undefined" && Navigator.prototype) { remove(Navigator.prototype, names[i]); }
        if (typeof navigator !== "undefined") { remove(navigator, names[i]); }
      }
      // No file chooser from the page either: a file input can offer the camera where no native
      // delegate refuses it (iOS before 18.4, or an SDK built with an older toolchain). Everything the
      // guard relies on is captured here, before any page script runs, and called through `Reflect.apply`,
      // so a page that later replaces `Event.prototype.preventDefault`, `composedPath`, the `target`
      // getter, `addEventListener`, `Function.prototype.call` or `HTMLInputElement[Symbol.hasInstance]`
      // changes nothing. A file input is recognised through the native `type` getter, whose own brand
      // check rejects anything that is not an input (no `instanceof`), compared with the lowercase
      // value the getter returns. The guard listens on the window in the capture phase (first), inside
      // every shadow root (attached open: a closed one would hide its nodes from the window's path, and
      // a page listener on the window could stop the event before the root's own guard), and again after
      // `document.open()`, which drops the window's listeners.
      var reflectApply = Reflect.apply;
      var own = Object.getOwnPropertyDescriptor;
      var define = Object.defineProperty;
      var assign = Object.assign;
      var EventProto = typeof Event !== "undefined" ? Event.prototype : null;
      var preventDefault = EventProto && EventProto.preventDefault;
      var composedPath = EventProto && EventProto.composedPath;
      var targetDescriptor = EventProto && own(EventProto, "target");
      var nativeTarget = targetDescriptor && targetDescriptor.get;
      var addListener = typeof EventTarget !== "undefined" && EventTarget.prototype ? EventTarget.prototype.addEventListener : null;
      var InputProto = typeof HTMLInputElement !== "undefined" ? HTMLInputElement.prototype : null;
      var typeDescriptor = InputProto && own(InputProto, "type");
      var nativeType = typeDescriptor && typeDescriptor.get;
      function isFileInput(node) {
        if (!nativeType || node === null || typeof node !== "object") { return false; }
        try { return reflectApply(nativeType, node, []) === "file"; } catch (e) { return false; }
      }
      function guard(event) {
        var path = null;
        if (composedPath) { try { path = reflectApply(composedPath, event, []); } catch (e) { path = null; } }
        if (!path || !path.length) {
          var target = null;
          if (nativeTarget) { try { target = reflectApply(nativeTarget, event, []); } catch (e) { target = null; } }
          path = [target];
        }
        for (var j = 0; j < path.length; j++) {
          if (isFileInput(path[j])) {
            if (preventDefault) { try { reflectApply(preventDefault, event, []); } catch (e) { /* not cancelable */ } }
            return;
          }
        }
      }
      function install(target) {
        if (!target || !addListener) { return; }
        try { reflectApply(addListener, target, ["click", guard, true]); } catch (e) { /* not an event target */ }
      }
      install(typeof window !== "undefined" ? window : null);
      if (typeof Element !== "undefined" && Element.prototype && typeof Element.prototype.attachShadow === "function") {
        var attachShadow = Element.prototype.attachShadow;
        try {
          define(Element.prototype, "attachShadow", {
            value: function (init) {
              var options = init && typeof init === "object" ? assign({}, init, { mode: "open" }) : init;
              var root = reflectApply(attachShadow, this, [options]);
              install(root);
              return root;
            },
            writable: false, configurable: false
          });
        } catch (e) { /* already locked */ }
      }
      if (typeof Document !== "undefined" && Document.prototype && typeof Document.prototype.open === "function") {
        var open = Document.prototype.open;
        try {
          define(Document.prototype, "open", {
            value: function () {
              var result = reflectApply(open, this, arguments);
              install(this.defaultView);
              return result;
            },
            writable: false, configurable: false
          });
        } catch (e) { /* already locked */ }
      }
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
