-- Transport for distributed mode.
--
-- Hides the difference between the two things that can carry a message between
-- bases in OpenComputers:
--
--   modem  — Network Card (wired) or Wireless Network Card. Wireless reaches 16
--            blocks on T1 and 400 on T2, minus block hardness along the ray
--            (WirelessNetwork.isUnobstructed), and CANNOT cross dimensions.
--            Broadcast on a port; the receiver must have opened that port.
--   tunnel — Linked Card. Unlimited range, crosses dimensions, but strictly
--            1:1: send() takes no address because there is exactly one peer.
--
-- Both deliver as a `modem_message` signal:
--   modem_message(localAddress, remoteAddress, port, distance, ...)
-- where localAddress is the card that received it — which is what lets a reply
-- go back out the same way it came in.
--
-- Neither carries components. Only messages. See CLAUDE.md.

local component = require("component")
local computer = require("computer")

local util = require("core.util")

local net = {}
net.__index = net

-- Cards are enumerated through component.list(), a component call, and this runs
-- inside the main loop. Rescan occasionally rather than every tick.
local RESCAN_INTERVAL = 5

-- Every message starts with this, so traffic from other programs sharing the
-- port is ignored rather than fed to serialization.
net.PROTOCOL = "argus"

-- ...and then with a network key, which separates YOUR bases from everyone
-- else's on a shared server.
--
-- This is not optional politeness. modem.broadcast reaches every modem in range
-- that has opened the port, so with a fixed default port and no key, a
-- neighbour's ARGUS server would poll your clients, your clients would answer
-- it, and their buffers would show up on your screen. Both directions.
--
-- Treat it as an SSID, not a password: it stops crossed wires, not a
-- determined eavesdropper. Messages travel in the clear, and anyone in range
-- who knows the key can join. For real isolation use a Linked Card — it is
-- point-to-point and nothing else can receive it.
local function keyFromAddress()
    -- The computer's own UUID: unique per machine, stable across reboots, and
    -- nothing a neighbouring base would ever land on by accident.
    return (computer.address():gsub("%-", ""):sub(1, 8):upper())
end

function net:key()
    local configured = self.config.network and self.config.network.key
    if configured and configured ~= "" then return configured end
    return keyFromAddress()
end

-- True when a message is ours: right protocol, right network.
function net:accepts(protocol, key)
    return protocol == net.PROTOCOL and key == self:key()
end

function net.new(config)
    return setmetatable({
        config = config,
        cards = {},
        cardsAt = nil,
        openedPort = nil,
    }, net)
end

-- {address = {proxy = ..., kind = "modem" | "tunnel"}}
function net:cardList(now)
    now = now or computer.uptime()
    if self.cardsAt and (now - self.cardsAt) < RESCAN_INTERVAL then
        return self.cards
    end

    local found = {}
    for _, kind in ipairs({"modem", "tunnel"}) do
        for address in component.list(kind, true) do
            local ok, proxy = pcall(component.proxy, address)
            if ok and type(proxy) == "table" then
                found[address] = {proxy = proxy, kind = kind}
            end
        end
    end

    self.cards, self.cardsAt = found, now
    self.openedPort = nil -- a new card has not opened the port yet
    return found
end

function net:available()
    return next(self:cardList()) ~= nil
end

-- A modem drops messages on ports it has not opened. A tunnel has no ports at
-- all, so opening one on it is meaningless (and harmless to skip).
function net:openPort(port)
    if self.openedPort == port then return end
    for _, card in pairs(self:cardList()) do
        if card.kind == "modem" then
            util.call(card.proxy, "open", port)
        end
    end
    self.openedPort = port
end

-- Send to everyone reachable: broadcast on every modem, and push down every
-- tunnel (whose single peer needs no address).
function net:broadcast(port, ...)
    self:openPort(port)
    local key = self:key()
    local sent = 0
    for _, card in pairs(self:cardList()) do
        local ok
        if card.kind == "tunnel" then
            ok = util.call(card.proxy, "send", net.PROTOCOL, key, ...) ~= nil
        else
            ok = util.call(card.proxy, "broadcast", port, net.PROTOCOL, key, ...) ~= nil
        end
        if ok then sent = sent + 1 end
    end
    return sent
end

-- Answer whoever just spoke, over the same card they reached us on. Replying by
-- broadcast instead would work but would also wake every other base.
function net:reply(localAddress, remoteAddress, port, ...)
    self:openPort(port)
    local card = self:cardList()[localAddress]
    if not card then return false end
    local key = self:key()
    if card.kind == "tunnel" then
        return util.call(card.proxy, "send", net.PROTOCOL, key, ...) ~= nil
    end
    return util.call(card.proxy, "send", remoteAddress, port, net.PROTOCOL, key, ...) ~= nil
end

-- Name this node answers to. The computer address is a poor label but beats an
-- empty column on the server's Network page.
function net:nodeName()
    local configured = self.config.network and self.config.network.name
    if configured and configured ~= "" then return configured end
    return "node " .. computer.address():sub(1, 8)
end

return net
