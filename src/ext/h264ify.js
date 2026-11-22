(function () {
  "use strict";

  const BLOCKED_CODECS = /vp0?9|av01/i;
  const HIGH_RES = /height=(?:1[1-9]\d{2}|[2-9]\d{3,})/i;

  if (typeof MediaSource !== "undefined" && typeof MediaSource.isTypeSupported === "function") {
    const origIsSupported = MediaSource.isTypeSupported.bind(MediaSource);
    MediaSource.isTypeSupported = function (mime) {
      if (typeof mime === "string" && (BLOCKED_CODECS.test(mime) || HIGH_RES.test(mime))) {
        return false;
      }
      return origIsSupported(mime);
    };
  }

  if (typeof HTMLMediaElement !== "undefined" && HTMLMediaElement.prototype.canPlayType) {
    const origCanPlay = HTMLMediaElement.prototype.canPlayType;
    HTMLMediaElement.prototype.canPlayType = function (mime) {
      if (typeof mime === "string" && BLOCKED_CODECS.test(mime)) {
        return "";
      }
      return origCanPlay.call(this, mime);
    };
  }
})();
