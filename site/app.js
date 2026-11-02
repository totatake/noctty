(function () {
  var root = document.documentElement;
  var toggle = document.getElementById("theme-toggle");
  var storageKey = "nc-theme";
  var media = window.matchMedia ? window.matchMedia("(prefers-color-scheme: light)") : null;
  // A choice made with the toggle, kept here too so it holds when storage
  // is blocked.
  var chosenThisVisit = false;

  function chosenTheme() {
    try {
      var stored = localStorage.getItem(storageKey);
      return stored === "light" || stored === "dark" ? stored : null;
    } catch (error) {
      return null;
    }
  }

  function applyTheme(theme) {
    root.setAttribute("data-theme", theme);

    if (toggle) {
      var nextTheme = theme === "dark" ? "light" : "dark";
      var label = "Switch to " + nextTheme + " mode";
      toggle.setAttribute("aria-label", label);
      toggle.setAttribute("title", label);
    }
  }

  applyTheme(root.getAttribute("data-theme") || "dark");

  // The 404 page's terminal names the path that was asked for. It is set as
  // text, stripped of control, format and line-separator characters so a
  // crafted URL cannot draw extra lines or reorder text, and capped by code
  // point so a long URL cannot stretch the page.
  var lostPaths = document.querySelectorAll("[data-nc-lost-path]");
  if (lostPaths.length > 0) {
    var requested = window.location.pathname;
    try {
      requested = decodeURIComponent(requested);
    } catch (error) {
      // Keep the encoded form when it does not decode.
    }
    requested = requested
      .replace(/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/gu, "")
      .replace(/\s+/g, " ")
      .replace(/\//g, "\\");
    var points = Array.from(requested);
    if (points.length > 64) requested = points.slice(0, 63).join("") + "…";
    for (var i = 0; i < lostPaths.length; i += 1) lostPaths[i].textContent = requested;
  }

  // Until the visitor picks a theme, follow the system when it changes.
  if (media) {
    var followSystem = function (event) {
      if (!chosenThisVisit && !chosenTheme()) applyTheme(event.matches ? "light" : "dark");
    };
    if (typeof media.addEventListener === "function") {
      media.addEventListener("change", followSystem);
    } else if (typeof media.addListener === "function") {
      media.addListener(followSystem);
    }
  }

  if (!toggle) return;

  toggle.addEventListener("click", function () {
    var nextTheme = root.getAttribute("data-theme") === "dark" ? "light" : "dark";
    chosenThisVisit = true;
    applyTheme(nextTheme);

    try {
      localStorage.setItem(storageKey, nextTheme);
    } catch (error) {
      // Keep the theme change even if storage is unavailable.
    }
  });
})();
