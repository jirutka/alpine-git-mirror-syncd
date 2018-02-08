#!/usr/bin/env lua

local mqtt = require 'mosquitto'

-- Allow either cjson, or th-LuaJSON
local ok, json = pcall(require, 'cjson')
if not ok then json = require 'json' end

-- unpack is not global since Lua 5.3
local unpack = table.unpack or unpack
local concat = table.concat
local sh = os.execute


local VERSION = '0.2.0'
local CONFIG = os.getenv('CONFIG') or './config.lua'
local DEBUG = os.getenv('DEBUG') ~= nil

-- Default configuration
local conf = {
  mqtt_host = nil,
  mqtt_port = 1883,
  mqtt_keepalive = 300,
  mqtt_topics = {},
  log_date_format = '%Y-%m-%dT%H:%M:%S',
  cache_dir = './tmp',
  origin_url = nil,
  mirror_url = nil,
  ssh_command = 'ssh',
}


-------- Functions --------

-- String interpolation using %.
getmetatable('').__mod = function(str, args)
  if type(args) ~= 'table' then
    args = { args }
  end
  return str:format(unpack(args)):gsub('($%b{})', function(placeholder)
    return args[placeholder:sub(3, -2)] or placeholder
  end)
end

-- Merges tables.
local function merge (...)
  local res = {}
  for _, tab in ipairs {...} do
    for k, v in pairs(tab) do res[k] = v end
  end

  return res
end

local function log (msg)
  if conf.log_date_format ~= '' then
    msg = os.date(conf.log_date_format)..' '..msg
  end
  io.stderr:write(msg..'\n')
end

local function load_config (path)
  local env = setmetatable({}, { __index = _G })

  local func, err = loadfile(path)
  if not func then
    return nil, err
  end
  assert(pcall(setfenv(func, env)))
  setmetatable(env, nil)

  return env
end

local function is_dir (path)
  return sh("test -d '%s'" % path) == 0
end

local function repo_conf (repo_name)
  return {
    repo_name   = repo_name,
    clone_dir   = conf.cache_dir..'/'..repo_name..'.git',
    origin_url  = conf.origin_url:format(repo_name),
    mirror_url  = conf.mirror_url:format(repo_name),
    git_opts    = (DEBUG and '' or '--quiet'),
    ssh_command = conf.ssh_command:gsub('"', '\\"'),
  }
end

local function git_clone (repo_conf)
  return sh([[
    set -e
    mkdir -p "$(dirname "${clone_dir}")"
    export GIT_SSH_COMMAND="${ssh_command}"
    git clone --mirror "${origin_url}" ${git_opts} "${clone_dir}"
    git -C "${clone_dir}" remote set-url --push origin "${mirror_url}"
  ]] % repo_conf)
end

local function git_update (repo_conf)
  return sh([[
    set -e
    cd "${clone_dir}"
    export GIT_SSH_COMMAND="${ssh_command}"
    git fetch --prune ${git_opts}
    git push --mirror ${git_opts}
  ]] % repo_conf)
end

local function sync_mirror (repo_name)
  local conf = repo_conf(repo_name)

  if not is_dir(conf.clone_dir) and git_clone(conf) ~= 0 then
    return nil, 'Failed to clone repository: '..conf.origin_url
  end

  if git_update(conf) ~= 0 then
    return nil, 'Failed to update repository: '..conf.mirror_url
  end

  return true
end


--------  M a i n  --------

local myconf, err = load_config(CONFIG)
if not myconf then
  log('ERROR: Failed to load config file '..err)
  os.exit(1)
end
conf = merge(conf, myconf)

local client = mqtt.new()

client.ON_CONNECT = function()
  log('INFO: Subscribing to '..concat(conf.mqtt_topics, ', '))

  for _, topic in ipairs(conf.mqtt_topics) do
    client:subscribe(topic, 1)
  end
end

client.ON_MESSAGE = function(mid, topic, payload)

  local ok, payload = pcall(json.decode, payload)
  if not ok or not payload.repo then
    log('ERROR: Failed to encode payload from topic '..topic)
    return
  end

  log('INFO: Synchronizing mirror '..payload.repo)

  local ok, err = sync_mirror(payload.repo)
  if ok then
    log('INFO: Completed')
  else
    log('ERROR: '..err)
  end
end

log('INFO: Starting git-mirror-syncd '..VERSION)
log('INFO: Connecting to %s:%s' % { conf.mqtt_host, conf.mqtt_port })
client:connect(conf.mqtt_host, conf.mqtt_port, conf.mqtt_keepalive)
client:loop_forever()
