local server = require "nvim-lsp-installer.server"
local npm = require "nvim-lsp-installer.installers.npm"

return function(name, root_dir)
    return server.Server:new {
        name = name,
        root_dir = root_dir,
        languages = { "spectral" },
        homepage = "https://stoplight.io/open-source/spectral/",
        installer = npm.packages { "spectral-language-server" },
        default_options = {
            cmd = { npm.executable(root_dir, "spectral-language-server") },
        },
    }
end
