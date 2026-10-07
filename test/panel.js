"use strict"

const assert = require("assert")
const panel = require("../bar/netshare.js")

function link(device, answer, connection) {
  return {
    device: device,
    answer: answer,
    connection: connection,
    proxy: "http://192.0.2.1:8282/ignored",
    address: "192.0.2.20/24"
  }
}

const yes = link("eth-yes", "yes", "NS-TEST-Yes")
const no = link("eth-no", "no", "NS-TEST-No")
const other = link("eth-other", "yes", "NS-TEST-Other")

assert.deepStrictEqual(
  panel.orderedLinks([no, null, yes]).map((item) => item.device),
  ["eth-yes", "eth-no"]
)

assert.strictEqual(panel.metaText({
  toggleBusy: false, pendingUp: false, tunnelLabel: "up",
  tunnelUp: true, posture: "desktop"
}), "Desktop")
assert.strictEqual(panel.metaText({
  toggleBusy: false, pendingUp: false, tunnelLabel: "up",
  tunnelUp: true, posture: "side"
}), "Side")
assert.strictEqual(panel.metaText({
  toggleBusy: false, pendingUp: false, tunnelLabel: "up",
  tunnelUp: true, posture: "default"
}), "On")
assert.strictEqual(panel.metaText({
  toggleBusy: false, pendingUp: false, tunnelLabel: "stale",
  tunnelUp: false, posture: "desktop"
}), "Stale")
assert.strictEqual(panel.metaText({
  toggleBusy: true, pendingUp: true, tunnelLabel: "down",
  tunnelUp: false, posture: ""
}), "Starting")
assert.strictEqual(panel.metaText({
  toggleBusy: false, pendingUp: false, tunnelLabel: "down",
  tunnelUp: false, posture: ""
}), "Off")

const upMissing = panel.focusLink({
  links: [other],
  boundDevice: "eth-yes",
  tunnelUp: true,
  tunnelLabel: "up"
})
assert.strictEqual(upMissing, null)

const upBound = panel.focusLink({
  links: [other, yes],
  boundDevice: "eth-yes",
  tunnelUp: true,
  tunnelLabel: "up"
})
assert.strictEqual(upBound.device, "eth-yes")

const downOther = panel.focusLink({
  links: [no],
  boundDevice: "",
  tunnelUp: false,
  tunnelLabel: "down"
})
assert.strictEqual(downOther.device, "eth-no")

assert.strictEqual(panel.proxyText(yes), "192.0.2.1:8282")
assert.strictEqual(panel.shownProxy(null, "http://192.0.2.9:8282/x"), "192.0.2.9:8282")
assert.strictEqual(panel.shownProxy(yes, "http://192.0.2.9:8282"), "192.0.2.1:8282")

console.log("ok panel")
