module("luci.controller.admin.dstore", package.seeall)

function index()
    entry({"admin", "tools"}, firstchild(), _("Tools"), 50).dependent = false
    entry({"admin", "tools", "dstore"}, firstchild(), _("Dstore"), 10).dependent = false
    entry({"admin", "tools", "dstore", "all"}, template("dstore/all"), _("All"), 1)
    entry({"admin", "tools", "dstore", "installed"}, template("dstore/installed"), _("Installed"), 2)
    entry({"admin", "tools", "dstore", "not_installed"}, template("dstore/not_installed"), _("Not Installed"), 3)
    entry({"admin", "tools", "dstore", "update"}, template("dstore/update"), _("Update"), 4)
    entry({"admin", "tools", "dstore", "settings"}, cbi("dstore/settings"), _("Settings"), 5)
    entry({"admin", "tools", "dstore", "api", "list"}, call("action_app_json"), nil).leaf = true
    entry({"admin", "tools", "dstore", "api", "manage"}, call("action_app_manage"), nil).leaf = true
end

local function clear_opkg_lock()
    local nixio = require "nixio.fs"
    local lock_files = { "/var/lock/opkg.lock", "/var/lib/opkg/status.lock" }
    for _, f in ipairs(lock_files) do
        if nixio.stat(f) then
            nixio.remove(f)
        end
    end
end

function action_app_manage()
    local url = luci.http.formvalue("url")
    local pkg = luci.http.formvalue("pkg")
    local action = luci.http.formvalue("do")
    luci.http.prepare_content("text/plain")

    if action == "list" then
        clear_opkg_lock()
        luci.http.write(luci.sys.exec("opkg list-installed 2>/dev/null"))
        return
    end

    if action == "install" and url and url:match("^https?://") and pkg then
        luci.http.write("Installing " .. pkg .. "...\n\n")
        local tmp_path = "/tmp/app.ipk"
        local wget_cmd = string.format("wget -O '%s' '%s' 2>&1", tmp_path, url)
        luci.http.write("Downloading package...\n")
        luci.sys.exec(wget_cmd)

        local nixio = require "nixio.fs"
        local file_stat = nixio.stat(tmp_path)
        if file_stat and file_stat.size > 0 then
            clear_opkg_lock()
            luci.sys.exec("opkg update >/dev/null 2>&1")
            local output = luci.sys.exec("opkg install " .. tmp_path .. " 2>&1")
            output = output:gsub("Collected errors:.-\n", "")
            luci.http.write(output)
            nixio.remove(tmp_path)
        else
            luci.http.write("\nDownload failed. Could not install package.\n")
        end
        return
    end

    if action == "uninstall" and pkg then
        clear_opkg_lock()
        local output = luci.sys.exec("opkg remove " .. pkg .. " 2>&1")
        output = output:gsub("Collected errors:.-\n", "")
        luci.http.write(output)
        return
    end

    luci.http.status(400, "Bad Request")
    luci.http.write("Invalid parameters.\n")
end

function action_app_json()
    local uci = require "luci.model.uci".cursor()
    local json = require "luci.jsonc"
    local util = require "luci.util"
    local urls = uci:get_list("dstore", "settings", "json_urls")

    if not urls or #urls == 0 then
        luci.http.status(500, "Missing JSON URLs in /etc/config/dstore")
        luci.http.write("Error: No 'json_urls' found in /etc/config/dstore")
        return
    end

    local installed_map = {}
    for line in io.popen("opkg list-installed"):lines() do
        local pkg, ver = line:match("^(%S+)%s+%-%s+(.+)$")
        if pkg and ver then
            installed_map[pkg] = ver
        end
    end

    local app_map = {}
    local function normalize_version(ver)
        return ver:gsub("^v", "")
    end

    local function compare_versions(a, b)
        local function split(v)
            local parts = {}
            for p in v:gmatch("[^%.%-]+") do
                table.insert(parts, tonumber(p) or p)
            end
            return parts
        end

        local pa = split(a)
        local pb = split(b)
        local len = math.max(#pa, #pb)

        for i = 1, len do
            local va = pa[i] or 0
            local vb = pb[i] or 0
            if type(va) == "number" and type(vb) == "number" then
                if va ~= vb then return va > vb end
            else
                va = tostring(va)
                vb = tostring(vb)
                if va ~= vb then return va > vb end
            end
        end
        return false
    end

    for _, url in ipairs(urls) do
        if url:match("^https?://") then
            local output = luci.sys.exec("wget -qO- '" .. url .. "'")
            local ok, data = pcall(json.parse, output)
            if ok and type(data) == "table" then
                for _, app in ipairs(data) do
                    if app.package and app.version then
                        local pkg = app.package
                        local new_ver = normalize_version(app.version)
                        if installed_map[pkg] then
                            app.installed_version = normalize_version(installed_map[pkg])
                        end
                        if not app_map[pkg] or compare_versions(new_ver, normalize_version(app_map[pkg].version)) then
                            app_map[pkg] = app
                        end
                    end
                end
            else
                util.perror("Failed to parse JSON from: " .. url)
            end
        end
    end

    local all_apps = {}
    for _, app in pairs(app_map) do
        table.insert(all_apps, app)
    end

    luci.http.prepare_content("application/json")
    luci.http.write(json.stringify(all_apps))
end
