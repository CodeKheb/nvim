local M = {}

local config = {
  host = "winbloat",
  remote_directory = "Projects",
  debounce_ms = 400,

  exclude = {
    [".git"] = true,
    [".vs"] = true,
    ["bin"] = true,
    ["obj"] = true,
    ["node_modules"] = true,
    [".dart_tool"] = true,
    ["coverage"] = true,
  },
}

local pending = {}
local generation = 0

local function notify(message, level)
  vim.schedule(function()
    vim.notify(message, level or vim.log.levels.INFO, {
      title = "Windows Sync",
    })
  end)
end

local function quote_ps(value)
  return "'" .. value:gsub("'", "''") .. "'"
end

local function should_sync(path)
  for part in path:gmatch("[^/\\]+") do
    if config.exclude[part] then
      return false
    end
  end

  return true
end

local function sync_file(path)
  local directory = vim.fs.dirname(path)

  -- Find the Git project root.
  vim.system({
    "git", "-C", directory,
    "rev-parse", "--show-toplevel",
  }, { text = true }, function(result)
    if result.code ~= 0 then
      return
    end

    local root = vim.trim(result.stdout)
    local relative = path:sub(#root + 2)

    if relative == "" or not should_sync(relative) then
      return
    end

    local project = vim.fs.basename(root)

    -- Create the matching destination directory on Windows.
    local remote_relative = relative:match("(.+)[/\\]") or ""
    local remote_folder = config.remote_directory
      .. "\\"
      .. project

    if remote_relative ~= "" then
      remote_folder = remote_folder .. "\\"
        .. remote_relative:gsub("/", "\\")
    end

    local script = string.format(
      "$dir = Join-Path $env:USERPROFILE %s; " ..
      "New-Item -ItemType Directory -Force -Path $dir | Out-Null; " ..
      "[Console]::Write($dir)",
      quote_ps(remote_folder)
    )

    local command = 'powershell -NoProfile -NonInteractive -Command "'
      .. script .. '"'

    vim.system({
      "ssh", config.host, command,
    }, { text = true }, function(ssh_result)
      if ssh_result.code ~= 0 then
        notify("Could not prepare Windows destination: " ..
          (ssh_result.stderr or ""), vim.log.levels.ERROR)
        return
      end

      local destination = vim.trim(ssh_result.stdout)
        :gsub("\\", "/")

      -- Transfer just the saved file.
      vim.system({
        "scp",
        "-q",
        path,
        config.host .. ":" .. destination .. "/" ..
          vim.fs.basename(path),
      }, {}, function(scp_result)
        if scp_result.code ~= 0 then
          notify("Transfer failed: " .. path,
            vim.log.levels.ERROR)
        end
      end)
    end)
  end)
end

local function flush()
  local files = pending
  pending = {}

  for path in pairs(files) do
    sync_file(path)
  end
end

function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})

  local group = vim.api.nvim_create_augroup(
    "WindowsAutoSync",
    { clear = true }
  )

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(event)
      local path = vim.api.nvim_buf_get_name(event.buf)

      if path == "" or vim.bo[event.buf].buftype ~= "" then
        return
      end

      path = vim.fn.fnamemodify(path, ":p")

      if not should_sync(path) then
        return
      end

      pending[path] = true
      generation = generation + 1

      local current = generation

      vim.defer_fn(function()
        if current == generation then
          flush()
        end
      end, config.debounce_ms)
    end,
  })

  vim.api.nvim_create_user_command("WinSync", function()
    flush()
    notify("Synchronization queue flushed")
  end, {})

  notify("Automatic Windows synchronization enabled")
end

return M
