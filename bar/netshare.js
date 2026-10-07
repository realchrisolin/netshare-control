// Panel decisions shared by the bar module and test/panel.js.
// Plain JavaScript. No network lookups.

function orderedLinks(links) {
  var yes = []
  var rest = []
  var list = links || []
  var i
  for (i = 0; i < list.length; i++) {
    if (!list[i]) continue
    if (list[i].answer === "yes") yes.push(list[i])
    else rest.push(list[i])
  }
  return yes.concat(rest)
}

function accessPointCount(links) {
  var list = orderedLinks(links)
  var count = 0
  var i
  for (i = 0; i < list.length; i++) {
    if (list[i] && list[i].answer === "yes") count++
  }
  return count
}

function accessPoint(links) {
  return accessPointCount(links) === 1 ? orderedLinks(links)[0] : null
}

function focusLink(state) {
  var list = orderedLinks(state.links)
  var bound = state.boundDevice ? String(state.boundDevice) : ""
  var i
  if (bound !== "") {
    for (i = 0; i < list.length; i++) {
      if (list[i] && String(list[i].device) === bound) return list[i]
    }
    if (state.tunnelUp || state.tunnelLabel === "stale") return null
  }
  var chosen = accessPoint(state.links)
  if (chosen) return chosen
  if (list.length === 1) return list[0]
  return null
}

function proxyText(link) {
  if (!link) return ""
  var proxy = String(link.proxy || "")
  proxy = proxy.replace(/^https?:\/\//, "")
  return proxy.split("/")[0]
}

function shownProxy(focus, boundProxy) {
  var fromLink = proxyText(focus)
  if (fromLink !== "") return fromLink
  var saved = String(boundProxy || "")
  saved = saved.replace(/^https?:\/\//, "")
  return saved.split("/")[0]
}

function metaText(state) {
  if (state.toggleBusy) return state.pendingUp ? "Starting" : "Stopping"
  if (state.tunnelLabel === "stale") return "Stale"
  if (state.tunnelUp && state.posture === "desktop") return "Desktop"
  if (state.tunnelUp && state.posture === "side") return "Side"
  if (state.tunnelUp) return "On"
  return "Off"
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    orderedLinks: orderedLinks,
    accessPointCount: accessPointCount,
    accessPoint: accessPoint,
    focusLink: focusLink,
    proxyText: proxyText,
    shownProxy: shownProxy,
    metaText: metaText
  }
}
