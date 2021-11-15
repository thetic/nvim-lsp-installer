local JobExecutionPool = require "nvim-lsp-installer.job.pool"
local fs = require "nvim-lsp-installer.fs"
local path = require "nvim-lsp-installer.path"
local Data = require "nvim-lsp-installer.data"
local process = require "nvim-lsp-installer.process"
local pip3 = require "nvim-lsp-installer.installers.pip3"

local json_decode = Data.json_decode

local M = {}

---@class CheckResult
---@field public server Server
---@field public success boolean
---@field public outdated_packages OutdatedPackage[]
local CheckResult = {}
CheckResult.__index = CheckResult

---@alias OutdatedPackage {name: string, current_version: string, latest_version: string}

---@param server Server
---@param outdated_packages OutdatedPackage[]
function CheckResult.new(server, success, outdated_packages)
    local self = setmetatable({}, CheckResult)
    self.server = server
    self.success = success
    self.outdated_packages = outdated_packages
    return self
end

function CheckResult:has_outdated_packages()
    return #self.outdated_packages > 0
end

---@param server Server
---@param on_check_complete fun(result: CheckResult)
local function check_npm_installation(server, on_check_complete)
    local stdio = process.in_memory_sink()
    process.spawn("npm", {
        args = { "outdated", "--json" },
        cwd = server.root_dir,
        stdio_sink = stdio.sink,
    }, function()
        ---@alias NpmOutdatedPackage {current: string, wanted: string, latest: string, dependent: string, location: string}
        ---@type table<string, NpmOutdatedPackage>
        local data = json_decode(table.concat(stdio.buffers.stdout, ""))

        ---@type OutdatedPackage[]
        local outdated_packages = {}

        for package, outdated_package in pairs(data) do
            if outdated_package.current ~= outdated_package.latest then
                table.insert(outdated_packages, {
                    name = package,
                    current_version = outdated_package.current,
                    latest_version = outdated_package.latest,
                })
            end
        end

        on_check_complete(CheckResult.new(server, true, outdated_packages))
    end)
end

---@param package PipOutdatedPackage
local function isnt_ignored_pip_package(package)
    return not Data.set_of({ "pip", "setuptools" })[package.name]
end

---@param server Server
---@param on_check_complete fun(result: CheckResult)
local function check_pip_installation(server, on_check_complete)
    local stdio = process.in_memory_sink()
    process.spawn(pip3.executable(server.root_dir, "pip"), {
        args = { "list", "--outdated", "--local", "--format=json", "--not-required" },
        cwd = server.root_dir,
        stdio_sink = stdio.sink,
    }, function(success)
        if success then
            ---@alias PipOutdatedPackage {name: string, version: string, latest_version: string, latest_filetype: string}
            ---@type PipOutdatedPackage[]
            local data = json_decode(table.concat(stdio.buffers.stdout, ""))
            ---@type PipOutdatedPackage[]
            local filtered_packages = vim.tbl_filter(isnt_ignored_pip_package, data)

            ---@type OutdatedPackage[]
            local outdated_packages = {}

            for _, outdated_package in ipairs(filtered_packages) do
                if outdated_package.version ~= outdated_package.latest_version then
                    table.insert(outdated_packages, {
                        name = outdated_package.name,
                        current_version = outdated_package.version,
                        latest_version = outdated_package.latest_version,
                    })
                end
            end

            on_check_complete(CheckResult.new(server, true, outdated_packages))
        else
            on_check_complete(CheckResult.new(server, false))
        end
    end)
end

---@param server Server
---@param on_check_complete fun(result: CheckResult)
local function check_git_installation(server, on_check_complete)
    process.spawn("git", {
        args = { "fetch", "origin", "HEAD" },
        cwd = server.root_dir,
        stdio_sink = process.empty_sink(),
    }, function(fetch_success)
        local stdio = process.in_memory_sink()
        if fetch_success then
            process.spawn("git", {
                args = { "rev-parse", "FETCH_HEAD", "HEAD" },
                cwd = server.root_dir,
                stdio_sink = stdio.sink,
            }, function(success)
                if success then
                    local stdout = table.concat(stdio.buffers.stdout, "")
                    local remote_head, local_head = unpack(vim.split(stdout, "\n"))
                    if remote_head ~= local_head then
                        on_check_complete(CheckResult.new(server, true, {
                            {
                                name = "git",
                                latest_version = remote_head,
                                current_version = local_head,
                            },
                        }))
                    else
                        on_check_complete(CheckResult.new(server, true, {}))
                    end
                else
                    on_check_complete(CheckResult.new(server, false))
                end
            end)
        else
            on_check_complete(CheckResult.new(server, false))
        end
    end)
end

jobpool = jobpool or JobExecutionPool:new {
    size = 4,
}

---@param check_fn fun(server: Server, on_check_complete: fun(result: CheckResult))
---@param server Server
---@param on_result fun(result: CheckResult)
local function wrap(check_fn, server, on_result)
    return function(done)
        check_fn(server, function(result)
            done()
            on_result(result)
        end)
    end
end

---@param servers Server[]
---@param on_result fun(result: CheckResult)
function M.identify_outdated_servers(servers, on_result)
    for _, server in ipairs(servers) do
        -- giggity
        local is_git_repo = fs.dir_exists(path.concat {
            server.root_dir,
            ".git",
        })
        local is_npm_installation = fs.file_exists(path.concat {
            server.root_dir,
            "package.json",
        })
        local is_pip_installation = fs.dir_exists(path.concat {
            server.root_dir,
            "venv",
        })

        if is_git_repo then
            jobpool:supply(wrap(check_git_installation, server, on_result))
        elseif is_npm_installation then
            jobpool:supply(wrap(check_npm_installation, server, on_result))
        elseif is_pip_installation then
            jobpool:supply(wrap(check_pip_installation, server, on_result))
        else
            on_result(CheckResult.new(server, false))
        end
    end
end

return M
