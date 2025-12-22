module("luci.controller.nftttl", package.seeall)

function index()
    entry({"admin", "tools"}, firstchild(), _("Tools"), 50).dependent = false
    if not nixio.fs.access("/etc/config/nftttl") then return end
    entry({"admin", "tools", "nftttl"}, cbi("nftttl"), _("TTL Config"), 60).acl_depends = { "luci-app-nft-ttl" }
end
