----------------------
-- A well defined API for using luarocks.
-- This allows you to query the existing packages (@{show} and @{list}) and
-- packages on a remote repository (@{search}). Like the luarocks command-line
-- tool, you can specify the flags `from` and `only_from` for this function.
--
-- Local information is a table: @{local_info_table}.  Usually you get less
-- information for remote queries (basically, package, version and repo) but
-- setting the  flag `details` for @{search} will fill in more fields by
-- downloading the remote rockspecs - bear in mind that this can be slow for
-- large queries.
--
-- @author Steve Donovan
-- @license MIT/X11

local api = {}

local lfs = require 'lfs'
local util = require("luarocks.util")
local deps = require("luarocks.deps")
local manif_core = require("luarocks.manif_core")
local _install = require("luarocks.install")
local build = require("luarocks.build")
local fs = require("luarocks.fs")
local path = require("luarocks.path")
local _remove = require("luarocks.remove")
local purge = require("luarocks.purge")
local list = require("luarocks.list")

local log = require 'loverocks.log'
local versions = require 'loverocks.love-versions'

local function version_iter (versions)
	return util.sortedpairs(versions, deps.compare_versions)
end

local function _latest(versions, first_repo)
	local version, repos = version_iter(versions)()
	local repo = repos[first_repo and 1 or #repos]
	return version, repo.repo
end

local function copy(t, into)
	for k, v in pairs(t) do
		if type(v) == 'table' then
			if not into[k] then into[k] = {} end
			copy(v, into[k])
		else
			into[k] = v
		end
	end
end

-- cool, let's initialize this baby. This is normally done by command_line.lua
-- Since cfg is a singleton, api has to be one too. So it goes.
local cfg = require("luarocks.cfg")

function api.apply_config(new)
	-- idea: instead of copying-in, we make package.preload["luarocks.cfg"]
	-- a mock table, and then push in and out prototypes to apply the config.
	copy(new, cfg)
end

local function use_tree(tree)
	cfg.root_dir = tree
	cfg.rocks_dir = path.rocks_dir(tree)
	cfg.rocks_trees = { "rocks" }
	cfg.deploy_bin_dir = path.deploy_bin_dir(tree)
	cfg.deploy_lua_dir = path.deploy_lua_dir(tree)
	cfg.deploy_lib_dir = path.deploy_lib_dir(tree)
end

local old_printout, old_printerr = util.printout, util.printerr
local path_sep = package.config:sub(1, 1)

function q_printout(...)
	log:info("L: %s", table.concat({...}, "\t"))
end

function q_printerr(...)
	log:_warning("L: %s", table.concat({...}, "\t"))
end

local project_cfg = nil
local cwd = nil
local function check_flags(flags)
	cwd = fs.current_dir()
	use_tree(cwd .. "/rocks")
	if not project_cfg then
		project_cfg = {}
		versions.add_version_info(cwd .. "/conf.lua", project_cfg)
		api.apply_config(project_cfg)
	end

	manif_core.manifest_cache = {} -- clear cache
	flags._old_servers = cfg.rocks_servers
	if flags.from then
		table.insert(cfg.rocks_servers, 1, flags.from)
	elseif flags.only_from then
		cfg.rocks_servers = { flags.only_from }
	end
	util.printout = q_printout
	util.printerr = q_printerr
end

local function restore_flags (flags)
	assert(lfs.chdir(cwd))
	if flags.from then
		table.remove(cfg.rocks_servers, 1)
	elseif flags.only_from then
		cfg.rocks = flags._old_servers
	end
	util.printout = old_printout
	util.printerr = old_printerr
end

--- show information about an installed package.
-- @param name the package name
-- @param version version, may be nil
-- @param field one of the output fields
-- @return @{local_info_table}, or a string if field is specified.
-- @see show.lua
function api.show(name, version, field)
	local res, err = list (name, version, {exact = true})
	if not res then return nil, err end
	res = res[1]
	if field then return res[field]
	else return res
	end
end

--- list information about currently installed packages.
-- @param pattern a string which is partially matched against packages
-- @param version a specific version, may be nil.
-- @param flags @{flags}
-- @return list of @{local_info_table}
function api.list(pattern, version, flags)
	flags = flags or {}
	check_flags(flags)

	local f = {pattern, version}
	if flags.outdated then
		table.insert(f, "--outdated")
	end
	if flags.porcelain then
		table.insert(f, "--porcelain")
	end

	log:fs("luarocks list %s", table.concat(f, " "))
	local ok, err = list.run(unpack(f))
	restore_flags(flags)
	return ok, err
end

--- is this package outdated?.
-- @{check.lua} shows how to compare installed and available packages.
-- @param linfo local info table
-- @param info server info table
-- @return true if the package is out of date.
function api.compare_versions (linfo, info)
	return deps.compare_versions(info.version, linfo.version)
end


--- install a rock.
-- @param name
-- @param version can ask for a specific version (default nil means get latest)
-- @param flags @{flags} `use_local` to install to local tree,
-- `from` to add another repository to the search and `only_from` to only use
-- the given repository
-- @return true if successful, nil if not.
-- @return error message if not
function api.install(name, version, flags)
	flags = flags or {}
	check_flags(flags)

	log:fs("luarocks install %s %s", name or "", version or "")
	local ok, err = _install.run(name, version)
	restore_flags(flags)
	return ok, err
end

--- remove a rock.
-- @param name
-- @param version a specific version (default nil means remove all)
function api.remove(name, version, flags)
	flags = flags or {}
	check_flags(flags)

	log:fs("luarocks remove %s %s", name, version)
	local ok, err = _remove.run(name, version)
	restore_flags(flags)
	return ok, err
end

--- Build a rock.
-- @param name
-- @param version
-- @param flags @{flags}
-- @return true if successful, nil if not
-- @return error message if not
function api.build(name, version, flags)
	flags = flags or {}
	check_flags(flags)
	local f = {}
	if version then table.insert(f, version) end
	if flags.only_deps then table.insert(f, "--only-deps") end

	log:fs("luarocks build %s %s", name, table.concat(f, " "))
	local ok, err = build.run(name, unpack(f))
	restore_flags(flags)
	return ok, err
end


--- Attempt to fulfill dependencies table
-- @param deps A list of dependency strings
function api.deps(name, depstrings, flags)
	assert(type(name) == 'string')
	local _deps = require 'luarocks.deps'
	flags = flags or {}
	check_flags(flags)

	local parsed_deps = {}
	for _, s in ipairs(depstrings) do
		table.insert(parsed_deps, _deps.parse_dep(s))
	end

	local ok, err = _deps.fulfill_dependencies({
		name = name,
		version = "",
		dependencies = parsed_deps
	}, "one")

	restore_flags(flags)

	return ok, err
end

--- Purge the loverocks tree
function api.purge(flags)
	flags = flags or {}
	check_flags(flags)

	local f = {}
	table.insert(f, ("--tree=%s"):format("rocks"))

	if flags.only_deps then
		table.insert(f, "--only-deps")
	end

	if flags.force then
		table.insert(f, "--force")
	end

	log:fs("luarocks purge")
	local ok, err = purge.run(unpack(f))

	restore_flags(flags)
	return ok, err
end

return api
